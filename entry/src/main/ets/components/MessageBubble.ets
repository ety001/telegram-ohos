/**
 * 消息气泡（M3 / M3-media）：ChatPanel 消息流子组件。
 *
 * 分支结构（model.mediaKind）：
 * - photo：选中档（宽 ≤1080）下载完成前 minithumbnail（base64 data URI）立即显示，完成后换真图；
 *   无边框纯图 + 底部时间覆盖层；点击全屏预览（ChatPanel overlay）
 * - video：thumbnail（minithumbnail 先行）+ 播放按钮覆盖；点击触发下载（高优先），
 *   完成后自动拉起 AVPlayer 播放页
 * - document：文件名/大小 + 下载按钮；点击下载，完成自动走 DocumentViewPicker 保存到用户目录
 * - voice/animation/sticker/audio：占位文案（M5 实装），**占位不崩溃**
 * - 文本（默认）：formattedText.text 纯文本（entities 富文本 M5）
 *
 * 下载状态：组件订阅 FileDownloadStore（onFileChanged → 本地 @State），
 * ForEach 键不含下载进度（避免整泡重建），气泡内部自刷新。
 *
 * 状态角标：发送中时钟 / 失败红色感叹号（点击重试）/ 已送出单勾 / 已读双勾。
 */
import { common } from '@kit.AbilityKit';
import { ChatUi } from '../pages/ChatUi';
import { MediaKind } from '../core/MessageContent';
import { FileDownloadStore, DownloadPriority } from '../core/FileDownloadStore';
import { MediaSaver, SaveResult } from '../core/MediaSaver';

/** 媒体气泡展示尺寸（vp） */
const MEDIA_WIDTH: number = 240;
const MEDIA_MAX_HEIGHT: number = 320;
const DEFAULT_ASPECT: number = 4 / 3;

/** 文档气泡动作态（docState） */
class DocActionState {
  static readonly IDLE: string = 'idle';
  static readonly DOWNLOADING: string = 'downloading';
  static readonly READY: string = 'ready';
  static readonly SAVING: string = 'saving';
  static readonly SAVED: string = 'saved';
  static readonly FAILED: string = 'failed';
}

/** 气泡视图模型：由 TDLib message 对象按需投影（ChatPanel 构建） */
export class MessageBubbleModel {
  messageId: number = 0;
  isOutgoing: boolean = false;
  text: string = '';
  timeText: string = '';
  /** 发送时间（unix 秒，分组头计算用） */
  dateSeconds: number = 0;
  /** sending / failed / sent（sent = 已送出服务器；isRead 另计） */
  sendState: string = 'none';
  isRead: boolean = false;
  /** 失败原因（TDLib error.message 或本地超时文案，气泡下方小字透传） */
  errorText: string = '';
  canRetry: boolean = false;
  /** 分组头 day key（由 ChatPanel 生成分组头，气泡内不渲染） */
  dayKey: number = 0;

  // ---------------- 媒体（M3-media） ----------------
  /** 媒体分支（MediaKind.*；none = 文本/占位走原路径） */
  mediaKind: string = MediaKind.NONE;
  /** photo：minithumbnail data URI（无则空串） */
  photoMini: string = '';
  photoFileId: number = 0;
  photoWidth: number = 0;
  photoHeight: number = 0;
  /** video：封面（minithumbnail data URI）+ thumbnail 文件 + 视频本体 */
  videoMini: string = '';
  videoThumbFileId: number = 0;
  videoThumbWidth: number = 0;
  videoThumbHeight: number = 0;
  /** 视频本体宽高（无 thumbnail 时气泡按原生比例估高） */
  videoWidth: number = 0;
  videoHeight: number = 0;
  videoFileId: number = 0;
  videoFileName: string = '';
  videoDurationText: string = '';
  /** document */
  docFileId: number = 0;
  docFileName: string = '';
  docSizeText: string = '';
  /** photo/video/document 共用 caption（formattedText.text） */
  caption: string = '';
  /** voice/animation/sticker/audio/未知类型占位文案 */
  placeholder: string = '';

