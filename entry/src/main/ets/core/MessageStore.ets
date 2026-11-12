/**
 * 消息数据仓库（M3）。单例。按 chatId 隔离。
 *
 * 数据流：
 *   TdClient 接收线程 → TdUpdateRouter（@type 路由）→ 本仓库 → onMessagesChanged(chatId) → ChatPanel
 *
 * 历史拉取（TDLib 1.8.63 契约，td_api.tl@f06b0bac 核对）：
 *   - getChatHistory(chat_id, from_message_id, offset:0, limit:50) 的结果对象 messages
 *     携带完整 message 数组（MessagesManager::get_dialog_history → get_messages_object 逐条
 *     get_message_object），响应经 @extra 等待取回——历史消息不走 updateNewMessage：
 *     add_message_to_dialog 对非 update 来源强制 need_update=false（MessagesManager.cpp
 *     `if (*need_update) { CHECK(from_update); }`），updateNewMessage 仅用于真正的新消息。
 *     入库路径双通道兼容（按 message id 去重），两条契约都不重不漏。
 *   - 上翻分页：from_message_id = 已加载最旧消息 id（响应含该条本身，去重后按「无新消息」判定到底）；
 *     404 Not Found 同样视为到底（与 loadChats 语义对齐，防御性兼容）。
 *
 * 发送（乐观 UI）：
 *   1. sendText 同步插入本地占位消息（id 取 -10^9 递减序列，避开 TDLib 本地临时 id 的小负数段），
 *      气泡立刻显示时钟态；
 *   2. sendMessage(chat_id, input_message_content:inputMessageText{text:formattedText{text}}) 带 @extra，
 *      响应为 TDLib 分配的临时 message（负数 id，sending_state=pending）：占位替换为临时消息；
 *   3. updateMessageSendSucceeded(message, old_message_id)：临时 id 替换为真实 message（正数 id，已发送）；
 *   4. updateMessageSendFailed(message, old_message_id, error)：入库 TDLib 返回的失败 message
 *      （sending_state=messageSendingStateFailed，气泡红色感叹号，点击重试 = deleteMessages + 重发）。
 *   注：发送的临时消息也会走 updateNewMessage（1.8.0 起 updateNewMessage 覆盖所有已发送消息），
 *   与 sendMessage 响应可能构成双气泡窗口——按 chatId+文本 消费未决占位并按 id 去重兜平。
 *
 * 缓存策略：内存缓存只保留最近激活的 2 个会话（简单 LRU：激活即提到队首，超限淘汰队尾）。
 *   消息正文全部驻内存代价高（千级历史 × 常驻会话），TDLib 侧数据库自有全量；被淘汰会话重激活时
 *   自动重新拉首屏。当前 TDLib 打开的会话（openChat）只保留 1 个：切换会话先 closeChat 旧会话
 *   （supergroup/channel 的更新仅对已打开会话下发，关闭即停更），重激活时刷新首屏自愈陈旧数据。
 *
 * 日志红线：消息内容/标题一律不打日志（真机即真实聊天内容），仅记录 chatId/messageId/数量。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TdClient } from '../tdlib/TdClient';
import { TdUpdateRouter, TdRouteHandler } from './TdUpdateRouter';
import { ChatListStore } from './ChatListStore';
import { TdReq, TdUpdate, TdField, TdMessageContent, TdInputMessage, TdMessageSource, TdSendingState, TdType, ErrorType } from './TdConstants';

const TAG: string = 'MessageStore';
const LOG_DOMAIN: number = 0x0012;
/** 历史分页大小（TDLib 上限 100，自述最优值为屏幕可见数 10 倍，M3 取 50） */
const PAGE_SIZE: number = 50;
const HISTORY_TIMEOUT_MS: number = 15000;
const SEND_TIMEOUT_MS: number = 15000;
/** TDLib 表示「已到底」的错误（HTTP 语义 404 透传） */
const ALL_LOADED_ERROR: string = 'not found';
/** 内存缓存保留的会话数（简单 LRU 上限） */
const CACHED_CHAT_LIMIT: number = 2;
/** 本地占位 id 基准：负数且远离 TDLib 本地临时 id 段（小负数），避免同 chat 内撞 id */
const LOCAL_ID_BASE: number = -1000000000;
/** 打开会话时上报已读的消息条数上限 */
const VIEW_COUNT_LIMIT: number = 20;
/** 跳转定位的上下文窗口参数（M6-2/5）：offset=-15 且 limit=40 ≥ |offset|（schema 约束） */
const JUMP_CONTEXT_BEFORE: number = 15;
const JUMP_CONTEXT_LIMIT: number = 40;
/** 会话内搜索结果上限（M6-5） */
const SEARCH_RESULT_LIMIT: number = 50;

export type MessageStoreObserver = (chatId: number) => void;

/** 单会话消息缓存（消息数组按时间升序：正数 server id 升序在前，本地/临时负数 id 按发送顺序居尾） */
interface ChatMessageCache {
  chatId: number;
  messages: Array<Record<string, Object>>;
  /** 是否还有更旧消息可上翻 */
  hasMore: boolean;
  /** 已加载最旧的正数 message id（上翻分页游标；0 = 尚无） */
  oldestLoadedId: number;
  /** 首屏是否已请求过（含重激活后的刷新请求） */
  initialRequested: boolean;
  /** 上翻请求在途标记（首屏刷新不占坑：合并入库幂等） */
  loadingOlder: boolean;
  /** 已读回执游标：自己发出去向消息中已读的最大 id（updateChatReadOutbox 维护） */
  lastReadOutboxId: number;
  /** 已上报 viewMessages 的最大正数 id（避免重复上报） */
  lastViewedMaxId: number;
  /** 会话关闭期停更标记（supergroup/channel）：重激活时缓存不可信，丢弃重拉（M2 复审修复） */
  stale: boolean;
  /**
   * 缓存世代（M5 复审 LOW 修复）：stale 重置时自增。在途 getChatHistory 响应落定时
   * 比对世代，不一致即丢弃——防止上翻响应把陈旧消息并回刚被丢弃重拉的缓存。
   * 取值来自仓库级单调序列（cacheGenerationSeq），缓存淘汰重建后两代永不重号。
   */
  generation: number;
}

/** 发送在途登记：@extra → 本地占位（响应到达后占位 → TDLib 临时消息） */
interface PendingSend {
  chatId: number;
  localId: number;
  text: string;
}

export class MessageStore {
  private static instance: MessageStore | null = null;

  private caches: Map<number, ChatMessageCache> = new Map();
  /** LRU 顺序（队首最新激活）；超限淘汰队尾 */
  private recentChatIds: Array<number> = [];
  private observers: Array<MessageStoreObserver> = [];
  private started: boolean = false;
  private activeChatId: number = 0;
  private actionSeq: number = 0;
  private localIdSeq: number = 0;
  /** 缓存世代单调序列（createCache / stale 重置取号；见 ChatMessageCache.generation） */
  private cacheGenerationSeq: number = 0;
  private pendingSends: Map<string, PendingSend> = new Map();

