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
import { MessageContent, MediaKind, PhotoInfo, VideoInfo, DocumentInfo, VoiceInfo, ReplyRef } from '../core/MessageContent';
import { FileDownloadStore } from '../core/FileDownloadStore';
import { NotificationService } from '../core/NotificationService';
import { DraftStore } from '../core/DraftStore';
import { ChatListStore } from '../core/ChatListStore';
import { AuthService, AppAuthState } from '../core/AuthService';
import { picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KeyCode } from '@kit.InputKit';
import { promptAction } from '@kit.ArkUI';
import { PhotoPreview, VideoPlayCover } from './MediaOverlays';
import { ForwardPicker } from './ForwardPicker';
import { fileUri } from '@kit.CoreFileKit';

/** 全屏媒体覆盖层类型（'' = 关闭） */
class OverlayKind {
  static readonly NONE: string = '';
  static readonly PHOTO: string = 'photo';
  static readonly VIDEO: string = 'video';
  static readonly FORWARD: string = 'forward';
}

/** 会话内搜索命中条目（M6-5；点击跳转定位） */
class SearchHit {
  messageId: number = 0;
  preview: string = '';
  timeText: string = '';
  isOutgoing: boolean = false;
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
  /** 首屏/重拉请求在途（M5 空态语义：此时显示「加载中…」而非「暂无消息」） */
  @State firstPagePending: boolean = false;
  // 全屏媒体覆盖层（图片预览 / 视频播放；bindContentCover 挂根布局）
  @State overlayKind: string = OverlayKind.NONE;
  @State overlayImageSrc: string = '';
  @State overlayVideoPath: string = '';
  @State overlayVideoTitle: string = '';
  // 回复模式（M6-2）：replyToMessageId > 0 时输入区上方挂引用预览条，发送携带 reply_to
  @State replyToMessageId: number = 0;
  @State replyPreviewLabel: string = '';
  // 编辑模式（M6-3）：editMessageId > 0 时输入区为「编辑消息」态（发送改调 editMessage*）
  @State editMessageId: number = 0;
  @State editPreviewLabel: string = '';
  /** 编辑目标是否媒体 caption（true=editMessageCaption / false=editMessageText） */
  private editIsCaption: boolean = false;
  /** 编辑 caption 时原消息 show_caption_above_media 透传（schema 必填） */
  private editShowAbove: boolean = false;
  /** 转发源（M6-3）：待转发消息 id（ForwardPicker 选定目标后消费） */
  private forwardMessageId: number = 0;
  // 会话内搜索（M6-5）：@Link 由聊天区顶栏 🔍 开关（Index lg / ChatPage sm 双入口）
  @Link showSearch: boolean;
  @State searchQuery: string = '';
  @State searchHits: Array<SearchHit> = [];
  @State searchPending: boolean = false;
  @State searchDone: boolean = false;
  /** 搜索请求序号（PR17 审计 P1：慢响应丢弃，防跨会话/跨查询旧结果覆盖） */
  private searchSeq: number = 0;
  // 跳转高亮（M6-2）：目标消息 id + 到期时间戳（setTimeout 清除）
  @State highlightMessageId: number = 0;
  private highlightTimer: number = -1;
  /** 待跳转消息（目标不在已加载窗口时先 loadAround 再定位；rebuild 内消费） */
  private pendingJumpId: number = 0;
  private scroller: Scroller = new Scroller();
  /** 已 activate 的会话 id（@Watch 换会话时先 deactivate，@Watch 回调不提供旧值故自记） */
  private activatedChatId: number = 0;
  private firstVisibleIndex: number = 0;
  /**
   * 受控 TextArea 回声守卫（PR13 审计 P1-2）：程序化改写 inputText（发送清空/切会话恢复）后，
   * IME 组合态可能携旧值再触发一次 onChange 回填。改写前把「即将被替换的旧文本」记入守卫字段，
   * onChange 命中同值即判回声丢弃（一次性，命中即清）。新输入产生不同值不受影响。
   */
  private inputEchoGuard: string = '';