  /** ForEach 键后缀：状态/已读/内容指纹任一变化即换键，强制重建气泡（编辑与发送状态机可见刷新） */
  keySuffix(): string {
    // 文本全量入键（M3 复审 MEDIUM 修复：同长度编辑如改错别字时 length 不变会漏刷新）
    return `${this.messageId}_${this.sendState}_${this.isRead}_${this.text}_${this.errorText}` +
      `_${this.mediaKind}_${this.photoFileId}_${this.videoFileId}_${this.docFileId}_${this.caption}`;
  }
}

/** 发送态枚举值（避免散落字符串） */
export class BubbleSendState {
  static readonly NONE: string = 'none';
  static readonly SENDING: string = 'sending';
  static readonly FAILED: string = 'failed';
  static readonly SENT: string = 'sent';
}

@Component
export struct MessageBubble {
  /** 组件入参（非 private：private 成员无法经组件构造器初始化） */
  model: MessageBubbleModel = new MessageBubbleModel();
  /** 失败气泡点击重试回调（ChatPanel 注入，调 MessageStore.retrySend） */
  onRetry: (messageId: number) => void = (messageId: number): void => {
  };
  /** 图片全屏预览回调（src = data URI 或沙盒应用 URI） */
  onPhotoOpen: (src: string) => void = (src: string): void => {
  };
  /** 视频播放回调（localPath = TDLib 沙盒绝对路径，播放页 open fd 播放） */
  onVideoOpen: (localPath: string, title: string) => void = (localPath: string, title: string): void => {
  };

  // ---------------- 下载态（FileDownloadStore 订阅） ----------------
  @State photoReady: boolean = false;
  @State photoUri: string = '';
  @State photoProgress: number = -1;
  @State photoFailed: boolean = false;
  @State thumbReady: boolean = false;
  @State thumbUri: string = '';
  @State videoProgress: number = -1;
  @State videoDownloading: boolean = false;
  @State docState: string = DocActionState.IDLE;
  @State docProgress: number = -1;
  /**
   * 用户已点击（下载完成即自动接续动作：视频播放 / 文件保存）。
   * 已知限制（M3-media 复审固化，不修）：组件私有标志在气泡滚出复用/重建后丢失，
   * 届时下载仍由 FileDownloadStore 层继续（无泄漏），仅"完成后自动拉起"不触发，
   * 用户再次点击即走 ready 快速路径；若需跨组件续动作可上移到 store 层（M5）。
   */
  private videoRequested: boolean = false;
  private docRequested: boolean = false;

  private readonly fileObserver: (fileId: number) => void = (fileId: number): void => {
    if (fileId === this.model.photoFileId && fileId !== 0) {
      this.refreshPhotoState();
    } else if (fileId === this.model.videoThumbFileId && fileId !== 0) {
      this.refreshThumbState();
    } else if (fileId === this.model.videoFileId && fileId !== 0) {
      this.onVideoFileChanged();
    } else if (fileId === this.model.docFileId && fileId !== 0) {
      this.onDocFileChanged();
    }
  };

  aboutToAppear(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    store.addObserver(this.fileObserver);
    this.refreshPhotoState();
    this.refreshThumbState();
    this.refreshDocState();
    // 自动预载：图片选中档 + 视频封面（低/中优先级；视频本体与文件点击才拉，省流量）
    if (this.model.photoFileId !== 0 && !store.isReady(this.model.photoFileId) &&
      !store.isFailed(this.model.photoFileId)) {
      store.downloadFile(this.model.photoFileId, DownloadPriority.PHOTO, 0, 0);
    }
    if (this.model.videoThumbFileId !== 0 && !store.isReady(this.model.videoThumbFileId) &&
      !store.isFailed(this.model.videoThumbFileId)) {
      store.downloadFile(this.model.videoThumbFileId, DownloadPriority.THUMBNAIL, 0, 0);
    }
  }

