/**
 * 语音录制器（M7-F2）：avRecorder 封装（aac/m4a，音频单轨）+ 麦克风运行时授权。
 *
 * 流程：requestPermission（首次弹窗）→ start（cacheDir 临时文件 + avRecorder url=fd://）
 * → stop（release 后回传沙盒路径与时长，调用方 sendMessage inputMessageVoiceNote）
 * → cancel（删临时文件）。
 *
 * 红线：录音文件为用户内容——路径不落日志；失败仅记错误码。
 */
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'VoiceRecorder';
const LOG_DOMAIN: number = 0x0012;

/** 录制结果（stop 成功回传） */
export class VoiceRecording {
  path: string = '';
  durationSec: number = 0;
}

export type VoiceRecorderListener = (state: string, durationSec: number) => void;

/** recorder 状态：idle / requesting / recording / processing */
export class VoiceRecorderState {
  static readonly IDLE: string = 'idle';
  static readonly REQUESTING: string = 'requesting';
  static readonly RECORDING: string = 'recording';
  static readonly PROCESSING: string = 'processing';
}

export class VoiceNoteRecorder {
  private recorder: media.AVRecorder | null = null;
  private outFile: fileIo.File | null = null;
  private outPath: string = '';
  private state: string = VoiceRecorderState.IDLE;
  private durationSec: number = 0;
  private tickTimer: number = -1;
  private listener: VoiceRecorderListener | null = null;

  setStateListener(listener: VoiceRecorderListener): void {
    this.listener = listener;
  }

  getState(): string {
    return this.state;
  }

  getDurationSec(): number {
    return this.durationSec;
  }

  private setState(state: string): void {
    this.state = state;
    if (this.listener !== null) {
      this.listener(state, this.durationSec);
    }
  }

  /** 麦克风运行时授权（user_grant；已授权直接过） */
  async requestPermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      // 1.8.63 时代 SDK：入口为 createAtManager（getAtManager 不存在，d.ts:92 实测）
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(context,
        ['ohos.permission.MICROPHONE'] as Array<Permissions>);
      for (let i: number = 0; i < result.authResults.length; i++) {
        if (result.authResults[i] === 0) {
          return true;
        }
      }
      return false;
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(LOG_DOMAIN, TAG, 'request mic permission failed: %{public}d', be.code);
      return false;
    }
  }

  /** 开始录制（前置：requestPermission 已过） */
  async start(context: common.UIAbilityContext): Promise<boolean> {
    if (this.state !== VoiceRecorderState.IDLE) {
      return false;
    }
    this.setState(VoiceRecorderState.PROCESSING);
    try {
      this.outPath = `${context.cacheDir}/voice_${Date.now()}.m4a`;
      this.outFile = fileIo.openSync(this.outPath, fileIo.OpenMode.READ_WRITE |
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      this.recorder = await media.createAVRecorder();
      const profile: media.AVRecorderProfile = {
        audioBitrate: 48000,
        audioChannels: 1,
        audioCodec: media.CodecMimeType.AUDIO_AAC,
        audioSampleRate: 16000,
        fileFormat: media.ContainerFormatType.CFT_MPEG_4A
      };
      const config: media.AVRecorderConfig = {
        profile: profile,
        url: `fd://${this.outFile.fd}`,
        audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC
      };
      await this.recorder.prepare(config);
      await this.recorder.start();
      this.durationSec = 0;
      this.setState(VoiceRecorderState.RECORDING);
      this.tickTimer = setInterval((): void => {
        this.durationSec += 1;
        if (this.listener !== null) {
          this.listener(this.state, this.durationSec);
        }
      }, 1000);
      return true;
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.error(LOG_DOMAIN, TAG, 'start failed: %{public}d', be.code);
      this.cleanup();
      this.setState(VoiceRecorderState.IDLE);
      return false;
    }
  }

  /** 停止并回传录制（成功返回 VoiceRecording；失败返回 null） */
  async stop(): Promise<VoiceRecording | null> {
    if (this.state !== VoiceRecorderState.RECORDING || this.recorder === null) {
      return null;
    }
    this.setState(VoiceRecorderState.PROCESSING);
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
    const duration: number = this.durationSec;
    const path: string = this.outPath;
    const recorder: media.AVRecorder = this.recorder;
    this.recorder = null;
    try {
      await recorder.stop();
      await recorder.release();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.error(LOG_DOMAIN, TAG, 'stop failed: %{public}d', be.code);
      this.cleanup();
      this.setState(VoiceRecorderState.IDLE);
      return null;
    }
    this.closeFile();
    const out: VoiceRecording = new VoiceRecording();
    out.path = path;
    out.durationSec = Math.max(1, duration);
    this.outPath = '';
    this.setState(VoiceRecorderState.IDLE);
    return out;
  }

  /** 取消录制（删临时文件） */
  async cancel(): Promise<void> {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
    const recorder: media.AVRecorder | null = this.recorder;
    this.recorder = null;
    if (recorder !== null) {
      try {
        await recorder.stop();
      } catch (err) {
        // 已失活场景 stop 失败可忽略
      }
      try {
        await recorder.release();
      } catch (err) {
        // 同上
      }
    }
    this.cleanup();
    this.setState(VoiceRecorderState.IDLE);
  }

  /** 组件销毁兜底（录音中强停，文件丢弃） */
  abortIfRecording(): void {
    if (this.state === VoiceRecorderState.RECORDING || this.state === VoiceRecorderState.PROCESSING) {
      this.cancel();
    }
  }

  private cleanup(): void {
    this.closeFile();
    if (this.outPath.length > 0) {
      try {
        fileIo.unlinkSync(this.outPath);
      } catch (err) {
        // 文件已不存在：忽略
      }
      this.outPath = '';
    }
    this.durationSec = 0;
  }

  private closeFile(): void {
    if (this.outFile !== null) {
      try {
        fileIo.closeSync(this.outFile);
      } catch (err) {
        // fd 已失效：忽略
      }
      this.outFile = null;
    }
  }
}
