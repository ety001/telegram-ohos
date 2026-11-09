/**
 * 聊天区可嵌入组件（M3，PLAN §4 组件化）：
 * md/lg 断点由 Index 聊天区内嵌，sm 断点由 ChatPage 内嵌——同一份消息流 + 输入区三形态复用。
 * 页面只保留顶栏与参数传递，本组件自治消息数据（内部接 MessageStore 单例）。
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
import { ChatUi } from '../pages/ChatUi';
import { MessageBubble, MessageBubbleModel, BubbleSendState } from './MessageBubble';

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
  }

  /** 空态：首屏未到（无缓存）或会话确无消息 */
  @Builder
  emptyState() {
    Column() {
      Text(this.allLoaded ? '暂无消息' : '加载中…')
        .fontSize(13)
        .fontColor(ChatUi.TEXT_SECONDARY)
        .opacity(0.7)
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
        .onSubmit((enterKey: EnterKeyType): void => {
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
    store.markViewedUpToLatest(this.chatId);

    if (entries.length === 0) {
      this.positioned = false;
      return;
    }
    const lastKey: string = entries[entries.length - 1].key;
    if (!this.positioned) {
      this.positioned = true;
      this.scrollAfterRender(entries.length - 1, ScrollAlign.END);
      return;
    }
    if (lastKey !== previousLastKey) {
      // 底部有新消息（收/发）：跟底（用户主动上翻阅读时强行跟底为 M3 取舍，M5 改「回到底部」浮标）
      this.scrollAfterRender(entries.length - 1, ScrollAlign.END);
      return;
    }
    if (previousFirstKey.length > 0 && entries[0].key !== previousFirstKey) {
      // 头部插入（上翻页到达）：锚定原首可见条目，防止视口跳到底部/顶部
      const anchorIndex: number = this.indexOfKey(entries, previousFirstKey);
      if (anchorIndex > 0) {
        const target: number = anchorIndex + this.firstVisibleIndex;
        this.scrollAfterRender(target > entries.length - 1 ? entries.length - 1 : target, ScrollAlign.START);
      }
    }
  }

  /** 滚动定位须在 @State 渲染提交后执行（同步调用会被旧布局吞掉/钳制），延迟到下一宏任务 */
  private scrollAfterRender(index: number, align: ScrollAlign): void {
    setTimeout((): void => {
      this.scroller.scrollToIndex(index, false, align);
    }, 0);
  }

  /** TDLib message → 气泡视图模型（原对象不变更，纯投影） */
  private buildBubble(message: Record<string, Object>): MessageBubbleModel {
    const store: MessageStore = MessageStore.getInstance();
    const bubble: MessageBubbleModel = new MessageBubbleModel();
    bubble.messageId = ChatPanel.readNumber(message, TdField.ID);
    bubble.isOutgoing = message[TdField.IS_OUTGOING] === true;
    bubble.dateSeconds = ChatPanel.readNumber(message, TdField.DATE);
    bubble.timeText = TimeFormat.formatTime(bubble.dateSeconds);
    bubble.dayKey = TimeFormat.dayKeyOf(bubble.dateSeconds);
    bubble.text = ChatPanel.extractText(message);
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

  private indexOfKey(entries: Array<ChatEntryModel>, key: string): number {
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i].key === key) {
        return i;
      }
    }
    return -1;
  }

  /** messageText 纯文本提取（content.text.text；entities 富文本 M5） */
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
