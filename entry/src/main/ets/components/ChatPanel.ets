/**
 * 聊天区可嵌入组件（M3，PLAN §4 组件化）：
 * md/lg 断点由 Index 聊天区内嵌，sm 断点由 ChatPage 内嵌——同一份消息流 + 输入区三形态复用。
 * 页面只保留顶栏与参数传递，本组件自治消息数据（内部接 MessageStore 单例）。
 * M3-media：buildBubble 媒体投影（MessageContent 提取 + FileDownloadStore 状态种子）+
 * 全屏媒体覆盖层（bindContentCover：图片 pinch 预览 / AVPlayer 视频播放）。
 * M5：messageText/caption 富文本切片投影（RichText.parse，entities 按 UTF-16 code unit）。
 *
 * 消息流实现选型：
 * - 数组按时间升序渲染（旧→新，新消息在底部），不用 List 反转——ArkUI List 无 reversed 属性，
 *   倒序数组 + 反向滚动语义（sticking to bottom / 顶部锚定）均需手工补偿，正序 + scrollToIndex 最稳；
 * - 上翻分页：onReachStart（顶部）触发 loadOlder，MessageStore 按 from_message_id=最旧消息拉取；
 *   头部插入后按原首可见条目锚定回滚位置（防跳屏）；
 * - 按天分组头：dayKey（当天零点）变化处插入，文案 TimeFormat.formatDayLabel（今天/昨天/星期/日期）；
 * - ForEach（非 LazyForEach）：单会话常驻消息量有限（分页按需拉取），M3 先保证正确性，
 *   千级历史内存优化（LazyForEach + 精确 diff 通知）挂 M5 打磨。
 *
 * 生命周期：aboutToAppear 注册观察 + activateChat（openChat + 首屏拉取 + viewMessages 已读上报），
 * aboutToDisappear 注销 + deactivateChat（closeChat）。@Prop chatId 变化（Index 切换会话）经 @Watch
 * 平滑换会话（deactivate 旧 → activate 新），组件不重建。
 */
import { MessageStore, MessageStoreObserver } from '../core/MessageStore';
import { TimeFormat } from '../core/TimeFormat';
import { TdField, TdMessageContent, TdSendingState } from '../core/TdConstants';
import { RichSegment, RichText } from '../core/RichText';
import { ChatUi } from '../pages/ChatUi';
import { MessageBubble, MessageBubbleModel, BubbleSendState } from './MessageBubble';
import { MessageContent, MediaKind, PhotoInfo, VideoInfo, DocumentInfo, VoiceInfo } from '../core/MessageContent';
import { FileDownloadStore } from '../core/FileDownloadStore';
import { NotificationService } from '../core/NotificationService';
import { PhotoPreview, VideoPlayCover } from './MediaOverlays';

/** 全屏媒体覆盖层类型（'' = 关闭） */
class OverlayKind {
  static readonly NONE: string = '';
  static readonly PHOTO: string = 'photo';
  static readonly VIDEO: string = 'video';
}

/** 消息流条目：分组头 / 气泡（单类 + isHeader 区分，规避 ArkTS 联合类型限制） */
class ChatEntryModel {
  isHeader: boolean = false;
  /** ForEach 键：内容/状态变化即变键，强制重建对应气泡（编辑/状态机的可见刷新） */
  key: string = '';
  headerText: string = '';
  bubble: MessageBubbleModel | null = null;
}