  aboutToDisappear(): void {
    FileDownloadStore.getInstance().removeObserver(this.fileObserver);
  }

  build() {
    Row({ space: 8 }) {
      if (this.model.isOutgoing) {
        Blank()
          .layoutWeight(1)
      }
      if (this.model.mediaKind === MediaKind.PHOTO || this.model.mediaKind === MediaKind.VIDEO) {
        this.mediaBubble()
      } else if (this.model.mediaKind === MediaKind.DOCUMENT) {
        this.documentBubble()
      } else {
        this.textBubble()
      }
      if (!this.model.isOutgoing) {
        Blank()
          .layoutWeight(1)
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 2, bottom: 2 })
  }

  // ---------------- 图片 / 视频气泡（无边框纯图） ----------------

  @Builder
  mediaBubble() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        Stack({ alignContent: Alignment.Center }) {
          if (this.mediaSrc().length > 0) {
            Image(this.mediaSrc())
              .objectFit(ImageFit.Cover)
              .width(MEDIA_WIDTH)
              .height(this.mediaHeight())
              // 解码降采样（M3-media 复审修复）：仅目标小于源图时生效（mini 小图不受影响，
              // 无放大副作用）。上限取展示尺寸 2 倍（240vp 宽 / 320vp 高上限），1080 档照片
              // 解码内存约降 3/4，画质在 240vp 泡内无肉眼差异；全屏预览走独立 Image 不受限
              .sourceSize({ width: MEDIA_WIDTH * 2, height: MEDIA_MAX_HEIGHT * 2 })
              .borderRadius(12)
              .clip(true)
          } else {
            // 无任何可显示源（minithumbnail 也缺）：灰底占位（不崩溃兜底）
            Stack({ alignContent: Alignment.Center }) {
              Text(this.model.mediaKind === MediaKind.VIDEO ? '[视频]' : '[图片]')
                .fontSize(13)
                .fontColor(ChatUi.TEXT_SECONDARY)
            }
            .width(MEDIA_WIDTH)
            .height(this.mediaHeight())
            .borderRadius(12)
            .backgroundColor(ChatUi.SEARCH_BG)
          }

          // 下载中：中心进度胶囊（有 minithumbnail 底图时半透明遮罩）
          if (this.mediaProgressText().length > 0) {
            Text(this.mediaProgressText())
              .fontSize(12)
              .fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(11)
              .backgroundColor('#88000000')
          }

          // 视频播放按钮覆盖
          if (this.model.mediaKind === MediaKind.VIDEO) {
            Stack({ alignContent: Alignment.Center }) {
              Circle({ width: 46, height: 46 })
                .fill('#66000000')
              Text('▶')
                .fontSize(20)
                .fontColor('#FFFFFF')
            }
            .width(46)
            .height(46)
          }

          // 视频时长角标（左上）
          if (this.model.mediaKind === MediaKind.VIDEO && this.model.videoDurationText.length > 0) {
            Text(this.model.videoDurationText)
              .fontSize(11)
              .fontColor('#FFFFFF')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(7)
              .backgroundColor('#88000000')
              .position({ x: 8, y: 8 })
          }
        }

        if (this.model.caption.length > 0) {
          Text(this.model.caption)
            .fontSize(14)
            .lineHeight(20)
            .fontColor(this.model.isOutgoing ? '#FFFFFF' : ChatUi.TEXT_PRIMARY)
            .margin({ top: 4, left: 4, right: 4 })
        }

