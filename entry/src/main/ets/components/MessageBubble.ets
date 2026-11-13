/**
 * 消息气泡（M3 / M3-media / M5 富文本）：ChatPanel 消息流子组件。
 *
 * 分支结构（model.mediaKind）：
 * - photo：选中档（宽 ≤1080）下载完成前 minithumbnail（base64 data URI）立即显示，完成后换真图；
 *   无边框纯图 + 底部时间覆盖层；点击全屏预览（ChatPanel overlay）
 * - video：thumbnail（minithumbnail 先行）+ 播放按钮覆盖；点击触发下载（高优先），
 *   完成后自动拉起 AVPlayer 播放页
 * - document：文件名/大小 + 下载按钮；点击下载，完成自动走 DocumentViewPicker 保存到用户目录
 * - voice/animation/sticker/audio：占位文案（M5 实装），**占位不崩溃**
 * - 文本（默认）：formattedText 富文本渲染（M5）——entities 切分（RichText，UTF-16 code unit
 *   与 JS 字符串同基）→ Text 子 Span 样式（bold/italic/underline/strikethrough/code/链接色）；
 *   Url/TextUrl 切片可点击（stopPropagation 防误触气泡动作，openLink 拉起浏览器/深链）
 *
 * 下载状态：组件订阅 FileDownloadStore（onFileChanged → 本地 @State），
 * ForEach 键不含下载进度（避免整泡重建），气泡内部自刷新。
 *
 * 状态角标：发送中时钟 / 失败红色感叹号（点击重试）/ 已送出单勾 / 已读双勾。
 */
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { ChatUi } from '../pages/ChatUi';
import { MediaKind } from '../core/MessageContent';
import { RichSegment } from '../core/RichText';
import { FileDownloadStore, DownloadPriority } from '../core/FileDownloadStore';
import { MediaSaver, SaveResult } from '../core/MediaSaver';
import { AudioPlayerController, AudioSnapshot, AudioState } from '../core/AudioPlayerController';
import { MessageStore } from '../core/MessageStore';
import { TdType } from '../core/TdConstants';
import { PlayIcon, PauseIcon } from './Icons';