@Component
export struct ChatPanel {
  @Prop @Watch('onChatIdChanged') chatId: number = 0;
  @State entries: Array<ChatEntryModel> = [];
  @State inputText: string = '';
  @State loadingOlder: boolean = false;
  @State allLoaded: boolean = false;
  @State firstPageReady: boolean = false;
  // 全屏媒体覆盖层（图片预览 / 视频播放；bindContentCover 挂根布局）
  @State overlayKind: string = OverlayKind.NONE;
  @State overlayImageSrc: string = '';
  @State overlayVideoPath: string = '';
  @State overlayVideoTitle: string = '';
  private scroller: Scroller = new Scroller();
  /** 已 activate 的会话 id（@Watch 换会话时先 deactivate，@Watch 回调不提供旧值故自记） */
  private activatedChatId: number = 0;
  private firstVisibleIndex: number = 0;
  /** 首屏定位标记：首次数据到达前不做锚定/跟底 */
  private positioned: boolean = false;
  private readonly storeObserver: MessageStoreObserver = (chatId: number): void => {
    if (chatId === this.chatId) {
      this.rebuild();
    }
  };

  aboutToAppear(): void {
    MessageStore.getInstance().addObserver(this.storeObserver);
    this.switchChat();
  }

  aboutToDisappear(): void {
    MessageStore.getInstance().removeObserver(this.storeObserver);
    if (this.activatedChatId !== 0) {
      MessageStore.getInstance().deactivateChat(this.activatedChatId);
      // 通知触发规则接线：组件销毁后该会话不再视为「用户正在看」（新消息恢复通知）。
      // 直接清 0（而非尝试恢复某个「上一会话」）的前提：Index 通知路由已做 sm 栈归一化
      // （栈内至多一个 ChatPage 且 Index 常驻栈底），本组件销毁时栈下必无被覆盖的其他
      // 会话面板——「返回底层 ChatPage 需恢复 activeChat」的场景已不存在（复审 LOW-10
      // 随 MEDIUM-3 栈归一化闭合）。
      NotificationService.getInstance().setActiveChat(0);
      this.activatedChatId = 0;
    }
  }

  /** @Prop chatId 变化（Index 切换选中会话）：换会话不重建组件 */
  onChatIdChanged(propName: string): void {
    this.switchChat();
  }

  private switchChat(): void {
    if (this.chatId === this.activatedChatId) {
      return;
    }
    if (this.activatedChatId !== 0) {
      MessageStore.getInstance().deactivateChat(this.activatedChatId);
    }
    this.activatedChatId = this.chatId;
    // 通知触发规则接线（md/lg 选中变化 / sm ChatPage 推入弹出同一入口）：
    // 更新「正被查看的会话」，切到即撤该会话未读通知（已读）
    NotificationService.getInstance().setActiveChat(this.chatId);
    this.positioned = false;
    this.entries = [];
    if (this.chatId !== 0) {
      MessageStore.getInstance().activateChat(this.chatId);
      this.rebuild();
    }
  }