  private constructor() {
  }

  static getInstance(): MessageStore {
    if (MessageStore.instance === null) {
      MessageStore.instance = new MessageStore();
    }
    return MessageStore.instance;
  }

  // ---------------- 生命周期与路由 ----------------

  // 路由 handler 提为成员：重登录（reset→start）后重复 register 由 Router 去重，防双重分发
  private readonly onNewMessage: TdRouteHandler = (update: Record<string, Object>): void => {
    this.handleNewMessage(this.readRecord(update, TdField.MESSAGE));
  };

  private readonly onSendSucceeded: TdRouteHandler = (update: Record<string, Object>): void => {
    this.handleSendSettled(update, true);
  };

  private readonly onSendFailed: TdRouteHandler = (update: Record<string, Object>): void => {
    this.handleSendSettled(update, false);
  };

  private readonly onMessageContent: TdRouteHandler = (update: Record<string, Object>): void => {
    const chatId: number = this.readChatId(update);
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    if (cache === undefined) {
      return;
    }
    const messageId: number = this.readNumber(update, TdField.MESSAGE_ID);
    const message: Record<string, Object> | undefined = this.findById(cache, messageId);
    if (message === undefined) {
      return;
    }
    const newContent: Record<string, Object> | null = this.readRecord(update, TdField.NEW_CONTENT);
    if (newContent !== null) {
      message[TdField.CONTENT] = newContent;
      this.notifyChanged(chatId);
    }
  };

  private readonly onDeleteMessages: TdRouteHandler = (update: Record<string, Object>): void => {
    // from_cache=true：TDLib 关会话后把消息移出自身缓存（非真删除），保留本仓库缓存避免自毁；
    // 仅处理真删除（from_cache=false，含对方撤回/服务端删除）
    const fromCache: Object | undefined = update[TdField.FROM_CACHE];
    if (fromCache === true) {
      return;
    }
    const chatId: number = this.readChatId(update);
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    if (cache === undefined) {
      return;
    }
    const idsObj: Object | undefined = update[TdField.MESSAGE_IDS];
    if (!Array.isArray(idsObj)) {
      return;
    }
    const ids: Array<Object> = idsObj as Array<Object>;
    let removed: number = 0;
    for (const item of ids) {
      if (typeof item !== 'number') {
        continue;
      }
      if (this.removeById(cache, item)) {
        removed += 1;
      }
    }
    if (removed > 0) {
      hilog.info(LOG_DOMAIN, TAG, 'deleteMessages: chat=%{public}s removed=%{public}d', `${chatId}`, removed);
      this.notifyChanged(chatId);
    }
  };

  private readonly onChatReadOutbox: TdRouteHandler = (update: Record<string, Object>): void => {
    const chatId: number = this.readChatId(update);
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    if (cache === undefined) {
      return;
    }
    const lastRead: number = this.readNumber(update, TdField.LAST_READ_OUTBOX_MESSAGE_ID);
    if (lastRead > cache.lastReadOutboxId) {
      cache.lastReadOutboxId = lastRead;
      this.notifyChanged(chatId);
    }
  };

  // 消息被编辑（M6-3）：edit_date 写回缓存消息——updateMessageContent 只带内容不带 edit_date，
  // 「已编辑」标记依赖本更新即时出现（PR15 审计 P1-1）
  private readonly onMessageEdited: TdRouteHandler = (update: Record<string, Object>): void => {
    const chatId: number = this.readChatId(update);
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    if (cache === undefined) {
      return;
    }
    const messageId: number = this.readNumber(update, TdField.MESSAGE_ID);
    const message: Record<string, Object> | undefined = this.findById(cache, messageId);
    if (message === undefined) {
      return;
    }
    message[TdField.EDIT_DATE] = this.readNumber(update, TdField.EDIT_DATE);
    this.notifyChanged(chatId);
  };