/** 媒体气泡展示尺寸（vp） */
const MEDIA_WIDTH: number = 240;
const MEDIA_MAX_HEIGHT: number = 320;
const DEFAULT_ASPECT: number = 4 / 3;
/** 消息编辑窗口（Telegram 文本消息 48h；超出服务端必拒，菜单项直接隐藏） */
const EDIT_WINDOW_SECONDS: number = 48 * 3600;

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
  /** M5 富文本：messageText 的 entities 样式切片（空 = 纯文本走原 Text 路径） */
  segments: Array<RichSegment> = [];
  /** photo/video/document 的 caption 样式切片（同上） */
  captionSegments: Array<RichSegment> = [];
  /** 富文本样式指纹（keySuffix 用：仅改 entity 不改文本的编辑也能触发重建） */
  styleKey: string = '';
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

  // ---------------- 语音/音频（M6-6） ----------------
  /** 所属会话（openMessageContent 上报用；buildBubble 填充） */
  chatId: number = 0;
  /** 语音：波形 base64（空 = 无波形降级） */
  voiceWaveform: string = '';
  /** 语音：未听蓝点 */
  voiceUnheard: boolean = false;
  /** 语音/音频时长文本（m:ss） */
  audioDurationText: string = '';
  /** 音频：标题（title - performer） */
  audioTitle: string = '';
  /** 语音/音频文件 id（下载+播放目标） */
  audioFileId: number = 0;

  // ---------------- 贴纸与 GIF（M6-7） ----------------
  /** 贴纸格式 @type（stickerFormatWebp 可直渲；tgs/webm 显示静态缩略+动效角标） */
  stickerFormat: string = '';
  stickerEmoji: string = '';
  stickerFileId: number = 0;
  stickerThumbFileId: number = 0;
  /** 贴纸原始尺寸（512 常见；展示 clamp 到 160vp 按比例） */
  stickerWidth: number = 0;
  stickerHeight: number = 0;
  /** GIF/动图本体 file id；animIsGif=true 时下载完成 Image 直渲自动播放 */
  animFileId: number = 0;
  animThumbFileId: number = 0;
  animMini: string = '';
  animIsGif: boolean = false;
  animWidth: number = 0;
  animHeight: number = 0;
  animFileName: string = '';

  // ---------------- 回复引用（M6-2） ----------------
  /** 被回复消息 id（0 = 无引用） */
  replyToMessageId: number = 0;
  /** 被回复消息所在会话（同会话=当前 chatId；跨会话引用显示来源名） */
  replyToChatId: number = 0;
  /** 引用条显示名（「你」/对方名/来源名；异步补拉后重建刷新） */
  replyToName: string = '';
  /** 引用条单行预览 */
  replyToPreview: string = '';
  /** 跳转高亮（M6-2/5：跳转目标短暂强调背景） */
  highlighted: boolean = false;
  // ---------------- 编辑与转发（M6-3） ----------------
  /** 已编辑标记（message.edit_date > 0；时间旁「已编辑」小字） */
  edited: boolean = false;
  /** 转发来源名（message.forward_info.origin；名称不可解析为空串，标签仍显示） */
  forwardFrom: string = '';
  /** 是否转发消息（forward_info 存在；标签渲染门控，与名称可解析性解耦——PR15 审计 P1-2） */
  forwarded: boolean = false;

  // ---------------- 消息分组与发送者（UI 打磨） ----------------
  /** 与前一条同组（同发送者 + <10min）：顶部间距收紧、上侧圆角收小 */
  groupedWithPrev: boolean = false;
  /** 与后一条同组：时间行隐藏（组尾才显示时间+状态） */
  groupedWithNext: boolean = false;
  /** 发送者分组键（'me' / 私聊 'peer' / 群聊 sender id 字符串；分组与头像判定共用） */
  senderKey: string = '';
  /** 群聊发送者昵称（groupStart 且非 outgoing 时渲染；空串不渲染） */
  senderName: string = '';
  /** 群聊发送者着色（uid/标题 hash → 色板，头像底色与昵称同色） */
  senderColor: string = '';
  /** 群聊发送者首字母（字母头像；空串用 #） */
  senderLetter: string = '';
  /** 私聊会话头像 file id（incoming 组尾渲染会话头像；0 无头像） */
  chatAvatarFileId: number = 0;
  chatAvatarMini: string = '';

  /** ForEach 键后缀：状态/已读/内容指纹任一变化即换键，强制重建气泡（编辑与发送状态机可见刷新） */
  keySuffix(): string {
    // 文本全量入键（M3 复审 MEDIUM 修复：同长度编辑如改错别字时 length 不变会漏刷新）；
    // M5 追加样式指纹：仅改 entity（换链接目标/加粗范围）而文本不变的编辑同样触发重建；
    // M6-2 追加引用字段（补拉源消息后引用条刷新）与高亮态；M6-3 追加已编辑/转发来源
    return `${this.messageId}_${this.sendState}_${this.isRead}_${this.text}_${this.errorText}` +
      `_${this.mediaKind}_${this.photoFileId}_${this.videoFileId}_${this.docFileId}_${this.caption}` +
      `_${this.styleKey}_${this.replyToMessageId}_${this.replyToPreview}_${this.highlighted}` +
      `_${this.edited}_${this.forwardFrom}_${this.voiceUnheard}_${this.stickerFileId}_${this.animFileId}` +
      `_${this.groupedWithPrev}_${this.groupedWithNext}_${this.senderName}_${this.senderColor}`;
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
  /** 回复动作回调（M6-2：进入回复模式，ChatPanel 挂引用预览条） */
  onReplyAction: (messageId: number) => void = (messageId: number): void => {
  };
  /** 删除动作回调（M6-2：弹删除方式选择，ChatPanel 处理） */
  onDeleteAction: (messageId: number) => void = (messageId: number): void => {
  };
  /** 引用条点击跳转回调（M6-2：滚动定位到被回复消息） */
  onReplyJump: (messageId: number) => void = (messageId: number): void => {
  };
  /** 编辑动作回调（M6-3：进入编辑模式） */
  onEditAction: (messageId: number) => void = (messageId: number): void => {
  };
  /** 转发动作回调（M6-3：打开转发目标选择器） */
  onForwardAction: (messageId: number) => void = (messageId: number): void => {
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
  // 语音/音频播放态（M6-6；AudioPlayerController 单例快照按 key 匹配刷新）
  @State voicePlaying: boolean = false;
  @State voicePositionMs: number = 0;
  @State voiceDurationMs: number = 0;
  @State voiceSpeed: number = 1;
  @State voiceFileReady: boolean = false;
  /** 本次展示周期内已上报过已听（openMessageContent 幂等去重） */
  private listenReported: boolean = false;
  // 贴纸/动图下载态（M6-7）
  @State stickerReady: boolean = false;
  @State stickerThumbReady: boolean = false;
  @State animReady: boolean = false;
  @State animThumbReady: boolean = false;
  /** 动图点击待播（下载完成自动接续：GIF 就地自动播 / 视频拉起播放器） */
  private animRequested: boolean = false;
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
    } else if (fileId === this.model.audioFileId && fileId !== 0) {
      this.onAudioFileChanged();
    } else if (fileId === this.model.stickerFileId && fileId !== 0) {
      this.stickerReady = FileDownloadStore.getInstance().isReady(fileId);
    } else if (fileId === this.model.stickerThumbFileId && fileId !== 0) {
      this.stickerThumbReady = FileDownloadStore.getInstance().isReady(fileId);
    } else if (fileId === this.model.animFileId && fileId !== 0) {
      this.onAnimFileChanged();
    } else if (fileId === this.model.animThumbFileId && fileId !== 0) {
      this.animThumbReady = FileDownloadStore.getInstance().isReady(fileId);
    }
  };

  private readonly audioObserver: (snapshot: AudioSnapshot) => void = (snapshot: AudioSnapshot): void => {
    if (snapshot.key !== this.audioKey()) {
      // 异 key 快照：复位本气泡全部播放态（互斥切换时停显/收滑条/复位倍速角标——PR18 审计 P2）
      this.voicePlaying = false;
      this.voicePositionMs = 0;
      this.voiceSpeed = 1;
      return;
    }
    this.voicePlaying = snapshot.state === AudioState.PLAYING;
    this.voicePositionMs = snapshot.positionMs;
    this.voiceDurationMs = snapshot.durationMs;
    this.voiceSpeed = snapshot.speed;
    if (this.voicePlaying && !this.listenReported && this.model.mediaKind === MediaKind.VOICE) {
      this.listenReported = true;
      MessageStore.getInstance().reportListened(this.model.chatId, this.model.messageId);
    }
  };

  aboutToAppear(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    store.addObserver(this.fileObserver);
    AudioPlayerController.getInstance().addObserver(this.audioObserver);
    this.refreshPhotoState();
    this.refreshThumbState();
    this.refreshDocState();
    this.refreshAudioState();
    const dlStore: FileDownloadStore = FileDownloadStore.getInstance();
    this.stickerReady = this.model.stickerFileId !== 0 && dlStore.isReady(this.model.stickerFileId);
    this.stickerThumbReady = this.model.stickerThumbFileId !== 0 && dlStore.isReady(this.model.stickerThumbFileId);
    this.animReady = this.model.animFileId !== 0 && dlStore.isReady(this.model.animFileId);
    this.animThumbReady = this.model.animThumbFileId !== 0 && dlStore.isReady(this.model.animThumbFileId);
    // 自动预载：图片选中档 + 视频封面 + 语音（未听优先；语音文件小，全量预载）
    if (this.model.photoFileId !== 0 && !store.isReady(this.model.photoFileId) &&
      !store.isFailed(this.model.photoFileId)) {
      store.downloadFile(this.model.photoFileId, DownloadPriority.PHOTO, 0, 0);
    }
    if (this.model.videoThumbFileId !== 0 && !store.isReady(this.model.videoThumbFileId) &&
      !store.isFailed(this.model.videoThumbFileId)) {
      store.downloadFile(this.model.videoThumbFileId, DownloadPriority.THUMBNAIL, 0, 0);
    }
    if (this.model.audioFileId !== 0 && !store.isReady(this.model.audioFileId) &&
      !store.isFailed(this.model.audioFileId)) {
      store.downloadFile(this.model.audioFileId, DownloadPriority.THUMBNAIL, 0, 0);
    }
    // 贴纸：仅 webp 预载本体（PR19 审计 P0-1——tgs/webm 本体不可 Image 解码，
    // 下载完会顶掉正常缩略图）；缩略图全格式低优预载；动图：缩略图预载，
    // 本体 GIF 低优预载（下载完自动播放），非 GIF（mp4）点击才拉
    if (this.model.stickerFormat === TdType.STICKER_FORMAT_WEBP && this.model.stickerFileId !== 0 &&
      !store.isReady(this.model.stickerFileId) && !store.isFailed(this.model.stickerFileId)) {
      store.downloadFile(this.model.stickerFileId, DownloadPriority.THUMBNAIL, 0, 0);
    }
    if (this.model.stickerThumbFileId !== 0 && !store.isReady(this.model.stickerThumbFileId) &&
      !store.isFailed(this.model.stickerThumbFileId)) {
      store.downloadFile(this.model.stickerThumbFileId, DownloadPriority.THUMBNAIL, 0, 0);
    }
    if (this.model.animThumbFileId !== 0 && !store.isReady(this.model.animThumbFileId) &&
      !store.isFailed(this.model.animThumbFileId)) {
      store.downloadFile(this.model.animThumbFileId, DownloadPriority.THUMBNAIL, 0, 0);
    }
    if (this.model.animIsGif && this.model.animFileId !== 0 && !store.isReady(this.model.animFileId) &&
      !store.isFailed(this.model.animFileId)) {
      store.downloadFile(this.model.animFileId, DownloadPriority.THUMBNAIL, 0, 0);
    }
  }

  aboutToDisappear(): void {
    FileDownloadStore.getInstance().removeObserver(this.fileObserver);
    AudioPlayerController.getInstance().removeObserver(this.audioObserver);
  }

  build() {
    Row({ space: 8 }) {
      if (this.model.isOutgoing) {
        Blank()
          .layoutWeight(1)
      }
      // incoming 侧发送者信息列（UI 打磨）：组尾头像（私聊=会话头像/群聊=首字母着色圆）
      if (!this.model.isOutgoing) {
        this.senderAvatar()
      }
      Column() {
        // 群聊发送者昵称（组首着色，仅非私聊 + incoming + 组首）
        if (!this.model.isOutgoing && this.model.senderName.length > 0 && !this.model.groupedWithPrev) {
          Text(this.model.senderName)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.model.senderColor.length > 0 ? this.model.senderColor : ChatUi.TEXT_SECONDARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 6, bottom: 2 })
        }
        // 转发来源标签（M6-3）：forward_info 存在即显示（名称不可解析时仅「转发的消息」）
        if (this.model.forwarded) {
          Text(this.model.forwardFrom.length > 0 ? `转发的消息：${this.model.forwardFrom}` : '转发的消息')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.model.isOutgoing ? '#C9E1F8' : ChatUi.ACCENT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 8, right: 8, top: 6 })
        }
        // 回复引用条（M6-2）：所有气泡类型统一置顶
        if (this.model.replyToMessageId !== 0) {
          this.replyQuoteBar()
        }
        if (this.model.mediaKind === MediaKind.PHOTO || this.model.mediaKind === MediaKind.VIDEO) {
          this.mediaBubble()
        } else if (this.model.mediaKind === MediaKind.DOCUMENT) {
          this.documentBubble()
        } else if (this.model.mediaKind === MediaKind.VOICE || this.model.mediaKind === MediaKind.AUDIO) {
          this.voiceBubble()
        } else if (this.model.mediaKind === MediaKind.STICKER) {
          this.stickerBubble()
        } else if (this.model.mediaKind === MediaKind.ANIMATION) {
          this.animationBubble()
        } else {
          this.textBubble()
        }
      }
      // 外层不设 maxWidth（PR14 审计 P2-①）：Column 收敛到气泡宽度，引用条 width('100%')
      // 与气泡对齐；避免外层百分比与气泡自身 78% 嵌套把文本气泡压到 ~61% 行宽
      .borderRadius(13)
      .alignItems(HorizontalAlign.Start)
      // 分组间距（UI 打磨）：组内 2、跨组 10
      .margin({ top: this.model.groupedWithPrev ? 1 : 10 })
      // 跳转高亮（M6-2/5）：短暂强调背景色（与气泡自身底色叠加由透明度保证可辨识）
      .backgroundColor(this.model.highlighted ? ChatUi.HIGHLIGHT_BG : Color.Transparent)
      if (!this.model.isOutgoing) {
        Blank()
          .layoutWeight(1)
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 0, bottom: 0 })
    // 消息上下文菜单（M6-2）：长按（触屏/触控板）与右键（PC 鼠标）双入口，沿 Index 会话菜单模式
    .bindContextMenu(this.bubbleMenu(), ResponseType.LongPress)
    .bindContextMenu(this.bubbleMenu(), ResponseType.RightClick)
  }

  /**
   * incoming 侧头像（UI 打磨）：
   * - 组尾（!groupedWithNext）才渲染 34vp 头像（Telegram 桌面版语义），组内其余占位 34vp 保持缩进；
   * - 私聊：会话头像（chatAvatarFileId 下载 / mini / 首字母色环三级）；
   * - 群聊：发送者首字母 + senderColor 着色圆（精确头像挂 M7 用户头像体系）。
   * 头像自带 34vp 宽度，不与 Row space 叠加额外空隙。
   */
  @Builder
  senderAvatar() {
    Column() {
      Blank()
        .layoutWeight(1)
      if (!this.model.groupedWithNext) {
        Stack() {
          Circle({ width: 34, height: 34 })
            .fill(this.model.senderColor.length > 0 ? this.model.senderColor : ChatUi.avatarColor(this.model.chatId))
          if (this.senderAvatarSrc().length > 0) {
            Image(this.senderAvatarSrc())
              .width(34)
              .height(34)
              .borderRadius(17)
              .clip(true)
          } else {
            Text(this.model.senderLetter.length > 0 ? this.model.senderLetter : '#')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
          }
        }
        .width(34)
        .height(34)
      }
    }
    .width(34)
    .constraintSize({ minHeight: 34 })
  }

  /** 私聊会话头像源：下载完成 file URI > minithumbnail（群聊返回空走字母圆） */
  private senderAvatarSrc(): string {
    if (this.model.chatAvatarFileId === 0) {
      return '';
    }
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    if (store.isReady(this.model.chatAvatarFileId)) {
      return store.getReadyUri(this.model.chatAvatarFileId);
    }
    return this.model.chatAvatarMini.length > 0 ? `data:image/jpeg;base64,${this.model.chatAvatarMini}` : '';
  }

  /**
   * 组合圆角（UI 打磨）：基准 12；组内相邻侧收小到 4（贴近 Telegram 消息串联视觉）。
   * incoming 收左上/左下，outgoing 收右上/右下。
   */
  private groupedRadius(): BorderRadiuses {
    const r: number = 12;
    const s: number = 4;
    // incoming 收左上/左下，outgoing 收右上/右下（组内相邻侧 4；BorderRadiuses 为对象接口）
    const tl: number = !this.model.isOutgoing && this.model.groupedWithPrev ? s : r;
    const tr: number = this.model.isOutgoing && this.model.groupedWithPrev ? s : r;
    const br: number = this.model.isOutgoing && this.model.groupedWithNext ? s : r;
    const bl: number = !this.model.isOutgoing && this.model.groupedWithNext ? s : r;
    const radius: BorderRadiuses = { topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl };
    return radius;
  }

  /** outgoing 垂直渐变蓝（UI 打磨）；incoming 纯色（保持原观感，由发丝边提层次） */
  private bubbleGradient(): LinearGradientOptions {
    const stops: Array<[ResourceColor, number]> = this.model.isOutgoing
      ? [['#4FA3F5', 0], ['#2E7BE6', 1]]
      : [['#242F3D', 0], ['#242F3D', 1]];
    return { angle: 180, colors: stops };
  }

  /** incoming 发丝描边（outgoing 无边框） */
  private bubbleBorder(): BorderOptions {
    if (this.model.isOutgoing) {
      return { width: 0 };
    }
    return { width: 0.5, color: '#14FFFFFF' };
  }

  /** 回复引用条：来源名 + 单行预览 + 左侧强调竖线；点击跳转源消息 */  @Builder
  replyQuoteBar() {
    Row({ space: 6 }) {
      Column()
        .width(3)
        .height(30)
        .borderRadius(2)
        .backgroundColor(this.model.isOutgoing ? '#C9E1F8' : ChatUi.ACCENT)
      Column({ space: 1 }) {
        Text(this.model.replyToName.length > 0 ? this.model.replyToName : '消息')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.model.isOutgoing ? '#C9E1F8' : ChatUi.ACCENT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.model.replyToPreview.length > 0 ? this.model.replyToPreview : '加载中…')
          .fontSize(12)
          .fontColor(this.model.isOutgoing ? '#DCE9F7' : ChatUi.TEXT_SECONDARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 8, right: 8, top: 6, bottom: 2 })
    .onClick((): void => {
      this.onReplyJump(this.model.replyToMessageId);
    })
  }

  /**
   * 消息上下文菜单（M6-2 建立，M6-3 增编辑/转发）。
   * 复制直接走系统剪贴板（文本优先，媒体消息回退 caption，均无则菜单项禁用态文案）。
   * 编辑可用性客户端判定：自己发的 + 48h 内 + 有文本或 caption（服务端拒绝时 toast 透传，
   * getMessageProperties.can_be_edited 精确判定登记 M7 精化）。
   */
  @Builder
  bubbleMenu() {
    Menu() {
      MenuItem({ content: '回复' })
        .contentFontColor(ChatUi.TEXT_PRIMARY)
        .onClick((): void => {
          this.onReplyAction(this.model.messageId);
        })
      if (this.editable()) {
        MenuItem({ content: '编辑' })
          .contentFontColor(ChatUi.TEXT_PRIMARY)
          .onClick((): void => {
            this.onEditAction(this.model.messageId);
          })
      }
      MenuItem({ content: '转发' })
        .contentFontColor(ChatUi.TEXT_PRIMARY)
        .onClick((): void => {
          this.onForwardAction(this.model.messageId);
        })
      if (this.copyableText().length > 0) {
        MenuItem({ content: '复制' })
          .contentFontColor(ChatUi.TEXT_PRIMARY)
          .onClick((): void => {
            this.copyToClipboard();
          })
      }
      MenuItem({ content: '删除' })
        .contentFontColor(ChatUi.BUBBLE_ERROR)
        .onClick((): void => {
          this.onDeleteAction(this.model.messageId);
        })
    }
    // 应用为固定深色视觉，Menu 默认底色跟随系统会跳浅色——显式对齐列表底色
    .backgroundColor(ChatUi.LIST_BG)
    .radius(12)
  }

  /** 编辑可用性：自己发的 + 48h 编辑窗内 + 有可编辑文本（正文或 caption） */
  private editable(): boolean {
    if (!this.model.isOutgoing || this.model.messageId <= 0) {
      return false;
    }
    if (this.copyableText().length === 0) {
      return false;
    }
    const ageSeconds: number = Math.floor(Date.now() / 1000) - this.model.dateSeconds;
    return ageSeconds >= 0 && ageSeconds < EDIT_WINDOW_SECONDS;
  }

  /** 可复制文本：消息正文 > 媒体 caption > 空（空则不出菜单项） */
  private copyableText(): string {
    if (this.model.text.length > 0) {
      return this.model.text;
    }
    return this.model.caption;
  }

  private copyToClipboard(): void {
    const text: string = this.copyableText();
    if (text.length === 0) {
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).catch((): void => {
    });
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
              PlayIcon({ iconSize: 18, iconColor: '#FFFFFF' })
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
          Column() {
            this.richBody(this.model.captionSegments, this.model.caption, 14, 20)
          }
          .alignItems(HorizontalAlign.Start)
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
      if (this.consumeLinkClick()) {
        return; // 链接切片点击已消费（见 linkClickConsumed 注释）
      }
      if (this.model.mediaKind === MediaKind.VIDEO) {
        this.handleVideoClick();
      } else {
        this.handlePhotoClick();
      }
    })
  }

  // ---------------- 语音/音频气泡（M6-6） ----------------

  /**
   * 语音/音频播放气泡：波形（或音频标题行）+ 播放/暂停 + 进度 + 倍速 + 未听蓝点。
   * 点击整泡：文件未就绪 → 高优下载（完成自动开播）；就绪 → toggle 播放/暂停。
   * 倍速角标：独立点击（不冒泡切播）。进度条 Slider 拖动 seek。
   */
  @Builder
  voiceBubble() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle({ width: 38, height: 38 })
            .fill(this.model.isOutgoing ? '#4DFFFFFF' : ChatUi.SEARCH_BG)
          if (this.voicePlaying) {
            PauseIcon({ iconSize: 13, iconColor: this.model.isOutgoing ? '#FFFFFF' : ChatUi.ACCENT })
          } else {
            PlayIcon({ iconSize: 14, iconColor: this.model.isOutgoing ? '#FFFFFF' : ChatUi.ACCENT })
          }
        }
        .width(38)
        .height(38)
        .onClick((): void => {
          this.handleVoiceClick();
        })

        Column({ space: 3 }) {
          if (this.model.mediaKind === MediaKind.AUDIO && this.model.audioTitle.length > 0) {
            Text(this.model.audioTitle)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.model.isOutgoing ? '#FFFFFF' : ChatUi.TEXT_PRIMARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          if (this.voiceBars().length > 0) {
            // 波形条：已播段强调色 / 未播段次级色（progress 比例着色）
            Row({ space: 2 }) {
              ForEach(this.voiceBars(), (bar: number, index: number) => {
                Column()
                  .width(3)
                  .height(this.voiceBarHeight(bar))
                  .borderRadius(1)
                  .backgroundColor(this.voiceBarPlayed(index) ?
                    (this.model.isOutgoing ? '#FFFFFF' : ChatUi.ACCENT) :
                    (this.model.isOutgoing ? '#80FFFFFF' : ChatUi.TEXT_SECONDARY))
              }, (bar: number, index: number) => `${index}_${bar}_${this.voiceBarPlayed(index)}`)
            }
            .height(30)
            .alignItems(VerticalAlign.Center)
          } else if (this.model.mediaKind === MediaKind.AUDIO) {
            // 音频无波形：时长条降级
            Text(this.model.audioDurationText)
              .fontSize(12)
              .fontColor(this.model.isOutgoing ? '#DCE9F7' : ChatUi.TEXT_SECONDARY)
          }
          Row({ space: 8 }) {
            Text(this.voiceTimeText())
              .fontSize(11)
              .fontColor(this.model.isOutgoing ? '#C9E1F8' : ChatUi.TEXT_SECONDARY)
            if (this.voicePlaying || this.voiceSpeed !== 1) {
              Text(`${this.voiceSpeed}x`)
                .fontSize(11)
                .fontColor(this.model.isOutgoing ? '#C9E1F8' : ChatUi.ACCENT)
                .onClick((): void => {
                  AudioPlayerController.getInstance().cycleSpeed(this.audioKey());
                })
            }
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // 未听蓝点（语音；播放过即上报 openMessageContent 后由 update 刷新消失）
        if (this.model.voiceUnheard) {
          Circle({ width: 8, height: 8 })
            .fill(ChatUi.ACCENT)
            .margin({ left: 4 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.voicePlaying || this.voicePositionMs > 0) {
        Slider({
          value: this.voicePositionMs,
          min: 0,
          max: this.voiceDurationMs > 0 ? this.voiceDurationMs : 1,
          step: 500
        })
          .blockColor(ChatUi.ACCENT)
          .selectedColor(ChatUi.ACCENT)
          .trackColor(this.model.isOutgoing ? '#80FFFFFF' : ChatUi.SEARCH_BG)
          .height(18)
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (mode === SliderChangeMode.End) {
              AudioPlayerController.getInstance().seek(this.audioKey(), value);
            }
          })
      }

      if (!this.model.groupedWithNext || this.model.sendState === BubbleSendState.FAILED) {
        Row({ space: 4 }) {
        if (this.model.sendState === BubbleSendState.FAILED) {
          Text(this.model.errorText.length > 0 ? this.model.errorText : '发送失败')
            .fontSize(10)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '60%' })
            .fontColor(ChatUi.BUBBLE_ERROR)
        }
        if (this.model.edited) {
          Text('已编辑')
            .fontSize(10)
            .fontColor(this.model.isOutgoing ? '#C9E1F8' : ChatUi.TEXT_SECONDARY)
        }
        Text(this.model.timeText)
          .fontSize(10)
          .fontColor(this.model.isOutgoing ? '#C9E1F8' : ChatUi.TEXT_SECONDARY)
        this.stateMark()
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(VerticalAlign.Center)
      }
    }
    .constraintSize({ maxWidth: '78%' })
    .padding({ left: 11, right: 11, top: 7, bottom: 7 })
    .borderRadius(this.groupedRadius())
    .backgroundColor(this.model.isOutgoing ? ChatUi.BUBBLE_OUT : ChatUi.BUBBLE_IN)
    // UI 打磨：outgoing 垂直渐变蓝（覆盖底色）；incoming 发丝描边提层次
    .linearGradient(this.bubbleGradient())
    .border(this.bubbleBorder())
    .shadow({ radius: 8, color: '#3D000000', offsetX: 0, offsetY: 2 })
  }

  /** 播放目标 key（chatId:messageId；AudioPlayerController 互斥匹配用） */
  private audioKey(): string {
    return `${this.model.chatId}:${this.model.messageId}`;
  }

  private handleVoiceClick(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const fileId: number = this.model.audioFileId;
    if (fileId === 0) {
      return;
    }
    if (store.isReady(fileId)) {
      AudioPlayerController.getInstance().toggle(this.audioKey(), store.getLocalPath(fileId));
      return;
    }
    if (!store.isActive(fileId) || store.isFailed(fileId)) {
      store.downloadFile(fileId, DownloadPriority.USER_ACTION, 0, 0);
    }
    // 点击触发下载 → 完成后自动开播（onAudioFileChanged 消费）
    this.voicePendingPlay = true;
  }

  private onAudioFileChanged(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    this.voiceFileReady = store.isReady(this.model.audioFileId);
    // 用户点击触发的下载完成 → 自动开播（videoRequested 同思路的本地标志）
    if (this.voiceFileReady && this.voicePendingPlay) {
      this.voicePendingPlay = false;
      AudioPlayerController.getInstance().toggle(this.audioKey(), store.getLocalPath(this.model.audioFileId));
    }
  }

  private voicePendingPlay: boolean = false;

  private refreshAudioState(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    this.voiceFileReady = this.model.audioFileId !== 0 && store.isReady(this.model.audioFileId);
    const controller: AudioPlayerController = AudioPlayerController.getInstance();
    if (controller.getActiveKey() === this.audioKey()) {
      this.voicePlaying = controller.getState() === AudioState.PLAYING;
    }
  }

  /**
   * 波形解码：base64 → 连续 5bit LSB 位流样本（第 i 个样本 bit 偏移 = i*5，跨字节拼接）
   * → 归一化到 4..28vp 条高，重采样为 ~44 根。PR 计划审计 R2 P1-4 修正算法。
   */
  private static decodeWaveform(waveform: string): Array<number> {
    if (waveform.length === 0) {
      return [];
    }
    let bytes: Uint8Array;
    try {
      const helper: util.Base64Helper = new util.Base64Helper();
      bytes = helper.decodeSync(waveform);
    } catch (err) {
      return [];
    }
    const totalBits: number = bytes.length * 8;
    const sampleCount: number = Math.floor(totalBits / 5);
    if (sampleCount === 0) {
      return [];
    }
    const samples: Array<number> = new Array<number>();
    for (let i: number = 0; i < sampleCount; i++) {
      const bitOffset: number = i * 5;
      const byteIndex: number = bitOffset >> 3;
      const bitInByte: number = bitOffset & 7;
      let value: number = bytes[byteIndex] >> bitInByte;
      const spill: number = bitInByte + 5 - 8;
      if (spill > 0 && byteIndex + 1 < bytes.length) {
        value |= bytes[byteIndex + 1] << (8 - bitInByte);
      }
      samples.push(value & 0x1F);
    }
    return samples;
  }

  /** 波形重采样为展示条（归一化 4..28vp 高度；最多 44 根） */
  private voiceBars(): Array<number> {
    if (this.model.voiceWaveform.length === 0) {
      return [];
    }
    if (this.voiceBarCache === null) {
      const samples: Array<number> = MessageBubble.decodeWaveform(this.model.voiceWaveform);
      const targetCount: number = Math.min(44, samples.length);
      if (targetCount === 0) {
        this.voiceBarCache = [];
        return this.voiceBarCache;
      }
      const groupSize: number = samples.length / targetCount;
      const bars: Array<number> = new Array<number>();
      for (let i: number = 0; i < targetCount; i++) {
        let max: number = 0;
        const start: number = Math.floor(i * groupSize);
        const end: number = Math.min(samples.length, Math.floor((i + 1) * groupSize));
        for (let j: number = start; j < end; j++) {
          if (samples[j] > max) {
            max = samples[j];
          }
        }
        // 归一化：5bit 值域 0..31 → 4..28vp
        bars.push(4 + Math.round(max * 24 / 31));
      }
      this.voiceBarCache = bars;
    }
    return this.voiceBarCache;
  }

  private voiceBarCache: Array<number> | null = null;

  private voiceBarHeight(bar: number): number {
    return bar;
  }

  /** 第 index 根是否已播（进度比例着色） */
  private voiceBarPlayed(index: number): boolean {
    const bars: Array<number> = this.voiceBars();
    if (bars.length === 0 || this.voiceDurationMs <= 0) {
      return false;
    }
    const ratio: number = this.voicePositionMs / this.voiceDurationMs;
    return index / bars.length <= ratio;
  }

  /** 播放时间文本（播放中 显示 已播/总长；静止显示总长） */
  private voiceTimeText(): string {
    // 总长未知（prepared 前无 duration）：降级显示消息自带时长文本
    if (this.model.audioDurationText.length > 0 && this.voiceDurationMs <= 0) {
      return this.model.audioDurationText;
    }
    const total: number = this.voiceDurationMs > 0 ? this.voiceDurationMs : this.parseDurationText();
    const played: number = Math.min(this.voicePositionMs, total > 0 ? total : this.voicePositionMs);
    const playedText: string = MessageBubble.formatMs(played);
    if (this.voicePlaying && total > 0) {
      return `${playedText} / ${MessageBubble.formatMs(total)}`;
    }
    if (total > 0) {
      return MessageBubble.formatMs(total);
    }
    return this.model.audioDurationText;
  }

  /** audioDurationText（m:ss）→ 毫秒（时长未知时估算进度用） */
  private parseDurationText(): number {
    const parts: Array<string> = this.model.audioDurationText.split(':');
    if (parts.length === 2) {
      const minutes: number = Number(parts[0]);
      const seconds: number = Number(parts[1]);
      if (Number.isFinite(minutes) && Number.isFinite(seconds)) {
        return Math.floor((minutes * 60 + seconds) * 1000);
      }
    }
    return 0;
  }

  private static formatMs(ms: number): string {
    const totalSeconds: number = Math.floor(ms / 1000);
    const minutes: number = Math.floor(totalSeconds / 60);
    const seconds: number = totalSeconds % 60;
    return `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`;
  }

  // ---------------- 贴纸与 GIF 气泡（M6-7） ----------------

  /** 贴纸展示尺寸：clamp 160vp 等比（原图 512 常见） */
  private stickerDisplaySize(): number {
    const w: number = this.model.stickerWidth > 0 ? this.model.stickerWidth : 512;
    const h: number = this.model.stickerHeight > 0 ? this.model.stickerHeight : 512;
    return Math.min(160, Math.max(96, Math.round(Math.min(w, h) * 160 / 512)));
  }

  /**
   * 贴纸气泡（无气泡底板）：webp 直渲；tgs/webm 静态缩略图 + 右下「动效」角标
   * （动画渲染挂 M7：tgs 需 lottie 依赖、webm 需 AVPlayer VP9 验证，本批不冒进）。
   */
  @Builder
  stickerBubble() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (this.stickerImageSrc().length > 0) {
        Image(this.stickerImageSrc())
          .width(this.stickerDisplaySize())
          .height(this.stickerDisplaySize())
          .objectFit(ImageFit.Contain)
          .onClick((): void => {
            this.handleStickerClick();
          })
      } else {
        Stack({ alignContent: Alignment.Center }) {
          Text(this.model.stickerEmoji.length > 0 ? this.model.stickerEmoji : '[贴纸]')
            .fontSize(this.model.stickerEmoji.length > 0 ? 40 : 13)
            .fontColor(ChatUi.TEXT_SECONDARY)
        }
        .width(this.stickerDisplaySize())
        .height(this.stickerDisplaySize())
        .borderRadius(12)
        .backgroundColor(ChatUi.SEARCH_BG)
        .onClick((): void => {
          this.handleStickerClick();
        })
      }
      if (this.model.stickerFormat !== '' && this.model.stickerFormat !== TdType.STICKER_FORMAT_WEBP) {
        Text('动效')
          .fontSize(9)
          .fontColor('#FFFFFF')
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .borderRadius(7)
          .backgroundColor('#88000000')
          .margin(4)
      }
    }
  }

  /** 贴纸当前展示源：本体（仅 webp 可解码，PR19 审计 P0-1）> 缩略图（tgs/webm 占位）> 空 */
  private stickerImageSrc(): string {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    if (this.model.stickerFormat === TdType.STICKER_FORMAT_WEBP && this.stickerReady) {
      const uri: string = store.getReadyUri(this.model.stickerFileId);
      if (uri.length > 0) {
        return uri;
      }
    }
    if (this.stickerThumbReady) {
      const uri: string = store.getReadyUri(this.model.stickerThumbFileId);
      if (uri.length > 0) {
        return uri;
      }
    }
    return '';
  }

  /** 贴纸加载失败重拉（点击兜底，沿图片 FAILED 补救思路；本体仅 webp 可拉） */
  private handleStickerClick(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    if (this.stickerImageSrc().length > 0) {
      return;
    }
    if (this.model.stickerFormat === TdType.STICKER_FORMAT_WEBP && this.model.stickerFileId !== 0 &&
      store.isFailed(this.model.stickerFileId) && !store.isActive(this.model.stickerFileId)) {
      store.downloadFile(this.model.stickerFileId, DownloadPriority.USER_ACTION, 0, 0);
      return;
    }
    if (this.model.stickerThumbFileId !== 0 && store.isFailed(this.model.stickerThumbFileId) &&
      !store.isActive(this.model.stickerThumbFileId)) {
      store.downloadFile(this.model.stickerThumbFileId, DownloadPriority.USER_ACTION, 0, 0);
    }
  }

  /** 动图展示尺寸：clamp 240x320（沿媒体气泡上限，宽高比保持） */
  private animDisplayWidth(): number {
    return Math.min(240, Math.max(120, this.model.animWidth > 0 ? this.model.animWidth / 2 : 240));
  }

  private animDisplayHeight(): number {
    const aspect: number = this.model.animWidth > 0 && this.model.animHeight > 0 ?
      this.model.animHeight / this.model.animWidth : 1;
    return Math.min(320, Math.max(120, Math.round(this.animDisplayWidth() * aspect)));
  }

  /**
   * GIF/动图气泡：image/gif 下载完成 Image 直渲自动播放（ArkUI 原生 GIF 解码）；
   * 其余（video/mp4 十or 等）缩略图 + 播放按钮 → 下载完成拉起 VideoPlayCover。
   */
  @Builder
  animationBubble() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
      if (this.animImageSrc().length > 0) {
        Image(this.animImageSrc())
          .width(this.animDisplayWidth())
          .height(this.animDisplayHeight())
          .objectFit(ImageFit.Cover)
          .borderRadius(12)
          .clip(true)
          .onClick((): void => {
            this.handleAnimClick();
          })
      } else {
        Stack({ alignContent: Alignment.Center }) {
          Text('[动图]')
            .fontSize(13)
            .fontColor(ChatUi.TEXT_SECONDARY)
        }
        .width(this.animDisplayWidth())
        .height(this.animDisplayHeight())
        .borderRadius(12)
        .backgroundColor(ChatUi.SEARCH_BG)
        .onClick((): void => {
          this.handleAnimClick();
        })
      }

      // 非 GIF（需播放器）或 GIF 未就绪时：播放按钮覆盖（GIF 已就绪直渲不显示按钮）
      if (!(this.model.animIsGif && this.animReady)) {
        Stack({ alignContent: Alignment.Center }) {
          Circle({ width: 42, height: 42 })
            .fill('#66000000')
          PlayIcon({ iconSize: 16, iconColor: '#FFFFFF' })
        }
        .width(42)
        .height(42)
        .onClick((): void => {
          this.handleAnimClick();
        })
      }
      }

      // caption（PR19 审计 P1-1：媒体气泡均应渲染 caption）
      if (this.model.caption.length > 0) {
        Column() {
          this.richBody(this.model.captionSegments, this.model.caption, 14, 20)
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 4, left: 4, right: 4 })
      }
    }
    .alignItems(HorizontalAlign.Start)
  }

  /** 动图当前展示源：GIF 本体 > 缩略图 > minithumbnail > 空 */
  private animImageSrc(): string {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    if (this.model.animIsGif && this.animReady) {
      const uri: string = store.getReadyUri(this.model.animFileId);
      if (uri.length > 0) {
        return uri;
      }
    }
    if (this.animThumbReady) {
      const uri: string = store.getReadyUri(this.model.animThumbFileId);
      if (uri.length > 0) {
        return uri;
      }
    }
    return this.model.animMini.length > 0 ? `data:image/jpeg;base64,${this.model.animMini}` : '';
  }

  private handleAnimClick(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const fileId: number = this.model.animFileId;
    if (fileId === 0) {
      return;
    }
    if (store.isReady(fileId)) {
      if (this.model.animIsGif) {
        return; // GIF 已在播（Image 直渲），无进一步动作
      }
      this.onVideoOpen(store.getLocalPath(fileId), this.model.animFileName.length > 0 ? this.model.animFileName : '动图');
      return;
    }
    if (!store.isActive(fileId) || store.isFailed(fileId)) {
      store.downloadFile(fileId, DownloadPriority.USER_ACTION, 0, 0);
    }
    this.animRequested = true;
  }

  private onAnimFileChanged(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    this.animReady = store.isReady(this.model.animFileId);
    if (this.animReady && this.animRequested) {
      this.animRequested = false;
      if (!this.model.animIsGif) {
        this.onVideoOpen(store.getLocalPath(this.model.animFileId),
          this.model.animFileName.length > 0 ? this.model.animFileName : '动图');
      }
      // GIF：animReady 置位后 animImageSrc 切本体，自动播放（无需动作）
    }
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
        Column() {
          this.richBody(this.model.captionSegments, this.model.caption, 14, 20)
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 4 })
      }

      if (!this.model.groupedWithNext || this.model.sendState === BubbleSendState.FAILED) {
        Row({ space: 4 }) {
        if (this.model.sendState === BubbleSendState.FAILED) {
          Text(this.model.errorText.length > 0 ? this.model.errorText : '发送失败')
            .fontSize(10)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '60%' })
            .fontColor(ChatUi.BUBBLE_ERROR)
        }
        if (this.model.edited) {
          Text('已编辑')
            .fontSize(10)
            .fontColor(this.model.isOutgoing ? '#C9E1F8' : ChatUi.TEXT_SECONDARY)
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
    }
    .constraintSize({ maxWidth: '78%' })
    .padding({ left: 11, right: 11, top: 7, bottom: 7 })
    .borderRadius(this.groupedRadius())
    .backgroundColor(this.model.isOutgoing ? ChatUi.BUBBLE_OUT : ChatUi.BUBBLE_IN)
    // UI 打磨：outgoing 垂直渐变蓝（覆盖底色）；incoming 发丝描边提层次
    .linearGradient(this.bubbleGradient())
    .border(this.bubbleBorder())
    .shadow({ radius: 8, color: '#3D000000', offsetX: 0, offsetY: 2 })
    .onClick((): void => {
      if (this.consumeLinkClick()) {
        return; // 链接切片点击已消费（见 linkClickConsumed 注释）
      }
      this.handleDocumentClick();
    })
  }

  // ---------------- 文本 / 占位气泡（原路径） ----------------

  @Builder
  textBubble() {
    Column() {
      if (this.model.text.length > 0) {
        this.richBody(this.model.segments, this.model.text, 15, 21)
      } else {
        // 媒体类型占位（语音/动图/贴纸 M5 实装）或未知类型兜底——占位不崩溃
        Text(this.model.placeholder.length > 0 ? this.model.placeholder : '[暂不支持的消息类型]')
          .fontSize(13)
          .fontColor(this.model.isOutgoing ? '#DCE9F7' : ChatUi.TEXT_SECONDARY)
      }
      if (!this.model.groupedWithNext || this.model.sendState === BubbleSendState.FAILED) {
        Row({ space: 4 }) {
        if (this.model.sendState === BubbleSendState.FAILED) {
          Text(this.model.errorText.length > 0 ? this.model.errorText : '发送失败')
            .fontSize(10)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '60%' })
            .fontColor(ChatUi.BUBBLE_ERROR)
        }
        if (this.model.edited) {
          Text('已编辑')
            .fontSize(10)
            .fontColor(this.model.isOutgoing ? '#C9E1F8' : ChatUi.TEXT_SECONDARY)
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
    }
    .constraintSize({ maxWidth: '78%' })
    .padding({ left: 11, right: 11, top: 7, bottom: 7 })
    .borderRadius(this.groupedRadius())
    .backgroundColor(this.model.isOutgoing ? ChatUi.BUBBLE_OUT : ChatUi.BUBBLE_IN)
    // UI 打磨：outgoing 垂直渐变蓝（覆盖底色）；incoming 发丝描边提层次
    .linearGradient(this.bubbleGradient())
    .border(this.bubbleBorder())
    .shadow({ radius: 8, color: '#3D000000', offsetX: 0, offsetY: 2 })
    .onClick((): void => {
      if (this.consumeLinkClick()) {
        return; // 链接切片点击已消费（见 linkClickConsumed 注释）
      }
      // 失败气泡点击 = 重试（其余点击无动作；长按菜单 M5）
      if (this.model.sendState === BubbleSendState.FAILED && this.model.canRetry) {
        this.onRetry(this.model.messageId);
      }
    })
  }

  // ---------------- 富文本渲染（M5：entities → Text 子 Span） ----------------

  /**
   * 富文本/纯文本统一渲染入口：
   * - 无样式（无 entities 或全部为普通切片）→ 单 Text 纯文本（原路径，零开销）；
   * - 有样式 → Text 内 ForEach Span 切片（Span 属性显式全量设置：不依赖父 Text 继承，
   *   基色/装饰按切片样式计算）。
   * Span 仅支持 onClick/onHover 两个通用事件（官方 span.d.ts 声明），链接点击经
   * stopPropagation 阻断冒泡，避免误触气泡级 onClick（图片预览/失败重试）。
   */
  @Builder
  richBody(segments: Array<RichSegment>, plain: string, fontSize: number, lineHeight: number) {
    if (this.hasRichStyle(segments)) {
      Text() {
        ForEach(segments, (segment: RichSegment) => {
          Span(segment.text)
            .fontWeight(segment.bold ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(segment.italic ? FontStyle.Italic : FontStyle.Normal)
            .decoration(this.decorationOf(segment))
            .fontColor(this.segmentColorOf(segment))
            // 等宽字体：monospace 不可用时按列表回落 HarmonyOS Sans（fontFamily 官方支持逗号回落）
            .fontFamily(segment.code ? 'monospace, HarmonyOS Sans' : 'HarmonyOS Sans')
            .onClick((): void => {
              if (segment.url.length > 0) {
                this.linkClickConsumed = true;
                this.openExternalLink(segment.url);
              }
            })
        }, (segment: RichSegment, index: number) => `${index}_${segment.text.length}_${segment.url.length}`)
      }
      .fontSize(fontSize)
      .lineHeight(lineHeight)
      .textAlign(TextAlign.Start)
    } else {
      Text(plain)
        .fontSize(fontSize)
        .lineHeight(lineHeight)
        .fontColor(this.model.isOutgoing ? '#FFFFFF' : ChatUi.TEXT_PRIMARY)
        .textAlign(TextAlign.Start)
    }
  }

  /**
   * 链接切片点击消费标记：ClickEvent 无 stopPropagation（官方 d.ts：仅 Touch/Hover 支持），
   * 利用点击冒泡「子（Span）先、父（气泡）后」的顺序——Span 命中置位，气泡 onClick 首行检查并复位
   */
  private linkClickConsumed: boolean = false;

  /** 链接切片点击是否已消费（取用即复位；冒泡顺序保证 Span 先于气泡 onClick 置位） */
  private consumeLinkClick(): boolean {
    const consumed: boolean = this.linkClickConsumed;
    this.linkClickConsumed = false;
    return consumed;
  }

  /** 存在任一样式切片（决定走 Span 分支还是纯 Text 分支） */
  private hasRichStyle(segments: Array<RichSegment>): boolean {
    for (const segment of segments) {
      if (!segment.isPlain()) {
        return true;
      }
    }
    return false;
  }

  /**
   * 切片文字色：链接色（incoming 用 ACCENT 蓝；outgoing 泡为 ACCENT 底，沿用既有的
   * 浅蓝次级色保证对比度）> 普通基色（白/主文字色）。
   */
  private segmentColorOf(segment: RichSegment): string {
    if (segment.link) {
      return this.model.isOutgoing ? '#C9E1F8' : ChatUi.ACCENT;
    }
    return this.model.isOutgoing ? '#FFFFFF' : ChatUi.TEXT_PRIMARY;
  }

  /**
   * 切片装饰线：下划线/删除线合并计算（Span 的 decoration 为单一类型，二者同时命中时
   * 取 LineThrough——视觉主导，TDLib 中两者叠加也极罕见）。
   */
  private decorationOf(segment: RichSegment): DecorationStyleInterface {
    if (segment.strikethrough) {
      return { type: TextDecorationType.LineThrough, color: this.segmentColorOf(segment) };
    }
    if (segment.underline) {
      return { type: TextDecorationType.Underline, color: this.segmentColorOf(segment) };
    }
    return { type: TextDecorationType.None, color: Color.Black };
  }

  /** 链接切片点击：openLink 拉起系统浏览器/深链处理器（M5 简版，无内置预览） */
  private openExternalLink(url: string): void {
    const hostContext: Object | undefined = this.getUIContext().getHostContext();
    if (hostContext === undefined) {
      return;
    }
    const context: common.UIAbilityContext = hostContext as common.UIAbilityContext;
    // 打开失败（无可用处理器等）静默降级：错误对象可能携带 URL（属消息内容），不打日志
    context.openLink(url).catch((): void => {
    });
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
