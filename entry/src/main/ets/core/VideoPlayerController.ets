/**
 * AVPlayer 简版封装（M3-media）：本地文件（TDLib 沙盒绝对路径）→ 播放。
 *
 * 状态机（media.AVPlayer 官方流转，surface 渲染）：
 *   createAVPlayer(idle) → 设 url=fd://xx（必须 idle 态）→ initialized
 *   → 设 surfaceId → prepare → prepared → play → playing
 *   paused ⇄ playing；completed；error → release
 *   surfaceId 官方契约：initialized 态首次设置；prepared/playing/paused/completed/stopped
 *   态可更新（晚到 surface 按此重设恢复渲染，消除永久黑屏竞态——M3-media 复审修复）
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
        // 打开本地文件单独兜底（M3-media 复审修复）：失败不误标 createAVPlayer failed，
        // 释放实例并转 ERROR（fd 未打开无泄漏）
        let fd: number = -1;
        try {
          const opened: fileIo.File = fileIo.openSync(localPath, fileIo.OpenMode.READ_ONLY);
          this.srcFile = opened;
          fd = opened.fd;
        } catch (err) {
          const be: BusinessError = err as BusinessError;
          hilog.error(LOG_DOMAIN, TAG, 'open local file failed: code=%{public}d', be.code);
          this.player = null;
          player.release().catch((): void => {
          });
          this.setState(PlayerState.ERROR);
          return;
        }
        player.url = `fd://${fd}`; // idle → initialized（stateChange 接续）
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
      this.applySurfaceIfReady(); // 晚到 surface：官方允许 prepared 态重设
      player.play().catch((err: BusinessError): void => {
        hilog.error(LOG_DOMAIN, TAG, 'play failed: code=%{public}d', err.code);
        this.setState(PlayerState.ERROR);
      });
    } else if (state === 'playing') {
      this.applySurfaceIfReady(); // 官方允许 playing 态重设
      this.setState(PlayerState.PLAYING);
    } else if (state === 'paused') {
      this.applySurfaceIfReady(); // 官方允许 paused 态重设
      this.setState(PlayerState.PAUSED);
    } else if (state === 'completed') {
      this.applySurfaceIfReady(); // 官方允许 completed 态重设
      this.setState(PlayerState.COMPLETED);
    } else if (state === 'error') {
      this.setState(PlayerState.ERROR);
    }
  }

  /**
   * surfaceId 官方契约：initialized 态首次设置；prepared/playing/paused/completed/stopped
   * 态可更新。surfaceId 晚于 initialized 到达的竞态（原实现守卫过严 → 永久黑屏）由此消除：
   * 状态机每次推进到可设态都重试绑定（M3-media 复审修复）。
   */
  private applySurfaceIfReady(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null || this.releasing || this.surfaceId.length === 0) {
      return;
    }
    const state: media.AVPlayerState = player.state;
    const settable: boolean = state === 'initialized' || state === 'prepared' || state === 'playing' ||
      state === 'paused' || state === 'completed' || state === 'stopped';
    if (settable && player.surfaceId !== this.surfaceId) {
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
