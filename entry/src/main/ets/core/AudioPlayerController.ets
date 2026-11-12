/**
 * 会话语音/音频播放控制器（M6-6）。单例。
 *
 * 与 VideoPlayerController（M3，视频 surface 渲染）的差异：
 * - 纯音频：无 surfaceId 环节，initialized → prepare → prepared → play；
 * - 单实例互斥：同屏多条语音/音频共享一个 AVPlayer——切换播放目标自动停旧（key 语义：
 *   `chatId:messageId`），UI 用 activeKey 判定哪条气泡在播；
 * - 倍速：setSpeed（media.PlaybackSpeed 枚举：SPEED_FORWARD_1_00_X / _1_25_X / _2_00_X，
 *   API 26 d.ts 实测无 1.5 档，倍速循环取 1.0 → 1.25 → 2.0）；
 * - seek：进度条拖动（prepared 后可用）；
 * - 进度：'seekUpdate' 事件驱动（currentTime 精度有限），completed 归零。
 *
 * fd 生命周期：open 后移交 AVPlayer 独占，release 完成后 closeSync（沿视频控制器契约）。
 * 日志红线：不记路径/文件名，仅记 key 与状态。
 */
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'AudioPlayer';
const LOG_DOMAIN: number = 0x0012;

/** 对 UI 暴露的播放器状态 */
export class AudioState {
  static readonly IDLE: string = 'idle';
  static readonly PREPARING: string = 'preparing';
  static readonly PLAYING: string = 'playing';
  static readonly PAUSED: string = 'paused';
  static readonly COMPLETED: string = 'completed';
  static readonly ERROR: string = 'error';
}

/** 播放快照（activeKey + 状态 + 进度，UI 观察者按 key 匹配刷新对应气泡） */
export class AudioSnapshot {
  key: string = '';
  state: string = AudioState.IDLE;
  positionMs: number = 0;
  durationMs: number = 0;
  speed: number = 1;
}

export type AudioObserver = (snapshot: AudioSnapshot) => void;

/** 倍速循环档位（1.0 → 1.25 → 2.0；API 26 无 1.5 档） */
const SPEED_STEPS: Array<media.PlaybackSpeed> = [
  media.PlaybackSpeed.SPEED_FORWARD_1_00_X,
  media.PlaybackSpeed.SPEED_FORWARD_1_25_X,
  media.PlaybackSpeed.SPEED_FORWARD_2_00_X
];
const SPEED_VALUES: Array<number> = [1, 1.25, 2];

export class AudioPlayerController {
  private static instance: AudioPlayerController | null = null;

  private player: media.AVPlayer | null = null;
  private srcFile: fileIo.File | null = null;
  /** 当前播放目标 key（chatId:messageId；空 = 空闲） */
  private activeKey: string = '';
  private state: string = AudioState.IDLE;
  private positionMs: number = 0;
  private durationMs: number = 0;
  private speedStep: number = 0;
  private releasing: boolean = false;
  private observers: Array<AudioObserver> = [];

  private constructor() {
  }

  static getInstance(): AudioPlayerController {
    if (AudioPlayerController.instance === null) {
      AudioPlayerController.instance = new AudioPlayerController();
    }
    return AudioPlayerController.instance;
  }

  addObserver(observer: AudioObserver): void {
    if (!this.observers.includes(observer)) {
      this.observers.push(observer);
    }
  }

  removeObserver(observer: AudioObserver): void {
    const index: number = this.observers.indexOf(observer);
    if (index >= 0) {
      this.observers.splice(index, 1);
    }
  }

  getActiveKey(): string {
    return this.activeKey;
  }

  getState(): string {
    return this.state;
  }

  /**
   * 播放/暂停切换（互斥语义）：
   * - 同 key：playing → pause；paused/prepared/completed → play（completed 先 seek 0）；
   * - 异 key：释放当前实例后以新目标重建（在途释放期间重复调用被 releasing 挡住，UI 自然忽略）。
   */
  toggle(key: string, localPath: string): void {
    if (key.length === 0 || localPath.length === 0) {
      return;
    }
    if (this.releasing) {
      return;
    }
    if (this.activeKey === key) {
      // PREPARING 窗口（createAVPlayer 在途，player 仍 null）重复点击：直接忽略
      // （PR18 审计 P1-2——重复 openInternal 会双实例叠播 + fd 泄漏）
      if (this.player !== null) {
        this.toggleCurrent();
      }
      return;
    }
    this.releaseAndPlay(key, localPath);
  }