  build() {
    Column() {
      if (this.loadingOlder) {
        Text('加载更早消息…')
          .fontSize(11)
          .fontColor(ChatUi.TEXT_SECONDARY)
          .height(22)
          .margin({ top: 4 })
      }
      if (this.entries.length === 0) {
        this.emptyState()
      } else {
        List({ space: 2, scroller: this.scroller }) {
          ForEach(this.entries, (entry: ChatEntryModel) => {
            ListItem() {
              if (entry.isHeader) {
                this.dayHeader(entry)
              } else if (entry.bubble !== null) {
                MessageBubble({
                  model: entry.bubble,
                  onRetry: (messageId: number): void => {
                    this.retryMessage(messageId);
                  },
                  onPhotoOpen: (src: string): void => {
                    this.openPhotoPreview(src);
                  },
                  onVideoOpen: (localPath: string, title: string): void => {
                    this.openVideoPlayer(localPath, title);
                  }
                })
              }
            }
          }, (entry: ChatEntryModel) => entry.key)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)
        .cachedCount(8)
        // 官方聊天流方案（API 19+）：初始布局对齐末项、内容不足一屏底部对齐、
        // 插入条目时上方内容上移——头部插入锚定/新消息跟底由其接管（M3 复审修复）
        .stackFromEnd(true)
        .onReachStart((): void => {
          this.loadOlder();
        })
        .onScrollIndex((first: number, last: number): void => {
          this.firstVisibleIndex = first;
        })
      }
      this.inputBar()
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor(ChatUi.CHAT_BG)
    // 全屏媒体覆盖层：图片 pinch 预览 / AVPlayer 播放（三断点同一份，随组件三形态复用）
    .bindContentCover(this.overlayKind !== OverlayKind.NONE, this.mediaOverlayBuilder(), {
      modalTransition: ModalTransition.DEFAULT,
      // 全屏覆盖层适配安全区（API 20+，工程 targetApi 26 可用）：内容约束在安全区内，
      // 避免顶栏/控制条被状态栏与导航条遮挡
      enableSafeArea: true,
      onWillDismiss: (action: DismissContentCoverAction): void => {
        this.closeOverlay();
        action.dismiss();
      }
    })
  }

  /** 全屏媒体覆盖层内容（photo：pinch 缩放预览 / video：XComponent + AVPlayer） */
  @Builder
  mediaOverlayBuilder() {
    if (this.overlayKind === OverlayKind.PHOTO) {
      PhotoPreview({
        src: this.overlayImageSrc,
        onClose: (): void => {
          this.closeOverlay();
        }
      })
    } else if (this.overlayKind === OverlayKind.VIDEO) {
      VideoPlayCover({
        path: this.overlayVideoPath,
        title: this.overlayVideoTitle,
        onClose: (): void => {
          this.closeOverlay();
        }
      })
    }
  }

  private openPhotoPreview(src: string): void {
    if (src.length === 0) {
      return;
    }
    this.overlayImageSrc = src;
    this.overlayKind = OverlayKind.PHOTO;
  }

  private openVideoPlayer(localPath: string, title: string): void {
    if (localPath.length === 0) {
      return;
    }
    this.overlayVideoPath = localPath;
    this.overlayVideoTitle = title.length > 0 ? title : '视频';
    this.overlayKind = OverlayKind.VIDEO;
  }

  private closeOverlay(): void {
    this.overlayKind = OverlayKind.NONE;
  }

  /** 空态：首屏未到（无缓存）或会话确无消息 */
  @Builder
  emptyState() {
    Column() {
      if (!this.firstPageReady) {
        Text('加载中…')
          .fontSize(13)
          .fontColor(ChatUi.TEXT_SECONDARY)
          .opacity(0.7)
      } else if (this.allLoaded) {
        Text('暂无消息')
          .fontSize(13)
          .fontColor(ChatUi.TEXT_SECONDARY)
          .opacity(0.7)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  /** 按天分组头（居中小胶囊） */
  @Builder
  dayHeader(entry: ChatEntryModel) {
    Row() {
      Text(entry.headerText)
        .fontSize(11)
        .fontColor(ChatUi.TEXT_SECONDARY)
        .padding({ left: 10, right: 10, top: 3, bottom: 3 })
        .borderRadius(9)
        .backgroundColor(ChatUi.SEARCH_BG)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 8, bottom: 4 })
  }

  /** 输入区：TextInput + 发送按钮（回车/按钮双入口） */
  @Builder
  inputBar() {
    Row({ space: 8 }) {
      TextInput({ text: this.inputText, placeholder: '输入消息' })
        .layoutWeight(1)
        .height(40)
        .borderRadius(20)
        .backgroundColor(ChatUi.INPUT_BG)
        .fontColor(ChatUi.TEXT_PRIMARY)
        .fontSize(15)
        .placeholderColor(ChatUi.TEXT_SECONDARY)
        .placeholderFont({ size: 14 })
        .padding({ left: 14, right: 14 })
        .enterKeyType(EnterKeyType.Send)
        .onChange((value: string): void => {
          this.inputText = value;
        })
        .onSubmit((enterKey: EnterKeyType, event: SubmitEvent): void => {
          // 聊天连续输入：回车发送后保持输入框可编辑状态（键盘不收起；本 SDK 用 keepEditableState）
          event.keepEditableState();
          this.sendCurrent();
        })
      Text('发送')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .height(36)
        .borderRadius(18)
        .padding({ left: 16, right: 16 })
        .textAlign(TextAlign.Center)
        .backgroundColor(ChatUi.ACCENT)
        .opacity(this.inputText.trim().length > 0 ? 1 : 0.4)
        .onClick((): void => {
          this.sendCurrent();
        })
    }
    .width('100%')
    .height(60)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(ChatUi.LIST_BG)
  }

  // ---------------- 数据与滚动 ----------------

  private loadOlder(): void {
    if (this.chatId === 0) {
      return;
    }
    MessageStore.getInstance().loadOlder(this.chatId);
  }

  private sendCurrent(): void {
    const text: string = this.inputText.trim();
    if (text.length === 0 || this.chatId === 0) {
      return;
    }
    MessageStore.getInstance().sendText(this.chatId, text);
    this.inputText = '';
  }

  private retryMessage(messageId: number): void {
    if (this.chatId === 0) {
      return;
    }
    MessageStore.getInstance().retrySend(this.chatId, messageId);
  }

  /** 仓库通知/换会话后的视图重建：分组头合并 + 滚动定位（首屏到底/新消息跟底/上翻锚定） */
  private rebuild(): void {
    const store: MessageStore = MessageStore.getInstance();
    const messages: Array<Record<string, Object>> = store.getMessages(this.chatId);
    const previous: Array<ChatEntryModel> = this.entries;
    const previousFirstKey: string = previous.length > 0 ? previous[0].key : '';
    const previousLastKey: string = previous.length > 0 ? previous[previous.length - 1].key : '';

    const entries: Array<ChatEntryModel> = new Array<ChatEntryModel>();
    let lastDayKey: number = -1;
    for (const message of messages) {
      const bubble: MessageBubbleModel = this.buildBubble(message);
      if (bubble.dayKey !== lastDayKey) {
        const header: ChatEntryModel = new ChatEntryModel();
        header.isHeader = true;
        header.key = `d${bubble.dayKey}`;
        header.headerText = TimeFormat.formatDayLabel(bubble.dateSeconds, Date.now());
        entries.push(header);
        lastDayKey = bubble.dayKey;
      }
      const item: ChatEntryModel = new ChatEntryModel();
      item.key = `m${bubble.keySuffix()}`;
      item.bubble = bubble;
      entries.push(item);
    }
    this.entries = entries;
    this.loadingOlder = store.isLoadingOlder(this.chatId);
    this.allLoaded = !store.canLoadOlder(this.chatId) && !this.loadingOlder;
    this.firstPageReady = store.hasCache(this.chatId);
    store.markViewedUpToLatest(this.chatId);

    if (entries.length === 0) {
      this.positioned = false;
      return;
    }
    if (!this.positioned) {
      this.positioned = true;
      this.scrollAfterRender(entries.length - 1, ScrollAlign.END);
      return;
    }
    const lastKey: string = entries[entries.length - 1].key;
    if (lastKey !== previousLastKey) {
      // 底部有新消息（收/发）：stackFromEnd 自动维持视口，此处兜底跟底
      this.scrollAfterRender(entries.length - 1, ScrollAlign.END);
    }
    // 头部插入（上翻页到达）的视口稳定由 stackFromEnd 接管，不再手工锚定补偿
  }

  /** 滚动定位须在 @State 渲染提交后执行（同步调用会被旧布局吞掉/钳制），延迟到下一宏任务 */
  private scrollAfterRender(index: number, align: ScrollAlign): void {
    setTimeout((): void => {
      this.scroller.scrollToIndex(index, false, align);
    }, 0);
  }

  /** TDLib message → 气泡视图模型（原对象不变更，纯投影；媒体分支经 MessageContent 提取） */
  private buildBubble(message: Record<string, Object>): MessageBubbleModel {
    const store: MessageStore = MessageStore.getInstance();
    const bubble: MessageBubbleModel = new MessageBubbleModel();
    bubble.messageId = ChatPanel.readNumber(message, TdField.ID);
    bubble.isOutgoing = message[TdField.IS_OUTGOING] === true;
    bubble.dateSeconds = ChatPanel.readNumber(message, TdField.DATE);
    bubble.timeText = TimeFormat.formatTime(bubble.dateSeconds);
    bubble.dayKey = TimeFormat.dayKeyOf(bubble.dateSeconds);
    bubble.text = ChatPanel.extractText(message);
    // M5 富文本：messageText 的 entities 切片 + 样式指纹（气泡重建键用）
    const content: Record<string, Object> | null = ChatPanel.asRecord(message[TdField.CONTENT]);
    bubble.segments = ChatPanel.extractSegments(content, TdField.TEXT);
    this.attachMedia(bubble, message);
    bubble.styleKey = `${RichText.fingerprint(bubble.segments)}_${RichText.fingerprint(bubble.captionSegments)}`;
    const state: Record<string, Object> | null = ChatPanel.asRecord(message[TdField.SENDING_STATE]);
    if (state !== null) {
      const type: Object | undefined = state[TdField.TYPE];
      if (type === TdSendingState.PENDING) {
        bubble.sendState = BubbleSendState.SENDING;
      } else if (type === TdSendingState.FAILED) {
        bubble.sendState = BubbleSendState.FAILED;
        bubble.canRetry = state[TdField.CAN_RETRY] !== false;
        const error: Record<string, Object> | null = ChatPanel.asRecord(state[TdField.ERROR]);
        if (error !== null) {
          const msg: Object | undefined = error[TdField.MESSAGE];
          if (typeof msg === 'string') {
            bubble.errorText = msg;
          }
        }
      }
    } else if (bubble.isOutgoing && bubble.messageId > 0) {
      // 无 sending_state 且为已确认的正数 id 消息 = 已送出；已读双勾由 outbox 游标判定
      bubble.sendState = BubbleSendState.SENT;
      bubble.isRead = store.isOutgoingRead(this.chatId, bubble.messageId);
    }
    return bubble;
  }

  /**
   * 媒体投影：content → mediaKind + 展示字段（photo 选中档 / video 封面 / document 文件信息 /
   * 语音·动图·贴纸占位）。同时把 content 携带的 file 对象种入 FileDownloadStore
   * （TDLib 自动下载进行中 / 历史缓存已完成的场景，后续 updateFile 无缝接续）。
   * 提取失败（缺 file/尺寸）一律降级为占位文案——占位不崩溃。
   */
  private attachMedia(bubble: MessageBubbleModel, message: Record<string, Object>): void {
    const content: Record<string, Object> | null = ChatPanel.asRecord(message[TdField.CONTENT]);
    if (content === null) {
      return;
    }
    const kind: string = MessageContent.mediaKindOf(content);
    if (kind === MediaKind.NONE) {
      return; // 文本/未知：原路径
    }
    const files: FileDownloadStore = FileDownloadStore.getInstance();
    bubble.caption = MessageContent.extractCaption(content);
    // M5 富文本：媒体 caption 同为 formattedText（含 entities），切片供气泡渲染
    bubble.captionSegments = ChatPanel.extractSegments(content, TdField.CAPTION);
    if (kind === MediaKind.PHOTO) {
      const photo: PhotoInfo | null = MessageContent.extractPhoto(content);
      if (photo !== null && photo.selected !== null) {
        bubble.mediaKind = kind;
        bubble.photoFileId = photo.selected.fileId;
        bubble.photoWidth = photo.selected.width;
        bubble.photoHeight = photo.selected.height;
        bubble.photoMini = photo.miniData.length > 0 ? `data:image/jpeg;base64,${photo.miniData}` : '';
        files.trackFile(photo.selected.file);
      } else if (photo !== null && photo.miniData.length > 0) {
        // 无 sizes 只有 minithumbnail（M3-media 复审修复）：mini 先行灰底显示（无下载目标可拉）
        bubble.mediaKind = kind;
        bubble.photoMini = `data:image/jpeg;base64,${photo.miniData}`;
      } else {
        bubble.placeholder = '[图片]';
      }
    } else if (kind === MediaKind.VIDEO) {
      const video: VideoInfo | null = MessageContent.extractVideo(content);
      if (video !== null) {
        bubble.mediaKind = kind;
        bubble.videoFileId = video.fileId;
        bubble.videoFileName = video.fileName;
        bubble.videoDurationText = MessageContent.formatDuration(video.durationSeconds);
        bubble.videoThumbFileId = video.thumbFileId;
        bubble.videoThumbWidth = video.thumbWidth;
        bubble.videoThumbHeight = video.thumbHeight;
        // 本体宽高透传：无 thumbnail 时气泡按视频原生比例估高（复审修复）
        bubble.videoWidth = video.width;
        bubble.videoHeight = video.height;
        bubble.videoMini = video.miniData.length > 0 ? `data:image/jpeg;base64,${video.miniData}` : '';
        files.trackFile(video.videoFile);
        files.trackFile(video.thumbFile);
      } else {
        bubble.placeholder = '[视频]';
      }
    } else if (kind === MediaKind.DOCUMENT) {
      const doc: DocumentInfo | null = MessageContent.extractDocument(content);
      if (doc !== null) {
        bubble.mediaKind = kind;
        bubble.docFileId = doc.fileId;
        bubble.docFileName = doc.fileName;
        bubble.docSizeText = MessageContent.formatBytes(doc.sizeBytes);
        files.trackFile(doc.docFile);
      } else {
        bubble.placeholder = '[文件]';
      }
    } else if (kind === MediaKind.VOICE) {
      const voice: VoiceInfo | null = MessageContent.extractVoice(content);
      const duration: string = voice === null ? '' : MessageContent.formatDuration(voice.durationSeconds);
      bubble.placeholder = duration.length > 0 ? `[语音] ${duration}` : '[语音]';
    } else if (kind === MediaKind.ANIMATION) {
      bubble.placeholder = '[动图]';
    } else if (kind === MediaKind.STICKER) {
      bubble.placeholder = '[贴纸]';
    } else if (kind === MediaKind.AUDIO) {
      bubble.placeholder = '[音频]';
    }
  }

  private indexOfKey(entries: Array<ChatEntryModel>, key: string): number {
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i].key === key) {
        return i;
      }
    }
    return -1;
  }