  /** 登录就绪后触发（幂等）：挂路由。由 Index 会话仓库生命周期同步调用 */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    const router: TdUpdateRouter = TdUpdateRouter.getInstance();
    router.register(TdUpdate.NEW_MESSAGE, this.onNewMessage);
    router.register(TdUpdate.MESSAGE_SEND_SUCCEEDED, this.onSendSucceeded);
    router.register(TdUpdate.MESSAGE_SEND_FAILED, this.onSendFailed);
    router.register(TdUpdate.MESSAGE_CONTENT, this.onMessageContent);
    router.register(TdUpdate.DELETE_MESSAGES, this.onDeleteMessages);
    router.register(TdUpdate.CHAT_READ_OUTBOX, this.onChatReadOutbox);
    router.register(TdUpdate.MESSAGE_EDITED, this.onMessageEdited);
    hilog.info(LOG_DOMAIN, TAG, 'started');
  }

  /** 登出/会话结束（authState 离开 ready）后重置；通知观察者清空 UI（防登录页返回键回看旧消息） */
  reset(): void {
    if (!this.started && this.caches.size === 0) {
      return;
    }
    const affected: Array<number> = this.recentChatIds.slice();
    if (this.activeChatId !== 0 && !affected.includes(this.activeChatId)) {
      affected.push(this.activeChatId);
    }
    this.caches.clear();
    this.recentChatIds = [];
    this.pendingSends.clear();
    this.activeChatId = 0;
    this.started = false;
    for (const chatId of affected) {
      this.notifyChanged(chatId);
    }
    hilog.info(LOG_DOMAIN, TAG, 'reset for next login');
  }

  // ---------------- 会话激活（ChatPanel 生命周期入口） ----------------

  /** 打开会话：LRU 提队 + openChat + 首屏拉取（已缓存则刷新合并，自愈 closeChat 期间的停更） */
  activateChat(chatId: number): void {
    if (chatId === 0 || !this.started) {
      return;
    }
    this.activeChatId = chatId;
    this.touchLru(chatId);
    let cache: ChatMessageCache | undefined = this.caches.get(chatId);
    if (cache === undefined) {
      cache = this.createCache(chatId);
    }
    if (cache.stale) {
      // supergroup/channel 关闭期停更：缓存不可信（有缺口+删除残留），丢弃重拉
      // （M2 复审 MEDIUM 修复：只增合并无法自愈 >1 页缺口与删除残留）
      // M5 复审 LOW 修复：世代自增使在途上翻响应整体作废（见 requestHistory 比对）
      this.cacheGenerationSeq += 1;
      cache.generation = this.cacheGenerationSeq;
      cache.messages = [];
      cache.oldestLoadedId = 0;
      cache.hasMore = true;
      cache.loadingOlder = false;
      cache.stale = false;
    }
    // openChat：supergroup/channel 的消息更新仅对已打开会话下发（td_api.tl openChat 注释）
    // 注：对象字面量键须为字符串字面量（ArkTS arkts-identifiers-as-prop-names，沿 M2 风格），
    // 读取侧仍统一走 TdField 常量
    TdClient.getInstance().send({ ['@type']: TdReq.OPEN_CHAT, 'chat_id': chatId });
    if (!cache.initialRequested) {
      cache.initialRequested = true;
      this.requestHistory(chatId, 0);
    } else {
      // 重激活：关闭期间可能停更，刷新首屏（合并入库幂等，不重置上翻游标）
      this.requestHistory(chatId, 0);
    }
  }

  /** 关闭会话（ChatPanel aboutToDisappear）：closeChat 停止该会话的后续更新下发；缓存保留待 LRU 淘汰 */
  deactivateChat(chatId: number): void {
    if (chatId === 0 || this.activeChatId !== chatId) {
      return;
    }
    this.activeChatId = 0;
    // supergroup/channel 关闭后更新停发，缓存将不再自愈——标 stale，重激活时丢弃重拉
    const chat: Record<string, Object> | undefined =
      ChatListStore.getInstance().getChat(chatId);
    if (chat !== undefined) {
      const typeObj: Object | undefined = chat['type'];
      if (typeof typeObj === 'object' && typeObj !== null) {
        const type = typeObj as Record<string, Object>;
        const tObj: Object | undefined = type['@type'];
        const t: string = typeof tObj === 'string' ? tObj as string : '';
        if (t === 'chatTypeSupergroup') {
          const cache: ChatMessageCache | undefined = this.caches.get(chatId);
          if (cache !== undefined) {
            cache.stale = true;
          }
        }
      }
    }
    TdClient.getInstance().send({ ['@type']: TdReq.CLOSE_CHAT, 'chat_id': chatId });
  }

  // ---------------- UI 访问器 ----------------

  getMessages(chatId: number): Array<Record<string, Object>> {
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    return cache === undefined ? new Array<Record<string, Object>>() : cache.messages;
  }

  /** 首屏是否已就位（UI 区分「加载中」与「暂无消息」空态用） */
  hasCache(chatId: number): boolean {
    return this.caches.has(chatId);
  }

  /**
   * 首屏仍在拉取中（M5 空态语义修正）：缓存已建、已请求过、尚无任何消息且未判定到底。
   * 覆盖两态：首屏请求在途 / stale 重置后的重拉在途——均应显示「加载中…」而非「暂无消息」。
   */
  isFirstPagePending(chatId: number): boolean {
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    return cache !== undefined && cache.initialRequested && cache.messages.length === 0 &&
      cache.hasMore && !cache.loadingOlder;
  }

  canLoadOlder(chatId: number): boolean {
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    // oldestLoadedId>0：首屏未到（含首请求在途）不翻页，避免重复拉首页
    return cache !== undefined && cache.initialRequested && cache.oldestLoadedId > 0 &&
      cache.hasMore && !cache.loadingOlder;
  }

  isLoadingOlder(chatId: number): boolean {
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    return cache !== undefined && cache.loadingOlder;
  }

  /** 自己发送的消息是否已被对方读取（updateChatReadOutbox 游标判定） */
  isOutgoingRead(chatId: number, messageId: number): boolean {
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    return cache !== undefined && messageId > 0 && messageId <= cache.lastReadOutboxId;
  }

  addObserver(observer: MessageStoreObserver): void {
    if (!this.observers.includes(observer)) {
      this.observers.push(observer);
    }
  }

  removeObserver(observer: MessageStoreObserver): void {
    const index: number = this.observers.indexOf(observer);
    if (index >= 0) {
      this.observers.splice(index, 1);
    }
  }

  /**
   * 上报已读：取缓存内最新的 ≤20 条正数 id 发 viewMessages（source=messageSourceChatHistory）。
   * 已读判定：TDLib need_read = force_read || is_dialog_history（MessagesManager 实现），
   * 即 dialog history 来源本身即触发已读，与 openChat 无关；force_read 的语义是
   * 「会话关闭时也强制置已读」。无新增（≤上次上报游标）时跳过。
   */
  markViewedUpToLatest(chatId: number): void {
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    if (cache === undefined || this.activeChatId !== chatId) {
      return;
    }
    const ids: Array<number> = [];
    for (let i: number = cache.messages.length - 1; i >= 0 && ids.length < VIEW_COUNT_LIMIT; i--) {
      const id: number = this.readNumber(cache.messages[i], TdField.ID);
      if (id > 0) {
        ids.push(id);
      }
    }
    if (ids.length === 0) {
      return;
    }
    const maxId: number = ids[0];
    if (maxId <= cache.lastViewedMaxId) {
      return;
    }
    cache.lastViewedMaxId = maxId;
    const source: Record<string, Object> = { ['@type']: TdMessageSource.CHAT_HISTORY };
    const request: Record<string, Object> = {
      ['@type']: TdReq.VIEW_MESSAGES,
      'chat_id': chatId,
      'message_ids': ids,
      'source': source,
      'force_read': false
    };
    TdClient.getInstance().send(request);
    hilog.info(LOG_DOMAIN, TAG, 'viewMessages: chat=%{public}s count=%{public}d', `${chatId}`, ids.length);
  }

  // ---------------- 历史分页 ----------------

  /** 上翻加载更旧消息：滚动到顶触发；到底判定 = 空结果 / 无新消息 / 404 */
  loadOlder(chatId: number): void {
    if (!this.canLoadOlder(chatId)) {
      return;
    }
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    if (cache === undefined) {
      return;
    }
    cache.loadingOlder = true;
    this.requestHistory(chatId, cache.oldestLoadedId);
    this.notifyChanged(chatId);
  }

  private requestHistory(chatId: number, fromMessageId: number): void {
    this.actionSeq += 1;
    const extra: string = `getChatHistory_${this.actionSeq}`;
    const isOlderPage: boolean = fromMessageId > 0;
    const snapshotCache: ChatMessageCache | undefined = this.caches.get(chatId);
    const snapshotLength: number = snapshotCache === undefined ? 0 : snapshotCache.messages.length;
    // 捕获缓存世代（M5 复审 LOW 修复）：响应落定时世代不一致（stale 重置已发生）即整体丢弃
    const generation: number = snapshotCache === undefined ? 0 : snapshotCache.generation;
    TdUpdateRouter.getInstance().waitForExtra(extra, HISTORY_TIMEOUT_MS)
      .then((update: Record<string, Object>): void => {
        const cache: ChatMessageCache | undefined = this.caches.get(chatId);
        if (cache === undefined) {
          return; // 请求在途时会话被 LRU 淘汰：丢弃（重激活会重新拉取）
        }
        if (cache.generation !== generation) {
          // stale 重置后的迟到响应：内容不可信（缺口/删除残留），整体丢弃，不碰 loadingOlder
          // （重置时已复位，此处再写反而会覆盖重拉请求的在途标记）
          hilog.info(LOG_DOMAIN, TAG, 'history dropped by generation: chat=%{public}s from=%{public}d',
            `${chatId}`, fromMessageId);
          return;
        }
        cache.loadingOlder = false;
        const typeObj: Object | undefined = update[TdField.TYPE];
        const type: string = typeof typeObj === 'string' ? typeObj as string : '';
        if (type === ErrorType.INVALID) {
          const msgObj: Object | undefined = update[TdField.MESSAGE];
          const msg: string = typeof msgObj === 'string' ? msgObj : '';
          if (msg.toLowerCase().includes(ALL_LOADED_ERROR)) {
            cache.hasMore = false;
          } else {
            // 瞬时错误不熔断（保留 hasMore 可重试）；仅确定性到底/权限类错误判到底
            // 错误文案不打日志（可能含会话上下文）
            const permanent: boolean = msg.toLowerCase().includes('not found') ||
              msg.toLowerCase().includes('access');
            if (permanent) {
              cache.hasMore = false;
            }
            hilog.warn(LOG_DOMAIN, TAG, 'getChatHistory rejected: chat=%{public}s permanent=%{public}s',
              `${chatId}`, `${permanent}`);
          }
          this.notifyChanged(chatId);
          return;
        }
        // messages 结果：完整 message 数组（新→旧顺序），逐条入库（去重幂等）
        const listObj: Object | undefined = update[TdUpdate.MESSAGES];
        const list: Array<Object> = Array.isArray(listObj) ? listObj as Array<Object> : [];
        let inserted: number = 0;
        for (const item of list) {
          const message: Record<string, Object> | null = this.asRecord(item);
          if (message === null) {
            continue;
          }
          if (this.insertMessage(cache, message)) {
            inserted += 1;
          }
        }
        if (list.length === 0) {
          cache.hasMore = false;
        } else if (isOlderPage && inserted === 0) {
          // 上翻返回的全部是已加载消息（from_message_id 含自身 + 去重）：到底
          cache.hasMore = false;
        }
        this.refreshOldestLoaded(cache);
        hilog.info(LOG_DOMAIN, TAG,
          'history: chat=%{public}s from=%{public}d got=%{public}d new=%{public}d total=%{public}d more=%{public}s',
          `${chatId}`, fromMessageId, list.length, inserted, cache.messages.length, `${cache.hasMore}`);
        if (snapshotLength === 0 && cache.messages.length > 0) {
          this.markViewedUpToLatest(chatId); // 首屏到达即上报已读（ChatPanel 尚未滚动的兜底）
        }
        this.notifyChanged(chatId);
      })
      .catch((reason: string): void => {
        const cache: ChatMessageCache | undefined = this.caches.get(chatId);
        if (cache !== undefined && cache.generation === generation) {
          cache.loadingOlder = false;
          this.notifyChanged(chatId);
        }
        hilog.warn(LOG_DOMAIN, TAG, 'getChatHistory timeout: chat=%{public}s', `${chatId}`);
      });
    const request: Record<string, Object> = {
      ['@type']: TdReq.GET_CHAT_HISTORY,
      'chat_id': chatId,
      'from_message_id': fromMessageId,
      'offset': 0,
      'limit': PAGE_SIZE,
      'only_local': false
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
  }

  // ---------------- 发送 ----------------

  /**
   * 发送文本：本地占位（时钟态）→ sendMessage → 临时消息替换 → Succeeded/Failed 状态机。
   * M6-2：replyToMessageId > 0 时 sendMessage 携带 reply_to:inputMessageReplyToMessage
   * （1.8.63 schema——sendMessage 无平铺 reply_to_message_id 字段，仅 message_id 必填）。
   */
  sendText(chatId: number, text: string, replyToMessageId?: number): void {
    const trimmed: string = text.trim();
    if (chatId === 0 || trimmed.length === 0 || !this.started) {
      return;
    }
    const replyId: number = replyToMessageId === undefined ? 0 : replyToMessageId;
    this.localIdSeq += 1;
    const localId: number = LOCAL_ID_BASE - this.localIdSeq;
    const formatted: Record<string, Object> = { ['@type']: TdInputMessage.FORMATTED_TEXT, 'text': trimmed };
    const content: Record<string, Object> = {
      ['@type']: TdMessageContent.TEXT,
      'text': formatted
    };
    const sendingState: Record<string, Object> = { ['@type']: TdSendingState.PENDING };
    const placeholder: Record<string, Object> = {
      'id': localId,
      'chat_id': chatId,
      'is_outgoing': true,
      'date': Math.floor(Date.now() / 1000),
      'content': content,
      'sending_state': sendingState
    };
    const cache: ChatMessageCache = this.ensureCache(chatId);
    this.insertMessage(cache, placeholder);
    hilog.info(LOG_DOMAIN, TAG, 'sendText: chat=%{public}s placeholder=%{public}d', `${chatId}`, localId);

    this.actionSeq += 1;
    const extra: string = `sendMessage_${this.actionSeq}`;
    const pending: PendingSend = { chatId: chatId, localId: localId, text: trimmed };
    this.pendingSends.set(extra, pending);
    TdUpdateRouter.getInstance().waitForExtra(extra, SEND_TIMEOUT_MS)
      .then((update: Record<string, Object>): void => {
        this.pendingSends.delete(extra);
        const typeObj: Object | undefined = update[TdField.TYPE];
        const type: string = typeof typeObj === 'string' ? typeObj as string : '';
        if (type === ErrorType.INVALID) {
          // sendMessage 被拒（网络未连/无权限等）：占位转失败态，错误透传气泡（lastCredentialsError 同思路）
          const msgObj: Object | undefined = update[TdField.MESSAGE];
          const msg: string = typeof msgObj === 'string' ? msgObj : '发送失败';
          this.markPlaceholderFailed(chatId, localId, msg);
          this.notifyChanged(chatId);
          return;
        }
        // 响应即 TDLib 临时 message（负数 id，pending 态）：占位 → 临时消息（后续 Succeeded 接管）
        const live: ChatMessageCache | undefined = this.caches.get(chatId);
        if (live === undefined) {
          return;
        }
        this.removeById(live, localId);
        const tempMessage: Record<string, Object> | null = this.asRecord(update);
        if (tempMessage !== null) {
          this.insertMessage(live, tempMessage);
        }
        this.notifyChanged(chatId);
      })
      .catch((reason: string): void => {
        this.pendingSends.delete(extra);
        this.markPlaceholderFailed(chatId, localId, '发送超时');
        this.notifyChanged(chatId);
      });
    const inputContent: Record<string, Object> = {
      ['@type']: TdInputMessage.INPUT_MESSAGE_TEXT,
      'text': formatted,
      // M6-1：发送即清云端草稿（1.8.63 唯一草稿写路径——saveDraft 已被上游移除）
      'clear_draft': true
    };
    const request: Record<string, Object> = {
      ['@type']: TdReq.SEND_MESSAGE,
      'chat_id': chatId,
      'input_message_content': inputContent
    };
    if (replyId > 0) {
      request[TdField.REPLY_TO] = {
        '@type': TdType.INPUT_MESSAGE_REPLY_TO_MESSAGE,
        'message_id': replyId
      } as Record<string, Object>;
    }
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
  }

  /** 发送图片：本地占位 → sendPhoto → 消息确认 */
  sendPhoto(chatId: number, fileUri: string): void {
    if (chatId === 0 || !this.started || fileUri.length === 0) {
      return;
    }
    this.localIdSeq += 1;
    const localId: number = LOCAL_ID_BASE - this.localIdSeq;
    // 本地占位消息（显示为「图片发送中...」状态）
    const photoContent: Record<string, Object> = {
      ['@type']: 'messagePhoto',
      'photo': { ['@type']: 'photo', 'is_local': true, 'path': fileUri } as Record<string, Object>
    };
    const sendingState: Record<string, Object> = { ['@type']: 'messageSendingStatePending' };
    const placeholder: Record<string, Object> = {
      'id': localId,
      'chat_id': chatId,
      'is_outgoing': true,
      'date': Math.floor(Date.now() / 1000),
      'content': photoContent,
      'sending_state': sendingState
    };
    const cache: ChatMessageCache = this.ensureCache(chatId);
    this.insertMessage(cache, placeholder);
    hilog.info(LOG_DOMAIN, TAG, 'sendPhoto: chat=%{public}s file=%{private}s placeholder=%{public}d',
      `${chatId}`, fileUri, localId);

    this.actionSeq += 1;
    const extra: string = `sendPhoto_${this.actionSeq}`;
    const pending: PendingSend = { chatId: chatId, localId: localId, text: '[图片]' };
    this.pendingSends.set(extra, pending);
    TdUpdateRouter.getInstance().waitForExtra(extra, SEND_TIMEOUT_MS)
      .then((update: Record<string, Object>): void => {
        this.pendingSends.delete(extra);
        const typeObj: Object | undefined = update[TdField.TYPE];
        const type: string = typeof typeObj === 'string' ? typeObj as string : '';
        if (type === ErrorType.INVALID) {
          const msgObj: Object | undefined = update[TdField.MESSAGE];
          const msg: string = typeof msgObj === 'string' ? msgObj : '发送失败';
          this.markPlaceholderFailed(chatId, localId, msg);
          this.notifyChanged(chatId);
          return;
        }
        const live: ChatMessageCache | undefined = this.caches.get(chatId);
        if (live === undefined) {
          return;
        }
        this.removeById(live, localId);
        const tempMessage: Record<string, Object> | null = this.asRecord(update);
        if (tempMessage !== null) {
          this.insertMessage(live, tempMessage);
        }
        this.notifyChanged(chatId);
      })
      .catch((reason: string): void => {
        this.pendingSends.delete(extra);
        this.markPlaceholderFailed(chatId, localId, '发送超时');
        this.notifyChanged(chatId);
      });
    // TDLib: 发送图片用 sendMessage + inputMessagePhoto（非独立 sendPhoto 方法）
    const photoInput: Record<string, Object> = {
      ['@type']: 'inputFileLocal',
      'path': fileUri
    };
    const inputContent: Record<string, Object> = {
      ['@type']: TdInputMessage.PHOTO,
      'photo': photoInput
    };
    const request: Record<string, Object> = {
      ['@type']: TdReq.SEND_MESSAGE,
      'chat_id': chatId,
      'input_message_content': inputContent
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
  }

  /** 发送文件：本地占位 → sendDocument → 消息确认 */
  sendDocument(chatId: number, fileUri: string, fileName?: string): void {
    if (chatId === 0 || !this.started || fileUri.length === 0) {
      return;
    }
    this.localIdSeq += 1;
    const localId: number = LOCAL_ID_BASE - this.localIdSeq;
    const displayName: string = fileName || fileUri.split('/').pop() || '文件';
    const docContent: Record<string, Object> = {
      ['@type']: 'messageDocument',
      'document': { ['@type']: 'document', 'file_name': displayName, 'is_local': true } as Record<string, Object>
    };
    const sendingState2: Record<string, Object> = { ['@type']: 'messageSendingStatePending' };
    const placeholder: Record<string, Object> = {
      'id': localId,
      'chat_id': chatId,
      'is_outgoing': true,
      'date': Math.floor(Date.now() / 1000),
      'content': docContent,
      'sending_state': sendingState2
    };
    const cache: ChatMessageCache = this.ensureCache(chatId);
    this.insertMessage(cache, placeholder);
    hilog.info(LOG_DOMAIN, TAG, 'sendDocument: chat=%{public}s file=%{private}s name=%{private}s placeholder=%{public}d',
      `${chatId}`, fileUri, displayName, localId);

    this.actionSeq += 1;
    const extra: string = `sendDocument_${this.actionSeq}`;
    const pending: PendingSend = { chatId: chatId, localId: localId, text: `[文件: ${displayName}]` };
    this.pendingSends.set(extra, pending);
    TdUpdateRouter.getInstance().waitForExtra(extra, SEND_TIMEOUT_MS)
      .then((update: Record<string, Object>): void => {
        this.pendingSends.delete(extra);
        const typeObj: Object | undefined = update[TdField.TYPE];
        const type: string = typeof typeObj === 'string' ? typeObj as string : '';
        if (type === ErrorType.INVALID) {
          const msgObj: Object | undefined = update[TdField.MESSAGE];
          const msg: string = typeof msgObj === 'string' ? msgObj : '发送失败';
          this.markPlaceholderFailed(chatId, localId, msg);
          this.notifyChanged(chatId);
          return;
        }
        const live: ChatMessageCache | undefined = this.caches.get(chatId);
        if (live === undefined) {
          return;
        }
        this.removeById(live, localId);
        const tempMessage: Record<string, Object> | null = this.asRecord(update);
        if (tempMessage !== null) {
          this.insertMessage(live, tempMessage);
        }
        this.notifyChanged(chatId);
      })
      .catch((reason: string): void => {
        this.pendingSends.delete(extra);
        this.markPlaceholderFailed(chatId, localId, '发送超时');
        this.notifyChanged(chatId);
      });
    // TDLib: 发送文件用 sendMessage + inputMessageDocument（非独立 sendDocument 方法）
    const docInput: Record<string, Object> = {
      ['@type']: 'inputFileLocal',
      'path': fileUri
    };
    const docContent2: Record<string, Object> = {
      ['@type']: TdInputMessage.DOCUMENT,
      'document': docInput
    };
    if (fileName && fileName.length > 0) {
      (docContent2 as Record<string, Object>)['file_name'] = fileName;
    }
    const request2: Record<string, Object> = {
      ['@type']: TdReq.SEND_MESSAGE,
      'chat_id': chatId,
      'input_message_content': docContent2
    };
    request2[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request2);
  }

  // ---------------- 消息操作（M6-2） ----------------

  /**
   * 删除消息：乐观移除本地缓存（updateDeleteMessages 到达再确认，幂等）+ deleteMessages 请求。
   * revoke=true 双端删除（私聊/管理员场景；服务端拒绝时静默——错误含会话上下文不打日志）。
   */
  deleteMessages(chatId: number, messageIds: Array<number>, revoke: boolean): void {
    if (chatId === 0 || messageIds.length === 0 || !this.started) {
      return;
    }
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    if (cache !== undefined) {
      let removed: number = 0;
      for (const id of messageIds) {
        if (this.removeById(cache, id)) {
          removed += 1;
        }
      }
      if (removed > 0) {
        this.notifyChanged(chatId);
      }
    }
    const request: Record<string, Object> = {
      ['@type']: TdReq.DELETE_MESSAGES,
      'chat_id': chatId,
      'message_ids': messageIds,
      'revoke': revoke
    };
    TdClient.getInstance().send(request);
    hilog.info(LOG_DOMAIN, TAG, 'deleteMessages: chat=%{public}s count=%{public}d revoke=%{public}s',
      `${chatId}`, messageIds.length, `${revoke}`);
  }

  /** 本地缓存查询（引用条/跳转用；未加载返回 null） */
  getMessageById(chatId: number, messageId: number): Record<string, Object> | null {
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    if (cache === undefined) {
      return null;
    }
    const found: Record<string, Object> | undefined = this.findById(cache, messageId);
    return found === undefined ? null : found;
  }

  /**
   * 补拉单条消息（引用条源消息不在缓存时）：getMessage → 入库（幂等）→ 通知重建。
   * 结果为 error（消息已被删等）时静默——引用条保持「加载中…」降级文案由 UI 侧兜底。
   */
  fetchMessage(chatId: number, messageId: number): void {
    if (chatId === 0 || messageId === 0 || !this.started) {
      return;
    }
    if (this.getMessageById(chatId, messageId) !== null) {
      return;
    }
    this.actionSeq += 1;
    const extra: string = `getMessage_${this.actionSeq}`;
    TdUpdateRouter.getInstance().waitForExtra(extra, HISTORY_TIMEOUT_MS)
      .then((update: Record<string, Object>): void => {
        if (this.readChatId(update) !== chatId) {
          return; // error 响应（chat_id 缺失）或迟到的异会话响应：丢弃
        }
        const cache: ChatMessageCache | undefined = this.caches.get(chatId);
        if (cache === undefined) {
          return;
        }
        if (this.insertMessage(cache, update)) {
          this.notifyChanged(chatId);
        }
      })
      .catch((reason: string): void => {
        // 超时/失败静默：引用条预览保持降级文案
      });
    const request: Record<string, Object> = {
      ['@type']: TdReq.GET_MESSAGE,
      'chat_id': chatId,
      'message_id': messageId
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
  }

  /**
   * 加载目标消息上下文窗口（跳转定位用，M6-2 引用条跳转 / M6-5 搜索跳转共用）：
   * getChatHistory(from_message_id=目标id, offset=-15, limit=40)——1.8.63 schema 注释：
   * offset 取 -99..-1 且 limit ≥ |offset| 时返回「含 from_message_id 在内的附近消息」窗口。
   * 结果合并入缓存（幂等去重），不重置上翻游标（窗口内更旧消息自然刷新 oldestLoadedId）。
   */
  loadAroundMessage(chatId: number, messageId: number): void {
    if (chatId === 0 || messageId <= 0 || !this.started) {
      return;
    }
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    if (cache === undefined) {
      return;
    }
    this.actionSeq += 1;
    const extra: string = `historyAround_${this.actionSeq}`;
    const generation: number = cache.generation;
    TdUpdateRouter.getInstance().waitForExtra(extra, HISTORY_TIMEOUT_MS)
      .then((update: Record<string, Object>): void => {
        const live: ChatMessageCache | undefined = this.caches.get(chatId);
        if (live === undefined || live.generation !== generation) {
          return;
        }
        const typeObj: Object | undefined = update[TdField.TYPE];
        const type: string = typeof typeObj === 'string' ? typeObj as string : '';
        if (type === ErrorType.INVALID) {
          return; // 目标消息不可达（已删除/权限）：静默，UI 跳转保持现状
        }
        const listObj: Object | undefined = update[TdUpdate.MESSAGES];
        const list: Array<Object> = Array.isArray(listObj) ? listObj as Array<Object> : [];
        for (const item of list) {
          const message: Record<string, Object> | null = this.asRecord(item);
          if (message !== null) {
            this.insertMessage(live, message);
          }
        }
        this.refreshOldestLoaded(live);
        this.notifyChanged(chatId);
        hilog.info(LOG_DOMAIN, TAG, 'historyAround: chat=%{public}s target=%{public}d got=%{public}d',
          `${chatId}`, messageId, list.length);
      })
      .catch((reason: string): void => {
        // 超时静默
      });
    const request: Record<string, Object> = {
      ['@type']: TdReq.GET_CHAT_HISTORY,
      'chat_id': chatId,
      'from_message_id': messageId,
      'offset': -JUMP_CONTEXT_BEFORE,
      'limit': JUMP_CONTEXT_LIMIT,
      'only_local': false
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
  }

  /**
   * 编辑已发文本消息（M6-3）：editMessageText —— 成功结果 message 经 updateMessageContent
   * 消息刷新（1.8.63 editMessage* 的响应 message 不走 updateNewMessage；编辑内容更新由
   * updateMessageContent 驱动，本方法不重复入库，仅透传错误给调用方 toast）。
   * 返回 Promise<null>：成功 resolve；失败 reject(TDLib error.message)。
   */
  editMessageText(chatId: number, messageId: number, text: string): Promise<void> {
    const trimmed: string = text.trim();
    if (chatId === 0 || messageId === 0 || trimmed.length === 0 || !this.started) {
      return Promise.resolve();
    }
    this.actionSeq += 1;
    const extra: string = `editMessageText_${this.actionSeq}`;
    const promise: Promise<void> = this.waitRequestResult(extra, `editMessageText: chat=${`${chatId}`} id=${`${messageId}`}`);
    const formatted: Record<string, Object> = { ['@type']: TdInputMessage.FORMATTED_TEXT, 'text': trimmed };
    const inputContent: Record<string, Object> = {
      ['@type']: TdInputMessage.INPUT_MESSAGE_TEXT,
      'text': formatted
    };
    const request: Record<string, Object> = {
      ['@type']: TdReq.EDIT_MESSAGE_TEXT,
      'chat_id': chatId,
      'message_id': messageId,
      'input_message_content': inputContent
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
    return promise;
  }

  /**
   * 编辑媒体消息 caption（M6-3）：showAbove 从原消息 content 透传
   * （editMessageCaption 必填字段，漏传会把原上方 caption 强制移回媒体下方）。
   */
  editMessageCaption(chatId: number, messageId: number, caption: string, showAbove: boolean): Promise<void> {
    if (chatId === 0 || messageId === 0 || !this.started) {
      return Promise.resolve();
    }
    this.actionSeq += 1;
    const extra: string = `editMessageCaption_${this.actionSeq}`;
    const promise: Promise<void> = this.waitRequestResult(extra, `editMessageCaption: chat=${`${chatId}`} id=${`${messageId}`}`);
    const formatted: Record<string, Object> = { ['@type']: TdInputMessage.FORMATTED_TEXT, 'text': caption.trim() };
    const request: Record<string, Object> = {
      ['@type']: TdReq.EDIT_MESSAGE_CAPTION,
      'chat_id': chatId,
      'message_id': messageId,
      'caption': formatted,
      'show_caption_above_media': showAbove
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
    return promise;
  }

  /**
   * 转发消息（M6-3）：send_copy=false 保留来源（「转发的消息」标签由 forward_info 驱动）、
   * remove_caption=false 保留 caption；topic_id/options 可空缺省。
   */
  forwardMessages(toChatId: number, fromChatId: number, messageIds: Array<number>): void {
    if (toChatId === 0 || fromChatId === 0 || messageIds.length === 0 || !this.started) {
      return;
    }
    const request: Record<string, Object> = {
      ['@type']: TdReq.FORWARD_MESSAGES,
      'chat_id': toChatId,
      'from_chat_id': fromChatId,
      'message_ids': messageIds,
      'send_copy': false,
      'remove_caption': false
    };
    TdClient.getInstance().send(request);
    hilog.info(LOG_DOMAIN, TAG, 'forwardMessages: to=%{public}s from=%{public}s count=%{public}d',
      `${toChatId}`, `${fromChatId}`, messageIds.length);
  }

  /**
   * @extra 请求结果 → Promise<void>：error 响应 reject(error.message)、正常响应 resolve；
   * 超时 reject('超时')。日志仅记动作与 id（不落内容）。
   */
  private waitRequestResult(extra: string, logLabel: string): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (reason: string) => void): void => {
      TdUpdateRouter.getInstance().waitForExtra(extra, SEND_TIMEOUT_MS)
        .then((update: Record<string, Object>): void => {
          const typeObj: Object | undefined = update[TdField.TYPE];
          const type: string = typeof typeObj === 'string' ? typeObj as string : '';
          if (type === ErrorType.INVALID) {
            const msgObj: Object | undefined = update[TdField.MESSAGE];
            const msg: string = typeof msgObj === 'string' ? msgObj : '操作失败';
            hilog.warn(LOG_DOMAIN, TAG, '%{public}s rejected', logLabel);
            reject(msg);
            return;
          }
          hilog.info(LOG_DOMAIN, TAG, '%{public}s ok', logLabel);
          resolve();
        })
        .catch((reason: string): void => {
          reject('操作超时');
        });
    });
  }

  /**
   * 会话内搜索（M6-5）：searchChatMessages（filter 空集 = 全类型）→ foundChatMessages.messages。
   * 结果不入库（点击跳转时 loadAroundMessage 按需拉上下文）；error/超时 resolve 空数组。
   */
  searchInChat(chatId: number, query: string): Promise<Array<Record<string, Object>>> {
    const trimmed: string = query.trim();
    const empty: Array<Record<string, Object>> = new Array<Record<string, Object>>();
    if (chatId === 0 || trimmed.length === 0 || !this.started) {
      return Promise.resolve(empty);
    }
    this.actionSeq += 1;
    const extra: string = `searchChatMessages_${this.actionSeq}`;
    const promise: Promise<Array<Record<string, Object>>> = new Promise<Array<Record<string, Object>>>(
      (resolve: (messages: Array<Record<string, Object>>) => void): void => {
        TdUpdateRouter.getInstance().waitForExtra(extra, HISTORY_TIMEOUT_MS)
          .then((update: Record<string, Object>): void => {
            const typeObj: Object | undefined = update[TdField.TYPE];
            const type: string = typeof typeObj === 'string' ? typeObj : '';
            if (type === ErrorType.INVALID) {
              resolve(empty);
              return;
            }
            const messagesObj: Object | undefined = update[TdUpdate.MESSAGES];
            const list: Array<Object> = Array.isArray(messagesObj) ? messagesObj as Array<Object> : [];
            const messages: Array<Record<string, Object>> = new Array<Record<string, Object>>();
            for (const item of list) {
              const message: Record<string, Object> | null = this.asRecord(item);
              if (message !== null) {
                messages.push(message);
              }
            }
            hilog.info(LOG_DOMAIN, TAG, 'searchInChat: chat=%{public}s hits=%{public}d', `${chatId}`, messages.length);
            resolve(messages);
          })
          .catch((reason: string): void => {
            resolve(empty);
          });
      });
    const filter: Record<string, Object> = { ['@type']: TdType.SEARCH_MESSAGES_FILTER_EMPTY };
    const request: Record<string, Object> = {
      ['@type']: TdReq.SEARCH_CHAT_MESSAGES,
      'chat_id': chatId,
      'query': trimmed,
      'from_message_id': 0,
      'offset': 0,
      'limit': SEARCH_RESULT_LIMIT,
      'filter': filter
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
    return promise;
  }

  /** 失败重试：删除失败占位（本地 + TDLib）后按原文重发 */
  retrySend(chatId: number, messageId: number): void {    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    if (cache === undefined) {
      return;
    }
    const message: Record<string, Object> | undefined = this.findById(cache, messageId);
    if (message === undefined) {
      return;
    }
    const text: string = this.extractText(message);
    if (text.length === 0) {
      return;
    }
    const ids: Array<number> = [messageId];
    const deleteRequest: Record<string, Object> = {
      ['@type']: TdReq.DELETE_MESSAGES,
      'chat_id': chatId,
      'message_ids': ids,
      'revoke': false
    };
    TdClient.getInstance().send(deleteRequest);
    this.removeById(cache, messageId);
    this.notifyChanged(chatId);
    this.sendText(chatId, text);
  }

  // ---------------- 更新处理 ----------------

  /** updateNewMessage：新消息入库（未读/列表联动由 TDLib 的 updateChatReadInbox/updateChatLastMessage 交给 ChatListStore） */
  private handleNewMessage(message: Record<string, Object> | null): void {
    if (message === null) {
      return;
    }
    const chatId: number = this.readChatId(message);
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    if (cache === undefined) {
      return; // 非缓存会话：不入库（重激活时重拉首屏补齐）
    }
    const id: number = this.readNumber(message, TdField.ID);
    // 发送的临时消息先于 sendMessage 响应到达：先消费同文本未决占位，消除双气泡窗口
    if (id < 0 && message[TdField.IS_OUTGOING] === true) {
      this.consumePendingPlaceholder(chatId, this.extractText(message));
    }
    this.insertMessage(cache, message);
    this.notifyChanged(chatId);
  }

  /** updateMessageSendSucceeded / updateMessageSendFailed：old_message_id 移除 + 结果 message 入库 */
  private handleSendSettled(update: Record<string, Object>, succeeded: boolean): void {
    const message: Record<string, Object> | null = this.readRecord(update, TdField.MESSAGE);
    if (message === null) {
      return;
    }
    const chatId: number = this.readChatId(message);
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    if (cache === undefined) {
      return;
    }
    const oldId: number = this.readNumber(update, TdField.OLD_MESSAGE_ID);
    this.removeById(cache, oldId);
    this.insertMessage(cache, message);
    hilog.info(LOG_DOMAIN, TAG, 'sendSettled: chat=%{public}s old=%{public}d ok=%{public}s',
      `${chatId}`, oldId, `${succeeded}`);
    this.notifyChanged(chatId);
  }

  /** sendMessage 被拒/超时：本地占位转失败态（保留原 id，气泡显示错误与重试） */
  private markPlaceholderFailed(chatId: number, localId: number, errorText: string): void {
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    if (cache === undefined) {
      return;
    }
    const message: Record<string, Object> | undefined = this.findById(cache, localId);
    if (message === undefined) {
      return;
    }
    const errorObj: Record<string, Object> = { ['@type']: ErrorType.INVALID, 'message': errorText };
    const failedState: Record<string, Object> = {
      ['@type']: TdSendingState.FAILED,
      'error': errorObj,
      'can_retry': true
    };
    message[TdField.SENDING_STATE] = failedState;
  }

  /** 临时消息（id<0）先到时按 chatId+文本 消费未决占位；只消费占位本身，登记项留给响应兜底（幂等） */
  private consumePendingPlaceholder(chatId: number, text: string): void {
    if (text.length === 0) {
      return;
    }
    const entries: Array<string> = [];
    this.pendingSends.forEach((pending: PendingSend, extra: string): void => {
      if (pending.chatId === chatId && pending.text === text) {
        entries.push(extra);
      }
    });
    if (entries.length === 0) {
      return;
    }
    const first: PendingSend | undefined = this.pendingSends.get(entries[0]);
    if (first === undefined) {
      return;
    }
    const cache: ChatMessageCache | undefined = this.caches.get(chatId);
    if (cache !== undefined) {
      this.removeById(cache, first.localId);
    }
    this.notifyChanged(chatId);
  }

  // ---------------- 缓存与排序 ----------------

  private createCache(chatId: number): ChatMessageCache {
    this.cacheGenerationSeq += 1;
    const cache: ChatMessageCache = {
      chatId: chatId,
      messages: new Array<Record<string, Object>>(),
      hasMore: true,
      oldestLoadedId: 0,
      initialRequested: false,
      loadingOlder: false,
      lastReadOutboxId: 0,
      lastViewedMaxId: 0,
      stale: false,
      generation: this.cacheGenerationSeq
    };
    // 已读回执初值取 chat 对象存量游标（随后由 updateChatReadOutbox 增量推进；
    // M5 复审 LOW 修复：ChatListStore 已联动同步该存量字段，LRU 淘汰重建后种子不再陈旧）
    const chat: Record<string, Object> | undefined = ChatListStore.getInstance().getChat(chatId);
    if (chat !== undefined) {
      cache.lastReadOutboxId = this.readNumber(chat, TdField.LAST_READ_OUTBOX_MESSAGE_ID);
    }
    this.caches.set(chatId, cache);
    return cache;
  }

  private ensureCache(chatId: number): ChatMessageCache {
    const existing: ChatMessageCache | undefined = this.caches.get(chatId);
    if (existing !== undefined) {
      return existing;
    }
    return this.createCache(chatId);
  }

  /** LRU：激活提队首，超限淘汰队尾缓存（activeChatId 恒在队首不受影响） */
  private touchLru(chatId: number): void {
    const index: number = this.recentChatIds.indexOf(chatId);
    if (index >= 0) {
      this.recentChatIds.splice(index, 1);
    }
    this.recentChatIds.unshift(chatId);
    while (this.recentChatIds.length > CACHED_CHAT_LIMIT) {
      const evicted: number | undefined = this.recentChatIds.pop();
      if (evicted === undefined) {
        break;
      }
      this.caches.delete(evicted);
      hilog.info(LOG_DOMAIN, TAG, 'cache evicted by LRU: chat=%{public}s', `${evicted}`);
    }
  }

  /**
   * 消息入库（去重幂等）：
   * - 已存在同 id → 原位替换（编辑/状态变化天然收敛）；
   * - 负数 id（本地占位/临时消息）→ 追加队尾（逻辑上最新，负数 id 无时序含义）；
   * - 正数 id → 插入首个更大正数 id 之前（server id 升序），且始终位于负数 id 段之前。
   * 返回是否为新增（分页到底判定用）。
   */
  private insertMessage(cache: ChatMessageCache, message: Record<string, Object>): boolean {
    const id: number = this.readNumber(message, TdField.ID);
    if (id === 0) {
      return false;
    }
    if (this.readChatId(message) === 0) {
      message[TdField.CHAT_ID] = cache.chatId; // 防御：占位/异常缺 chat_id
    }
    for (let i: number = 0; i < cache.messages.length; i++) {
      const existingId: number = this.readNumber(cache.messages[i], TdField.ID);
      if (existingId === id) {
        cache.messages[i] = message;
        return false;
      }
      if (id > 0 && (existingId > id || existingId < 0)) {
        cache.messages.splice(i, 0, message);
        return true;
      }
    }
    cache.messages.push(message);
    return true;
  }

  private removeById(cache: ChatMessageCache, id: number): boolean {
    for (let i: number = 0; i < cache.messages.length; i++) {
      if (this.readNumber(cache.messages[i], TdField.ID) === id) {
        cache.messages.splice(i, 1);
        return true;
      }
    }
    return false;
  }

  private findById(cache: ChatMessageCache, id: number): Record<string, Object> | undefined {
    for (let i: number = 0; i < cache.messages.length; i++) {
      if (this.readNumber(cache.messages[i], TdField.ID) === id) {
        return cache.messages[i];
      }
    }
    return undefined;
  }

  /** 刷新上翻游标：首个正数 id（数组头部，若为本地负数段则跳过取后续正数） */
  private refreshOldestLoaded(cache: ChatMessageCache): void {
    for (let i: number = 0; i < cache.messages.length; i++) {
      const id: number = this.readNumber(cache.messages[i], TdField.ID);
      if (id > 0) {
        cache.oldestLoadedId = id;
        return;
      }
    }
  }

  /** messageText 纯文本提取（content.text.text；富文本渲染见 core/RichText，此处仅取纯文本供重发） */
  private extractText(message: Record<string, Object>): string {
    const content: Record<string, Object> | null = this.readRecord(message, TdField.CONTENT);
    if (content === null) {
      return '';
    }
    const typeObj: Object | undefined = content[TdField.TYPE];
    if (typeObj !== TdMessageContent.TEXT) {
      return '';
    }
    const formatted: Record<string, Object> | null = this.readRecord(content, TdField.TEXT);
    if (formatted === null) {
      return '';
    }
    const textObj: Object | undefined = formatted[TdField.TEXT];
    return typeof textObj === 'string' ? textObj : '';
  }

  // ---------------- 工具 ----------------

  private readChatId(source: Record<string, Object>): number {
    return this.readNumber(source, TdField.CHAT_ID);
  }

  private readNumber(source: Record<string, Object>, field: string): number {
    const value: Object | undefined = source[field];
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value;
    }
    return 0;
  }

  private readRecord(source: Record<string, Object>, field: string): Record<string, Object> | null {
    return this.asRecord(source[field]);
  }

  private asRecord(value: Object | undefined): Record<string, Object> | null {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return null;
  }

  private notifyChanged(chatId: number): void {
    for (const observer of this.observers) {
      try {
        observer(chatId);
      } catch (err) {
        hilog.error(LOG_DOMAIN, TAG, 'observer error: %{private}s', JSON.stringify(err));
      }
    }
  }
}
