/**
 * AVPlayer 简版封装（M3-media）：本地文件（TDLib 沙盒绝对路径）→ 播放。
 *
 * 状态机（media.AVPlayer 官方流转，surface 渲染）：
 *   createAVPlayer(idle) → 设 url=fd://xx（必须 idle 态）→ initialized
 *   → 设 surfaceId（首次仅 initialized 态可设）→ prepare → prepared → play → playing
 *   paused ⇄ playing；completed；error → release
 *
 * fd 生命周期：fs.openSync 打开后移交 AVPlayer 独占使用（官方约束：fd 不得同时用于其他读写），
 * release 完成后再 closeSync。
 *
 * 日志红线：不记路径/文件名（含用户内容特征），仅记状态与错误码。
 */
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'VideoPlayer';
const LOG_DOMAIN: number = 0x0012;

/** 对 UI 暴露的播放器状态 */
export class PlayerState {
  static readonly IDLE: string = 'idle';
  static readonly PREPARING: string = 'preparing';
  static readonly PLAYING: string = 'playing';
  static readonly PAUSED: string = 'paused';
  static readonly COMPLETED: string = 'completed';
  static readonly ERROR: string = 'error';
  static readonly RELEASED: string = 'released';
}

export type PlayerStateListener = (state: string) => void;

export class VideoPlayerController {
  private player: media.AVPlayer | null = null;
  private srcFile: fileIo.File | null = null;
  private surfaceId: string = '';
  private state: string = PlayerState.IDLE;
  private listener: PlayerStateListener | null = null;
  /** release 已发起标记：迟到的异步回调不再驱动状态机 */
  private releasing: boolean = false;

  setStateListener(listener: PlayerStateListener): void {
    this.listener = listener;
  }

  getState(): string {
    return this.state;
  }

  /** prepared 后可查；-1 = 未知 */
  getDurationMs(): number {
    if (this.player === null) {
      return -1;
    }
    const duration: number = this.player.duration;
    return Number.isFinite(duration) ? duration : -1;
  }

  /** prepared/playing/paused 后可查；-1 = 未知 */
  getCurrentTimeMs(): number {
    if (this.player === null) {
      return -1;
    }
    const time: number = this.player.currentTime;
    return Number.isFinite(time) ? time : -1;
  }

  /**
   * 打开本地文件并自动播放：open(path) → url → initialized → surfaceId → prepare → play。
   * surfaceId 由 UI 侧 XComponent 就绪后经 setSurface 传入（时序两者解耦，先到者等待）。
   */
  open(localPath: string): void {
    if (this.player !== null || this.releasing) {
      return;
    }
    media.createAVPlayer()
      .then((player: media.AVPlayer): void => {
        if (this.releasing) {
          player.release().catch((): void => {
          });
          return;
        }
        this.player = player;
        player.on('stateChange', (state: media.AVPlayerState, reason: media.StateChangeReason): void => {
          this.onStateChanged(state);
        });
        player.on('error', (err: BusinessError): void => {
          hilog.error(LOG_DOMAIN, TAG, 'player error: code=%{public}d', err.code);
          this.setState(PlayerState.ERROR);
        });
        this.srcFile = fileIo.openSync(localPath, fileIo.OpenMode.READ_ONLY);
        player.url = `fd://${this.srcFile.fd}`; // idle → initialized（stateChange 接续）
      })
      .catch((err: BusinessError): void => {
        hilog.error(LOG_DOMAIN, TAG, 'createAVPlayer failed: code=%{public}d', err.code);
        this.setState(PlayerState.ERROR);
      });
  }

  /** XComponent surface 就绪回调（须在 player 到 initialized 前后均可安全调用） */
  setSurface(surfaceId: string): void {
    this.surfaceId = surfaceId;
    this.applySurfaceIfReady();
  }

  /** 播放/暂停切换（prepared/playing/paused/completed 态可用） */
  toggle(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null || this.releasing) {
      return;
    }
    if (this.state === PlayerState.PLAYING) {
      player.pause().catch((err: BusinessError): void => {
        hilog.warn(LOG_DOMAIN, TAG, 'pause failed: code=%{public}d', err.code);
      });
    } else if (this.state === PlayerState.PAUSED || this.state === PlayerState.COMPLETED) {
      if (this.state === PlayerState.COMPLETED) {
        player.seek(0);
      }
      player.play().catch((err: BusinessError): void => {
        hilog.warn(LOG_DOMAIN, TAG, 'play failed: code=%{public}d', err.code);
      });
    }
  }

  /** 释放（幂等）：任何状态可调；fd 在 release 完成后关闭 */
  release(): void {
    if (this.releasing) {
      return;
    }
    this.releasing = true;
    const player: media.AVPlayer | null = this.player;
    this.player = null;
    const finish: () => void = (): void => {
      if (this.srcFile !== null) {
        fileIo.closeSync(this.srcFile);
        this.srcFile = null;
      }
      this.setState(PlayerState.RELEASED);
    };
    if (player === null) {
      finish();
      return;
    }
    player.off('stateChange');
    player.off('error');
    player.release()
      .then((): void => {
        finish();
      })
      .catch((): void => {
        finish(); // release 异常也必须关 fd，防泄漏
      });
  }

  // ---------------- 内部状态机 ----------------

  private onStateChanged(state: media.AVPlayerState): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null || this.releasing) {
      return;
    }
    if (state === 'initialized') {
      this.applySurfaceIfReady();
      this.setState(PlayerState.PREPARING);
      player.prepare().catch((err: BusinessError): void => {
        hilog.error(LOG_DOMAIN, TAG, 'prepare failed: code=%{public}d', err.code);
        this.setState(PlayerState.ERROR);
      });
    } else if (state === 'prepared') {
      player.play().catch((err: BusinessError): void => {
        hilog.error(LOG_DOMAIN, TAG, 'play failed: code=%{public}d', err.code);
        this.setState(PlayerState.ERROR);
      });
    } else if (state === 'playing') {
      this.setState(PlayerState.PLAYING);
    } else if (state === 'paused') {
      this.setState(PlayerState.PAUSED);
    } else if (state === 'completed') {
      this.setState(PlayerState.COMPLETED);
    } else if (state === 'error') {
      this.setState(PlayerState.ERROR);
    }
  }

  /** surfaceId 首次仅 initialized 态可设：initialized 已到且 surface 已知即设置 */
  private applySurfaceIfReady(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null || this.surfaceId.length === 0) {
      return;
    }
    if (player.state === 'initialized' && player.surfaceId === undefined) {
      player.surfaceId = this.surfaceId;
    }
  }

  private setState(state: string): void {
    this.state = state;
    if (this.listener !== null) {
      this.listener(state);
    }
  }
}