  private applyProgrammaticInput(text: string): void {
    this.inputEchoGuard = this.inputText;
    this.inputText = text;
  }
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
      // 组件销毁（sm 返回）前保存当前输入为本地草稿（M6-1）。
      // PR13 审计 P1-1：登出流程 reset 先行、组件后拆卸——此时登录态已离开 ready，
      // 残留 inputText 若回写会把跨账号内容塞进已清空的草稿仓，故按登录态守卫跳过
      if (AuthService.getInstance().getAuthState() === AppAuthState.READY) {
        DraftStore.getInstance().save(this.activatedChatId, this.inputText);
      }
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
      // 切走前保存旧会话输入为本地草稿（M6-1；空文本等价清除）
      DraftStore.getInstance().save(this.activatedChatId, this.inputText);
      MessageStore.getInstance().deactivateChat(this.activatedChatId);
    }
    this.activatedChatId = this.chatId;
    // 通知触发规则接线（md/lg 选中变化 / sm ChatPage 推入弹出同一入口）：
    // 更新「正被查看的会话」，切到即撤该会话未读通知（已读）
    NotificationService.getInstance().setActiveChat(this.chatId);
    this.positioned = false;
    this.entries = [];
    // 回复/编辑/跳转状态归零（PR14 审计 P1-1 同源）：均属旧会话，残留会导致
    // reply_to/editMessage 指向异会话消息（服务端必拒）与幽灵高亮
    this.replyToMessageId = 0;
    this.replyPreviewLabel = '';
    this.editMessageId = 0;
    this.editPreviewLabel = '';
    this.editIsCaption = false;
    this.editShowAbove = false;
    this.forwardMessageId = 0;
    this.overlayKind = OverlayKind.NONE;
    this.pendingJumpId = 0;
    // 搜索态归零（M6-5）：结果与输入属旧会话
    this.searchQuery = '';
    this.searchHits = [];
    this.searchPending = false;
    if (this.highlightMessageId !== 0) {
      this.highlightMessageId = 0;
      if (this.highlightTimer >= 0) {
        clearTimeout(this.highlightTimer);
        this.highlightTimer = -1;
      }
    }
    // 恢复新会话本地草稿（M6-1；无草稿为空串）。守卫旧文本防 IME 回声（PR13 审计 P1-2）
    this.applyProgrammaticInput(DraftStore.getInstance().restore(this.chatId));
    if (this.chatId !== 0) {
      MessageStore.getInstance().activateChat(this.chatId);
      this.rebuild();
    }
  }

  build() {
    Column() {
      // 会话内搜索条（M6-5）：顶栏 🔍 开关；Enter/按钮触发；结果面板随展示
      if (this.showSearch) {
        this.searchBar()
      }
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
                  },
                  onReplyAction: (messageId: number): void => {
                    this.startReply(messageId);
                  },
                  onDeleteAction: (messageId: number): void => {
                    this.confirmDeleteMessage(messageId);
                  },
                  onReplyJump: (messageId: number): void => {
                    this.jumpToMessage(messageId);
                  },
                  onEditAction: (messageId: number): void => {
                    this.startEdit(messageId);
                  },
                  onForwardAction: (messageId: number): void => {
                    this.openForwardPicker(messageId);
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

  /** 会话内搜索条 + 结果面板（M6-5）：命中项点击 → jumpToMessage（复用 M6-2 跳转+高亮） */
  @Builder
  searchBar() {
    Column() {
      Row({ space: 8 }) {
        TextInput({ text: this.searchQuery, placeholder: '搜索本会话消息' })
          .layoutWeight(1)
          .height(36)
          .borderRadius(18)
          .backgroundColor(ChatUi.INPUT_BG)
          .fontColor(ChatUi.TEXT_PRIMARY)
          .fontSize(14)
          .placeholderColor(ChatUi.TEXT_SECONDARY)
          .placeholderFont({ size: 13 })
          .padding({ left: 14, right: 14 })
          .enterKeyType(EnterKeyType.Search)
          .onChange((value: string): void => {
            this.searchQuery = value;
          })
          .onSubmit((enterKey: EnterKeyType, event: SubmitEvent): void => {
            event.keepEditableState();
            this.runSearch();
          })
        Text(this.searchPending ? '…' : '搜索')
          .fontSize(14)
          .fontColor(ChatUi.ACCENT)
          .height(32)
          .padding({ left: 12, right: 12 })
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            this.runSearch();
          })
        Text('✕')
          .fontSize(14)
          .fontColor(ChatUi.TEXT_SECONDARY)
          .width(30)
          .height(32)
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            this.closeSearch();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })

      if (this.searchHits.length > 0) {
        Column() {
          List() {
            ForEach(this.searchHits, (hit: SearchHit) => {
              ListItem() {
                Row({ space: 10 }) {
                  Column({ space: 2 }) {
                    Text(hit.isOutgoing ? '你' : '')
                      .fontSize(hit.isOutgoing ? 11 : 0)
                      .fontColor(ChatUi.ACCENT)
                      .height(hit.isOutgoing ? 14 : 0)
                    Text(hit.preview.length > 0 ? hit.preview : '[消息]')
                      .fontSize(13)
                      .fontColor(ChatUi.TEXT_PRIMARY)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  Text(hit.timeText)
                    .fontSize(11)
                    .fontColor(ChatUi.TEXT_SECONDARY)
                }
                .width('100%')
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                .alignItems(VerticalAlign.Center)
                .onClick((): void => {
                  const target: number = hit.messageId;
                  this.closeSearch();
                  this.jumpToMessage(target);
                })
              }
            }, (hit: SearchHit) => `${hit.messageId}_${hit.preview}`)
          }
          .width('100%')
          .constraintSize({ maxHeight: 240 })
          .scrollBar(BarState.Auto)
        }
        .width('100%')
        .backgroundColor(ChatUi.SEARCH_BG)
      } else if (this.searchDone && !this.searchPending) {
        // 已搜索且无命中（区分未搜索空态——PR17 审计 P2①）
        Text('未找到匹配消息')
          .fontSize(12)
          .fontColor(ChatUi.TEXT_SECONDARY)
          .opacity(0.7)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 4, bottom: 6 })
      }
    }
    .width('100%')
    .backgroundColor(ChatUi.LIST_BG)
  }

  private runSearch(): void {
    const query: string = this.searchQuery.trim();
    if (query.length === 0 || this.chatId === 0) {
      return;
    }
    this.searchPending = true;
    this.searchDone = false;
    this.searchSeq += 1;
    const seq: number = this.searchSeq;
    const chatId: number = this.chatId;
    MessageStore.getInstance().searchInChat(chatId, query)
      .then((messages: Array<Record<string, Object>>): void => {
        if (seq !== this.searchSeq || chatId !== this.chatId) {
          return; // PR17 审计 P1：迟到的旧请求/旧会话响应丢弃
        }
        this.searchPending = false;
        this.searchDone = true;
        const hits: Array<SearchHit> = new Array<SearchHit>();
        for (const message of messages) {
          const hit: SearchHit = new SearchHit();
          hit.messageId = ChatPanel.readNumber(message, TdField.ID);
          if (hit.messageId === 0) {
            continue;
          }
          hit.preview = MessageContent.previewTextOf(message);
          const dateSeconds: number = ChatPanel.readNumber(message, TdField.DATE);
          hit.timeText = TimeFormat.formatChatListTime(dateSeconds, Date.now());
          hit.isOutgoing = message[TdField.IS_OUTGOING] === true;
          hits.push(hit);
        }
        this.searchHits = hits;
      });
  }

  private closeSearch(): void {
    this.showSearch = false;
    this.searchQuery = '';
    this.searchHits = [];
    this.searchPending = false;
    this.searchDone = false;
    this.searchSeq += 1;
  }

  /** 全屏覆盖层内容（photo：pinch 缩放预览 / video：XComponent + AVPlayer / forward：转发选择器） */
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
    } else if (this.overlayKind === OverlayKind.FORWARD) {
      ForwardPicker({
        onPick: (chatId: number): void => {
          const messageId: number = this.forwardMessageId;
          const fromChatId: number = this.chatId;
          this.closeOverlay();
          this.forwardMessageId = 0;
          if (chatId !== 0 && messageId !== 0) {
            MessageStore.getInstance().forwardMessages(chatId, fromChatId, [messageId]);
          }
        },
        onClose: (): void => {
          this.closeOverlay();
          this.forwardMessageId = 0;
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

  /**
   * 空态（M5 语义修正）：
   * - 无缓存（activateChat 尚未建缓存）或首屏/重拉在途 →「加载中…」
   *   （stale 重置清空消息后 hasMore 复位为 true，此前会被误判成「暂无消息」）；
   * - 缓存就位且已到底（canLoadOlder=false 且无消息）→「暂无消息」；
   * - 其余（既未到底也无在途请求却无消息——理论不应到达）不显示文案。
   */
  @Builder
  emptyState() {
    Column() {
      if (!this.firstPageReady || this.firstPagePending) {
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

  /**
   * 输入区（M6-1 重构）：附件菜单（图片/文件）+ TextArea 多行 + 发送按钮。
   * - TextArea：Enter=换行（ArkUI 无法拦截默认换行插入），桌面 Ctrl+Enter=发送
   *   （KeyEvent.getModifierKeyState 判定，since 12），移动端走发送按钮；
   * - 附件 📎 bindMenu 两项：图片（PhotoViewPicker）/ 文件（DocumentViewPicker）；
   * - 草稿：切会话/销毁由 switchChat/aboutToDisappear 保存，发送成功即清（DraftStore）。
   */
  @Builder
  inputBar() {
    Column() {
      // 回复引用预览条（M6-2）：发送携带 reply_to；✕ 退出回复模式
      if (this.replyToMessageId !== 0) {
        Row({ space: 8 }) {
          Column()
            .width(3)
            .height(26)
            .borderRadius(2)
            .backgroundColor(ChatUi.ACCENT)
          Text(this.replyPreviewLabel.length > 0 ? this.replyPreviewLabel : '回复消息')
            .fontSize(12)
            .fontColor(ChatUi.TEXT_SECONDARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text('✕')
            .fontSize(14)
            .fontColor(ChatUi.TEXT_SECONDARY)
            .width(30)
            .height(26)
            .textAlign(TextAlign.Center)
            .onClick((): void => {
              this.cancelReply();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 12, top: 4, bottom: 2 })
        .alignItems(VerticalAlign.Center)
      }
      // 编辑预览条（M6-3）：发送改调 editMessage*；✕ 退出编辑模式（原文不动）
      if (this.editMessageId !== 0) {
        Row({ space: 8 }) {
          Column()
            .width(3)
            .height(26)
            .borderRadius(2)
            .backgroundColor(ChatUi.ACCENT)
          Text('编辑消息')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(ChatUi.ACCENT)
          Text(this.editPreviewLabel)
            .fontSize(12)
            .fontColor(ChatUi.TEXT_SECONDARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text('✕')
            .fontSize(14)
            .fontColor(ChatUi.TEXT_SECONDARY)
            .width(30)
            .height(26)
            .textAlign(TextAlign.Center)
            .onClick((): void => {
              this.cancelEdit();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 12, top: 4, bottom: 2 })
        .alignItems(VerticalAlign.Center)
      }
      Row({ space: 8 }) {
        Text('📎')
          .fontSize(22)
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .bindMenu(this.attachMenu())
        TextArea({ text: this.inputText, placeholder: '输入消息' })
          .layoutWeight(1)
          .constraintSize({ minHeight: 40, maxHeight: 120 })
          .borderRadius(20)
          .backgroundColor(ChatUi.INPUT_BG)
          .fontColor(ChatUi.TEXT_PRIMARY)
          .fontSize(15)
          .placeholderColor(ChatUi.TEXT_SECONDARY)
          .placeholderFont({ size: 14 })
          .padding({ left: 14, right: 14, top: 9, bottom: 9 })
          .maxLines(5)
          .textOverflow(TextOverflow.Ellipsis)
          .onChange((value: string): void => {
            // 回声守卫：程序化改写后的第一次 onChange 携旧值（IME 组合态回流）→ 丢弃
            if (this.inputEchoGuard.length > 0 && value === this.inputEchoGuard) {
              this.inputEchoGuard = '';
              return;
            }
            this.inputEchoGuard = '';
            this.inputText = value;
          })
          .onKeyEvent((event: KeyEvent): void => {
            // Ctrl+Enter 发送（桌面键盘；Enter 本身换行不拦截）
            if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ENTER &&
              event.getModifierKeyState?.(['Ctrl']) === true) {
              this.sendCurrent();
            }
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
      .constraintSize({ minHeight: 60, maxHeight: 140 })
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor(ChatUi.LIST_BG)
  }

  /** 附件菜单（M6-1）：图片 / 文件 */
  @Builder
  attachMenu() {
    Menu() {
      MenuItem({ content: '图片' })
        .contentFontColor(ChatUi.TEXT_PRIMARY)
        .onClick((): void => {
          this.selectPhoto();
        })
      MenuItem({ content: '文件' })
        .contentFontColor(ChatUi.TEXT_PRIMARY)
        .onClick((): void => {
          this.selectDocument();
        })
    }
    .backgroundColor(ChatUi.LIST_BG)
    .radius(12)
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
    // 编辑模式（M6-3）：分流 editMessageText / editMessageCaption；失败 toast 透传服务端错误
    if (this.editMessageId !== 0) {
      const editId: number = this.editMessageId;
      const isCaption: boolean = this.editIsCaption;
      const showAbove: boolean = this.editShowAbove;
      this.cancelEdit();
      this.applyProgrammaticInput('');
      const promise: Promise<void> = isCaption
        ? MessageStore.getInstance().editMessageCaption(this.chatId, editId, text, showAbove)
        : MessageStore.getInstance().editMessageText(this.chatId, editId, text);
      promise.catch((reason: string): void => {
        this.showToast(reason.length > 0 ? reason : '编辑失败');
      });
      return;
    }
    MessageStore.getInstance().sendText(this.chatId, text, this.replyToMessageId);
    // 守卫旧文本防发送清空后的 IME 回声（PR13 审计 P1-2）
    this.applyProgrammaticInput('');
    // 发送成功即清本地草稿（云端草稿由 sendText 的 clear_draft 顺带清理）与回复模式
    DraftStore.getInstance().clear(this.chatId);
    this.replyToMessageId = 0;
    this.replyPreviewLabel = '';
  }

  // ---------------- 消息操作（M6-2） ----------------

  /** 进入回复模式：预览条 = 发送方名 + 消息单行预览（模型数据自当前 entries 查找）。
   *  与编辑互斥：进入回复清编辑态 */
  private startReply(messageId: number): void {
    const bubble: MessageBubbleModel | null = this.findBubbleModel(messageId);
    if (bubble === null) {
      return;
    }
    this.cancelEdit();
    this.replyToMessageId = messageId;
    const senderName: string = this.senderLabelOf(bubble);
    const preview: string = bubble.text.length > 0 ? bubble.text.replace(/\s+/g, ' ').trim() :
      (bubble.caption.length > 0 ? bubble.caption : bubble.placeholder);
    const previewText: string = preview.length > 0 ? preview : '消息';
    const clipped: string = previewText.length > 40 ? `${previewText.slice(0, 40)}…` : previewText;
    this.replyPreviewLabel = `${senderName}：${clipped}`;
  }

  private cancelReply(): void {
    this.replyToMessageId = 0;
    this.replyPreviewLabel = '';
  }

  // ---------------- 编辑与转发（M6-3） ----------------

  /** 进入编辑模式：文本消息走 editMessageText；媒体消息按 caption 走 editMessageCaption
   *  （show_caption_above_media 自原 content 透传——schema 必填，漏传会改变 caption 位置） */
  private startEdit(messageId: number): void {
    const message: Record<string, Object> | null =
      MessageStore.getInstance().getMessageById(this.chatId, messageId);
    if (message === null) {
      return;
    }
    const bubble: MessageBubbleModel | null = this.findBubbleModel(messageId);
    const original: string = bubble !== null ? (bubble.text.length > 0 ? bubble.text : bubble.caption) : '';
    this.editIsCaption = original.length > 0 && bubble !== null && bubble.text.length === 0;
    const content: Record<string, Object> | null = ChatPanel.asRecord(message[TdField.CONTENT]);
    this.editShowAbove = MessageContent.showCaptionAboveOf(content);
    this.editMessageId = messageId;
    const clipped: string = original.length > 40 ? `${original.slice(0, 40)}…` : original;
    this.editPreviewLabel = clipped;
    // 回复与编辑互斥：进入编辑清回复态（反之亦然）
    this.replyToMessageId = 0;
    this.replyPreviewLabel = '';
    this.applyProgrammaticInput(original);
  }

  private cancelEdit(): void {
    this.editMessageId = 0;
    this.editPreviewLabel = '';
    this.editIsCaption = false;
    this.editShowAbove = false;
  }

  /** 打开转发目标选择器（覆盖层内选定后 forwardMessages） */
  private openForwardPicker(messageId: number): void {
    this.forwardMessageId = messageId;
    this.overlayKind = OverlayKind.FORWARD;
  }

  private showToast(message: string): void {
    this.getUIContext().getPromptAction().showToast({
      message: message,
      duration: 2500
    });
  }

  /** 引用条发送方名：自己 = 「你」；对方 = 会话标题（群聊精确到发送人挂 M7 用户体系） */
  private senderLabelOf(bubble: MessageBubbleModel): string {
    if (bubble.isOutgoing) {
      return '你';
    }
    const title: string = ChatListStore.getInstance().getTitle(this.chatId);
    return title.length > 0 ? title : '成员';
  }

  private findBubbleModel(messageId: number): MessageBubbleModel | null {
    for (const entry of this.entries) {
      if (entry.bubble !== null && entry.bubble.messageId === messageId) {
        return entry.bubble;
      }
    }
    return null;
  }

  /** 删除消息：ActionMenu 三选（仅自己 / 所有人 / 取消）；乐观移除由 MessageStore 承担 */
  private confirmDeleteMessage(messageId: number): void {
    this.getUIContext().getPromptAction().showActionMenu({
      title: '删除消息？',
      buttons: [
        { text: '删除（所有人）', color: ChatUi.BUBBLE_ERROR },
        { text: '删除（仅自己）', color: ChatUi.TEXT_PRIMARY },
        { text: '取消', color: ChatUi.TEXT_SECONDARY }
      ]
    }).then((result: promptAction.ActionMenuSuccessResponse): void => {
      const ids: Array<number> = [messageId];
      if (result.index === 0) {
        MessageStore.getInstance().deleteMessages(this.chatId, ids, true);
      } else if (result.index === 1) {
        MessageStore.getInstance().deleteMessages(this.chatId, ids, false);
      }
    }).catch((): void => {
    });
  }

  /**
   * 跳转定位：已加载 → 滚动居中 + 高亮；未加载 → loadAroundMessage 拉上下文后
   * 由 pendingJumpId 在 rebuild 尾部自动补跳。
   */
  private jumpToMessage(messageId: number): void {
    if (messageId <= 0 || this.chatId === 0) {
      return;
    }
    const index: number = this.indexOfMessage(messageId);
    if (index >= 0) {
      this.scrollAfterRender(index, ScrollAlign.CENTER);
      this.flashHighlight(messageId);
      return;
    }
    this.pendingJumpId = messageId;
    MessageStore.getInstance().loadAroundMessage(this.chatId, messageId);
  }

  /** entries 中定位气泡条目下标（key 前缀 m<id>_ 匹配；分组头跳过） */
  private indexOfMessage(messageId: number): number {
    const prefix: string = `m${messageId}_`;
    for (let i: number = 0; i < this.entries.length; i++) {
      const entry: ChatEntryModel = this.entries[i];
      if (!entry.isHeader && entry.key.startsWith(prefix)) {
        return i;
      }
    }
    return -1;
  }

  /** 高亮 2.5s 后自动消退（先 rebuild 应用高亮背景，到期再 rebuild 还原） */
  private flashHighlight(messageId: number): void {
    this.highlightMessageId = messageId;
    this.rebuild();
    if (this.highlightTimer >= 0) {
      clearTimeout(this.highlightTimer);
    }
    this.highlightTimer = setTimeout((): void => {
      this.highlightMessageId = 0;
      this.rebuild();
    }, 2500);
  }

  private retryMessage(messageId: number): void {
    if (this.chatId === 0) {
      return;
    }
    MessageStore.getInstance().retrySend(this.chatId, messageId);
  }

  /** 选择图片并发送 */
  private async selectPhoto(): Promise<void> {
    try {
      const photoPicker = new picker.PhotoViewPicker();
      const photoSelectOptions = new picker.PhotoSelectOptions();
      photoSelectOptions.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
      photoSelectOptions.maxSelectNumber = 1;
      const selectResult: picker.PhotoSelectResult = await photoPicker.select(photoSelectOptions);
      // PhotoSelectResult.photoUris is string[]
      const uris: Array<string> = selectResult?.photoUris ?? [];
      if (uris.length > 0 && this.chatId !== 0) {
        // 转换 file:// URI 为绝对路径（TDLib inputFileLocal 需要真实路径）
        const filePath: string = this.uriToPath(uris[0]);
        hilog.info(0x0012, 'ChatPanel', 'selectPhoto: uri=%{private}s path=%{private}s', uris[0], filePath);
        MessageStore.getInstance().sendPhoto(this.chatId, filePath);
      }
    } catch (err) {
      hilog.error(0x0012, 'ChatPanel', 'selectPhoto failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 选择文件并发送 */
  private async selectDocument(): Promise<void> {
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const documentSelectOptions = new picker.DocumentSelectOptions();
      documentSelectOptions.maxSelectNumber = 1;
      documentSelectOptions.defaultFilePathUri = 'internal://cache/';
      const uris: Array<string> = await documentPicker.select(documentSelectOptions);
      if (uris && uris.length > 0 && this.chatId !== 0) {
        const fileUri: string = uris[0];
        const filePath: string = this.uriToPath(fileUri);
        let fileName: string = filePath.split('/').pop() || '文件';
        hilog.info(0x0012, 'ChatPanel', 'selectDocument: uri=%{private}s path=%{private}s', fileUri, filePath);
        MessageStore.getInstance().sendDocument(this.chatId, filePath, fileName);
      }
    } catch (err) {
      hilog.error(0x0012, 'ChatPanel', 'selectDocument failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 将 HarmonyOS file:// URI 转换为 TDLib 可用的绝对路径。
   * picker 返回的 URI 格式：file://media/Photo/... 或 file:///data/storage/...
   * 使用 fileUri.FileUri(uri).path 解析真实文件系统路径
   */
  private uriToPath(uri: string): string {
    if (!uri) {
      return '';
    }
    try {
      // 使用 HarmonyOS FileUri API 解析真实路径
      const uriObj: fileUri.FileUri = new fileUri.FileUri(uri);
      const realPath: string = uriObj.path;
      hilog.info(0x0012, 'ChatPanel', 'uriToPath: %{private}s -> %{private}s', uri, realPath);
      return realPath;
    } catch (e) {
      hilog.error(0x0012, 'ChatPanel', 'uriToPath failed: %{public}s', JSON.stringify(e));
      // 降级处理：移除 file:// 前缀
      let path: string = uri;
      if (path.startsWith('file://')) {
        path = path.substring(7);
      }
      return path;
    }
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
    this.firstPagePending = store.isFirstPagePending(this.chatId);
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

    // 跳转补跳（M6-2）：loadAroundMessage 上下文到达后定位 pendingJumpId 目标
    if (this.pendingJumpId !== 0) {
      const index: number = this.indexOfMessage(this.pendingJumpId);
      if (index >= 0) {
        const target: number = this.pendingJumpId;
        this.pendingJumpId = 0;
        this.scrollAfterRender(index, ScrollAlign.CENTER);
        this.flashHighlight(target);
      }
    }
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
    this.attachReplyInfo(bubble, message);
    // M6-3：已编辑标记（edit_date）与转发来源标签（forward_info.origin）
    bubble.edited = ChatPanel.readNumber(message, TdField.EDIT_DATE) > 0;
    bubble.forwarded = MessageContent.isForwarded(message);
    bubble.forwardFrom = MessageContent.forwardFromNameOf(message);
    bubble.highlighted = this.highlightMessageId !== 0 && bubble.messageId === this.highlightMessageId;
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

  /**
   * 回复引用投影（M6-2）：
   * - 同会话回复（主场景）：origin/content 恒 null——摘要与名称从本地缓存查源消息，
   *   未命中异步 fetchMessage 补拉（到达后 notifyChanged → rebuild 刷新引用条）；
   * - 跨会话回复：origin（hiddenUser 名 / channel 标题）+ content 预览。
   */
  private attachReplyInfo(bubble: MessageBubbleModel, message: Record<string, Object>): void {
    const ref: ReplyRef | null = MessageContent.replyRefOf(message);
    if (ref === null) {
      return;
    }
    bubble.replyToMessageId = ref.messageId;
    bubble.replyToChatId = ref.chatId;
    if (ref.chatId === this.chatId) {
      const src: Record<string, Object> | null =
        MessageStore.getInstance().getMessageById(this.chatId, ref.messageId);
      if (src !== null) {
        bubble.replyToName = src[TdField.IS_OUTGOING] === true ? '你' : this.chatTitleFallback();
        bubble.replyToPreview = MessageContent.previewTextOf(src);
      } else {
        bubble.replyToName = this.chatTitleFallback();
        bubble.replyToPreview = '';
        MessageStore.getInstance().fetchMessage(this.chatId, ref.messageId);
      }
    } else {
      bubble.replyToName = MessageContent.originNameOf(ref.origin, this.chatTitleFallback());
      bubble.replyToPreview = MessageContent.previewOfContent(ref.content);
    }
  }

  /** 会话对方名兜底：标题（私聊即对方名/群名）；空则「成员」 */
  private chatTitleFallback(): string {
    const title: string = ChatListStore.getInstance().getTitle(this.chatId);
    return title.length > 0 ? title : '成员';
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