  /** seek（进度拖动；prepared 后有效，UI 层保证 0..duration） */
  seek(key: string, positionMs: number): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null || key !== this.activeKey || this.releasing) {
      return;
    }
    if (this.state === AudioState.PLAYING || this.state === AudioState.PAUSED ||
      this.state === AudioState.COMPLETED) {
      player.seek(Math.max(0, Math.floor(positionMs)));
      this.positionMs = Math.max(0, Math.floor(positionMs));
      this.notifyChanged();
    }
  }

  /** 倍速循环切换（1.0 → 1.25 → 2.0 → 1.0），返回切换后速率 */
  cycleSpeed(key: string): number {
    const player: media.AVPlayer | null = this.player;
    if (player === null || key !== this.activeKey || this.releasing) {
      return SPEED_VALUES[this.speedStep];
    }
    this.speedStep = (this.speedStep + 1) % SPEED_STEPS.length;
    player.setSpeed(SPEED_STEPS[this.speedStep]); // API 26：setSpeed 返回 void（结果经 speedDone 事件）
    this.notifyChanged();
    return SPEED_VALUES[this.speedStep];
  }

  /** 停止并释放（切会话/组件销毁调用；幂等） */
  stop(): void {
    this.activeKey = '';
    this.releaseInternal();
  }

  // ---------------- 内部 ----------------

  private toggleCurrent(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    if (this.state === AudioState.PLAYING) {
      player.pause().catch((err: BusinessError): void => {
        hilog.warn(LOG_DOMAIN, TAG, 'pause failed: code=%{public}d', err.code);
      });
    } else if (this.state === AudioState.PAUSED || this.state === AudioState.COMPLETED) {
      if (this.state === AudioState.COMPLETED) {
        player.seek(0);
        this.positionMs = 0;
      }
      player.play().catch((err: BusinessError): void => {
        hilog.warn(LOG_DOMAIN, TAG, 'play failed: code=%{public}d', err.code);
      });
    }
  }

  private releaseAndPlay(key: string, localPath: string): void {
    const previous: media.AVPlayer | null = this.player;
    this.player = null;
    const previousFile: fileIo.File | null = this.srcFile;
    this.srcFile = null;
    const startNew: () => void = (): void => {
      this.activeKey = key;
      this.state = AudioState.PREPARING;
      this.positionMs = 0;
      this.durationMs = 0;
      this.speedStep = 0;
      this.notifyChanged();
      this.openInternal(key, localPath);
    };
    if (previous !== null) {
      this.releasing = true;
      previous.off('stateChange');
      previous.off('error');
      previous.off('timeUpdate');
      previous.off('seekDone');
      previous.release()
        .then((): void => {
          this.closeFile(previousFile);
          this.releasing = false;
          startNew();
        })
        .catch((): void => {
          this.closeFile(previousFile);
          this.releasing = false;
          startNew();
        });
      return;
    }
    startNew();
  }

  private openInternal(key: string, localPath: string): void {
    media.createAVPlayer()
      .then((player: media.AVPlayer): void => {
        if (this.activeKey !== key) {
          // 等待期间目标已切换：丢弃本实例
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
          this.setState(AudioState.ERROR);
        });
        player.on('timeUpdate', (timeMs: number): void => {
          if (Number.isFinite(timeMs)) {
            this.positionMs = timeMs;
            this.notifyChanged();
          }
        });
        let fd: number = -1;
        try {
          const opened: fileIo.File = fileIo.openSync(localPath, fileIo.OpenMode.READ_ONLY);
          this.srcFile = opened;
          fd = opened.fd;
        } catch (err) {
          const be: BusinessError = err as BusinessError;
          hilog.error(LOG_DOMAIN, TAG, 'open file failed: code=%{public}d', be.code);
          this.player = null;
          player.release().catch((): void => {
          });
          this.setState(AudioState.ERROR);
          return;
        }
        player.url = `fd://${fd}`;
      })
      .catch((err: BusinessError): void => {
        hilog.error(LOG_DOMAIN, TAG, 'createAVPlayer failed: code=%{public}d', err.code);
        this.setState(AudioState.ERROR);
      });
  }

  private onStateChanged(state: media.AVPlayerState): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    if (state === 'initialized') {
      this.setState(AudioState.PREPARING);
      player.prepare().catch((err: BusinessError): void => {
        hilog.error(LOG_DOMAIN, TAG, 'prepare failed: code=%{public}d', err.code);
        this.setState(AudioState.ERROR);
      });
    } else if (state === 'prepared') {
      const duration: number = player.duration;
      this.durationMs = Number.isFinite(duration) ? duration : 0;
      if (this.speedStep !== 0) {
        player.setSpeed(SPEED_STEPS[this.speedStep]);
      }
      player.play().catch((err: BusinessError): void => {
        hilog.error(LOG_DOMAIN, TAG, 'play failed: code=%{public}d', err.code);
        this.setState(AudioState.ERROR);
      });
    } else if (state === 'playing') {
      this.setState(AudioState.PLAYING);
    } else if (state === 'paused') {
      this.setState(AudioState.PAUSED);
    } else if (state === 'completed') {
      this.positionMs = 0;
      this.setState(AudioState.COMPLETED);
    } else if (state === 'error') {
      this.setState(AudioState.ERROR);
    }
  }

  private releaseInternal(): void {
    const player: media.AVPlayer | null = this.player;
    this.player = null;
    const file: fileIo.File | null = this.srcFile;
    this.srcFile = null;
    this.state = AudioState.IDLE;
    this.positionMs = 0;
    this.durationMs = 0;
    this.speedStep = 0;
    if (player !== null) {
      player.off('stateChange');
      player.off('error');
      player.off('timeUpdate');
      player.off('seekDone');
      player.release().catch((): void => {
      });
    }
    this.closeFile(file);
    this.notifyChanged();
  }

  private closeFile(file: fileIo.File | null): void {
    if (file !== null) {
      try {
        fileIo.closeSync(file);
      } catch (err) {
        // fd 泄漏兜底失败：仅记日志（文件句柄随进程回收）
        hilog.warn(LOG_DOMAIN, TAG, 'close fd failed');
      }
      this.srcFile = null;
    }
  }

  private setState(state: string): void {
    this.state = state;
    this.notifyChanged();
  }

  private notifyChanged(): void {
    const snapshot: AudioSnapshot = new AudioSnapshot();
    snapshot.key = this.activeKey;
    snapshot.state = this.state;
    snapshot.positionMs = this.positionMs;
    snapshot.durationMs = this.durationMs;
    snapshot.speed = SPEED_VALUES[this.speedStep];
    for (const observer of this.observers) {
      try {
        observer(snapshot);
      } catch (err) {
        hilog.error(LOG_DOMAIN, TAG, 'observer error: %{private}s', JSON.stringify(err));
      }
    }
  }
}