        if (this.model.sendState === BubbleSendState.FAILED) {
          Text(this.model.errorText.length > 0 ? this.model.errorText : '发送失败')
            .fontSize(11)
            .maxLines(1)
            .fontColor(ChatUi.BUBBLE_ERROR)
            .margin({ top: 2, left: 4 })
        }
      }
      .alignItems(HorizontalAlign.Start)

      // 底部时间覆盖层（简版：图上右下角胶囊）
      Row({ space: 4 }) {
        Text(this.model.timeText)
          .fontSize(10)
          .fontColor('#FFFFFF')
        this.stateMark()
      }
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(10)
      .backgroundColor('#88000000')
      .margin(6)
    }
    .constraintSize({ maxWidth: '78%' })
    .onClick((): void => {
      if (this.model.mediaKind === MediaKind.VIDEO) {
        this.handleVideoClick();
      } else {
        this.handlePhotoClick();
      }
    })
  }

  // ---------------- 文件气泡（经典底色 + 文件行） ----------------

  @Builder
  documentBubble() {
    Column() {
      Row({ space: 10 }) {
        // 文件图标（自绘：圆角方块 + 文本行笔画，沿导航条/时钟的免 emoji 风格）
        Column({ space: 3 }) {
          Row({ space: 2 }) {
            Rect({ width: 12, height: 2 }).fill(this.model.isOutgoing ? '#FFFFFF' : ChatUi.TEXT_PRIMARY)
            Rect({ width: 4, height: 2 }).fill(this.model.isOutgoing ? '#FFFFFF' : ChatUi.TEXT_PRIMARY)
          }
          Rect({ width: 18, height: 2 }).fill(this.model.isOutgoing ? '#FFFFFF' : ChatUi.TEXT_PRIMARY)
          Rect({ width: 14, height: 2 }).fill(this.model.isOutgoing ? '#FFFFFF' : ChatUi.TEXT_PRIMARY)
        }
        .width(42)
        .height(42)
        .borderRadius(10)
        .backgroundColor(this.model.isOutgoing ? '#4DFFFFFF' : ChatUi.SEARCH_BG)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)

        Column({ space: 2 }) {
          Text(this.docDisplayName())
            .fontSize(14)
            .fontColor(this.model.isOutgoing ? '#FFFFFF' : ChatUi.TEXT_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.docStatusText())
            .fontSize(11)
            .fontColor(this.docState === DocActionState.FAILED ? ChatUi.BUBBLE_ERROR :
              (this.model.isOutgoing ? '#C9E1F8' : ChatUi.TEXT_SECONDARY))
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 动作位：下载图标 / 进度 / 完成勾
        Text(this.docActionMark())
          .fontSize(16)
          .fontColor(this.model.isOutgoing ? '#FFFFFF' : ChatUi.ACCENT)
          .width(30)
          .height(30)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.model.caption.length > 0) {
        Text(this.model.caption)
          .fontSize(14)
          .fontColor(this.model.isOutgoing ? '#FFFFFF' : ChatUi.TEXT_PRIMARY)
          .margin({ top: 4 })
      }

      Row({ space: 4 }) {
        if (this.model.sendState === BubbleSendState.FAILED) {
          Text(this.model.errorText.length > 0 ? this.model.errorText : '发送失败')
            .fontSize(10)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '60%' })
            .fontColor(ChatUi.BUBBLE_ERROR)
        }
        Text(this.model.timeText)
          .fontSize(10)
          .fontColor(this.model.isOutgoing ? '#C9E1F8' : ChatUi.TEXT_SECONDARY)
        this.stateMark()
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(VerticalAlign.Center)
      .margin({ top: 2 })
    }
    .constraintSize({ maxWidth: '78%' })
    .padding({ left: 11, right: 11, top: 7, bottom: 7 })
    .borderRadius(12)
    .backgroundColor(this.model.isOutgoing ? ChatUi.BUBBLE_OUT : ChatUi.BUBBLE_IN)
    .onClick((): void => {
      this.handleDocumentClick();
    })
  }

  // ---------------- 文本 / 占位气泡（原路径） ----------------

  @Builder
  textBubble() {
    Column() {
      if (this.model.text.length > 0) {
        Text(this.model.text)
          .fontSize(15)
          .lineHeight(21)
          .fontColor(this.model.isOutgoing ? '#FFFFFF' : ChatUi.TEXT_PRIMARY)
          .textAlign(TextAlign.Start)
      } else {
        // 媒体类型占位（语音/动图/贴纸 M5 实装）或未知类型兜底——占位不崩溃
        Text(this.model.placeholder.length > 0 ? this.model.placeholder : '[暂不支持的消息类型]')
          .fontSize(13)
          .fontColor(this.model.isOutgoing ? '#DCE9F7' : ChatUi.TEXT_SECONDARY)
      }
      Row({ space: 4 }) {
        if (this.model.sendState === BubbleSendState.FAILED) {
          Text(this.model.errorText.length > 0 ? this.model.errorText : '发送失败')
            .fontSize(10)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '60%' })
            .fontColor(ChatUi.BUBBLE_ERROR)
        }
        Text(this.model.timeText)
          .fontSize(10)
          .fontColor(this.model.isOutgoing ? '#C9E1F8' : ChatUi.TEXT_SECONDARY)
        this.stateMark()
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(VerticalAlign.Center)
      .margin({ top: 2 })
    }
    .constraintSize({ maxWidth: '78%' })
    .padding({ left: 11, right: 11, top: 7, bottom: 7 })
    .borderRadius(12)
    .backgroundColor(this.model.isOutgoing ? ChatUi.BUBBLE_OUT : ChatUi.BUBBLE_IN)
    .onClick((): void => {
      // 失败气泡点击 = 重试（其余点击无动作；长按菜单 M5）
      if (this.model.sendState === BubbleSendState.FAILED && this.model.canRetry) {
        this.onRetry(this.model.messageId);
      }
    })
  }

  // ---------------- 点击动作 ----------------

  private handlePhotoClick(): void {
    // FAILED 补救（M3-media 复审修复）：图片为自动预载，失败后无自愈路径——点击重拉一次
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const fileId: number = this.model.photoFileId;
    if (fileId !== 0 && store.isFailed(fileId) && !store.isActive(fileId)) {
      store.downloadFile(fileId, DownloadPriority.USER_ACTION, 0, 0);
      this.refreshPhotoState();
      return;
    }
    const src: string = this.photoReady && this.photoUri.length > 0 ? this.photoUri : this.model.photoMini;
    if (src.length > 0) {
      this.onPhotoOpen(src);
    }
  }

  private handleVideoClick(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const fileId: number = this.model.videoFileId;
    if (fileId === 0) {
      return;
    }
    if (store.isReady(fileId)) {
      this.onVideoOpen(store.getLocalPath(fileId), this.model.videoFileName);
      return;
    }
    // 未就绪：触发/维持高优先下载，完成后观察者自动拉起播放
    if (!store.isActive(fileId) || store.isFailed(fileId)) {
      store.downloadFile(fileId, DownloadPriority.USER_ACTION, 0, 0);
    }
    this.videoRequested = true;
    this.videoDownloading = true;
    this.videoProgress = store.getProgress(fileId);
  }

  private handleDocumentClick(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const fileId: number = this.model.docFileId;
    if (fileId === 0) {
      return;
    }
    if (store.isReady(fileId)) {
      this.saveDocument();
      return;
    }
    if (!store.isActive(fileId) || store.isFailed(fileId)) {
      store.downloadFile(fileId, DownloadPriority.USER_ACTION, 0, 0);
    }
    this.docRequested = true;
    this.docState = DocActionState.DOWNLOADING;
    this.docProgress = store.getProgress(fileId);
  }

  /** 下载完成 → DocumentViewPicker 保存到用户目录 */
  private saveDocument(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const path: string = store.getLocalPath(this.model.docFileId);
    if (path.length === 0) {
      return;
    }
    const hostContext: Object | undefined = this.getUIContext().getHostContext();
    if (hostContext === undefined) {
      this.docState = DocActionState.FAILED;
      return;
    }
    const context: common.UIAbilityContext = hostContext as common.UIAbilityContext;
    this.docState = DocActionState.SAVING;
    MediaSaver.saveDocument(context, path, this.model.docFileName)
      .then((result: string): void => {
        if (result === SaveResult.SAVED) {
          this.docState = DocActionState.SAVED;
          this.docRequested = false;
        } else if (result === SaveResult.CANCELLED) {
          this.docState = DocActionState.READY;
          this.docRequested = false;
        } else {
          this.docState = DocActionState.FAILED;
        }
      })
      .catch((): void => {
        this.docState = DocActionState.FAILED;
      });
  }

  // ---------------- 下载态刷新 ----------------

  private refreshPhotoState(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const fileId: number = this.model.photoFileId;
    this.photoReady = fileId !== 0 && store.isReady(fileId);
    this.photoUri = this.photoReady ? store.getReadyUri(fileId) : '';
    this.photoProgress = fileId === 0 ? -1 : store.getProgress(fileId);
    this.photoFailed = fileId !== 0 && store.isFailed(fileId);
  }

  private refreshThumbState(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const fileId: number = this.model.videoThumbFileId;
    this.thumbReady = fileId !== 0 && store.isReady(fileId);
    this.thumbUri = this.thumbReady ? store.getReadyUri(fileId) : '';
  }

  private onVideoFileChanged(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const fileId: number = this.model.videoFileId;
    this.videoProgress = store.getProgress(fileId);
    this.videoDownloading = store.isActive(fileId);
    if (store.isReady(fileId) && this.videoRequested) {
      this.videoRequested = false;
      this.videoDownloading = false;
      this.onVideoOpen(store.getLocalPath(fileId), this.model.videoFileName);
    }
  }

  private onDocFileChanged(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const fileId: number = this.model.docFileId;
    this.docProgress = store.getProgress(fileId);
    if (store.isReady(fileId)) {
      if (this.docRequested) {
        this.saveDocument();
      } else {
        this.docState = DocActionState.READY;
      }
    } else if (store.isFailed(fileId)) {
      this.docState = DocActionState.FAILED;
    } else if (store.isActive(fileId)) {
      this.docState = DocActionState.DOWNLOADING;
    }
  }

  private refreshDocState(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const fileId: number = this.model.docFileId;
    if (fileId === 0) {
      return;
    }
    if (store.isReady(fileId)) {
      this.docState = DocActionState.READY;
    } else if (store.isActive(fileId)) {
      this.docState = DocActionState.DOWNLOADING;
    } else if (store.isFailed(fileId)) {
      this.docState = DocActionState.FAILED;
    } else {
      this.docState = DocActionState.IDLE;
    }
    this.docProgress = store.getProgress(fileId);
  }

  // ---------------- 展示辅助 ----------------

  /** 当前展示源：真图 > minithumbnail > 空（空走灰底占位） */
  private mediaSrc(): string {
    if (this.model.mediaKind === MediaKind.VIDEO) {
      if (this.thumbReady && this.thumbUri.length > 0) {
        return this.thumbUri;
      }
      return this.model.videoMini;
    }
    if (this.photoReady && this.photoUri.length > 0) {
      return this.photoUri;
    }
    return this.model.photoMini;
  }

  private mediaHeight(): number {
    let ratio: number = DEFAULT_ASPECT;
    if (this.model.mediaKind === MediaKind.VIDEO) {
      if (this.model.videoThumbWidth > 0 && this.model.videoThumbHeight > 0) {
        ratio = this.model.videoThumbWidth / this.model.videoThumbHeight;
      } else if (this.model.videoWidth > 0 && this.model.videoHeight > 0) {
        ratio = this.model.videoWidth / this.model.videoHeight; // 无 thumbnail：按本体原生比例（复审修复）
      }
    } else if (this.model.photoWidth > 0 && this.model.photoHeight > 0) {
      ratio = this.model.photoWidth / this.model.photoHeight;
    }
    if (!(ratio > 0.2 && ratio < 5)) {
      ratio = DEFAULT_ASPECT; // 极端长宽比（全景图/长截图）按默认，避免一行高柱
    }
    const height: number = MEDIA_WIDTH / ratio;
    return Math.min(height, MEDIA_MAX_HEIGHT);
  }

  /** 中心进度文案：图片在拉且未就绪显示百分比；视频仅在用户请求下载时显示 */
  private mediaProgressText(): string {
    if (this.model.mediaKind === MediaKind.VIDEO) {
      if (this.videoDownloading) {
        return this.videoProgress >= 0 ? `下载中 ${this.videoProgress}%` : '下载中…';
      }
      return '';
    }
    if (this.photoFailed && !this.photoReady) {
      return '下载失败 点击重试';
    }
    if (!this.photoReady && this.photoProgress >= 0) {
      return `${this.photoProgress}%`;
    }
    return '';
  }

  private docDisplayName(): string {
    return this.model.docFileName.length > 0 ? this.model.docFileName : '文件';
  }

  private docStatusText(): string {
    if (this.docState === DocActionState.DOWNLOADING) {
      return this.docProgress >= 0 ? `下载中 ${this.docProgress}%` : '下载中…';
    }
    if (this.docState === DocActionState.SAVING) {
      return '保存中…';
    }
    if (this.docState === DocActionState.SAVED) {
      return '已保存到用户目录';
    }
    if (this.docState === DocActionState.FAILED) {
      return '下载失败，点击重试';
    }
    if (this.docState === DocActionState.READY) {
      return this.model.docSizeText.length > 0 ? `${this.model.docSizeText} · 点击保存` : '点击保存';
    }
    return this.model.docSizeText.length > 0 ? `${this.model.docSizeText} · 点击下载` : '点击下载';
  }

  private docActionMark(): string {
    if (this.docState === DocActionState.DOWNLOADING) {
      return this.docProgress >= 0 ? `${this.docProgress}%` : '…';
    }
    if (this.docState === DocActionState.SAVING) {
      return '…';
    }
    if (this.docState === DocActionState.SAVED) {
      return '✓';
    }
    if (this.docState === DocActionState.FAILED) {
      return '!';
    }
    return '↓';
  }

  /** 状态角标：时钟 / 红色感叹号 / 单勾 / 双勾 */
  @Builder
  stateMark() {
    if (this.model.sendState === BubbleSendState.SENDING) {
      // 发送中：自绘小时钟（圆盘 + 指针），不依赖 emoji/符号资源
      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 11, height: 11 })
          .fill(Color.Transparent)
          .stroke(this.model.isOutgoing ? '#C9E1F8' : ChatUi.TEXT_SECONDARY)
          .strokeWidth(1)
        Rect({ width: 1, height: 3.5 })
          .fill(this.model.isOutgoing ? '#C9E1F8' : ChatUi.TEXT_SECONDARY)
          .offset({ x: 0, y: -2.2 })
        Rect({ width: 3, height: 1 })
          .fill(this.model.isOutgoing ? '#C9E1F8' : ChatUi.TEXT_SECONDARY)
          .offset({ x: 1.5, y: 0.5 })
      }
      .width(11)
      .height(11)
    } else if (this.model.sendState === BubbleSendState.FAILED) {
      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 13, height: 13 })
          .fill(ChatUi.BUBBLE_ERROR)
        Text('!')
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
      }
      .width(13)
      .height(13)
    } else if (this.model.sendState === BubbleSendState.SENT) {
      Text(this.model.isRead ? '✓✓' : '✓')
        .fontSize(11)
        // 已读双勾弱化为浅色（Telegram 语义：单勾=已送出，双勾=已读）
        .fontColor(this.model.isRead ? '#9AC3EC' : '#C9E1F8')
    }
  }
}