  /** messageText 纯文本提取（content.text.text；视图渲染用切片见 extractSegments） */
  private static extractText(message: Record<string, Object>): string {
    const content: Record<string, Object> | null = ChatPanel.asRecord(message[TdField.CONTENT]);
    if (content === null) {
      return '';
    }
    const type: Object | undefined = content[TdField.TYPE];
    if (type !== TdMessageContent.TEXT) {
      return '';
    }
    const formatted: Record<string, Object> | null = ChatPanel.asRecord(content[TdField.TEXT]);
    if (formatted === null) {
      return '';
    }
    const text: Object | undefined = formatted[TdField.TEXT];
    return typeof text === 'string' ? text : '';
  }

  /**
   * formattedText 富文本切片提取（M5）：
   * content[field]（messageText 的 text / 媒体的 caption）→ RichText.parse 切片序列；
   * 非文本类型 / 缺字段 / 空文本返回空数组（气泡走纯 Text 路径）。
   */
  private static extractSegments(content: Record<string, Object> | null,
    field: string): Array<RichSegment> {
    if (content === null) {
      return [];
    }
    const formatted: Record<string, Object> | null = ChatPanel.asRecord(content[field]);
    if (formatted === null) {
      return [];
    }
    return RichText.parse(formatted);
  }

  private static readNumber(source: Record<string, Object>, field: string): number {
    const value: Object | undefined = source[field];
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value;
    }
    return 0;
  }

  private static asRecord(value: Object | undefined): Record<string, Object> | null {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return null;
  }
}
