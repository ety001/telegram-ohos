/**
 * 会话列表数据仓库（M2）。单例。
 *
 * 数据流：
 *   TdClient 接收线程 → TdUpdateRouter（@type 路由）→ 本仓库 → onChatListChanged → UI（LazyForEach 数据源）
 *
 * 初始化序列（authorizationStateReady 后由 UI 触发 start()）：
 *   1. send getChats(chat_list:null, limit:50) 拉首屏
 *   2. TDLib 契约：每个 chat 的 updateNewChat（完整 chat 对象）保证先于其出现在 chats 结果中
 *      —— 1.8.63 的 chats 结果只含 chat_ids/total_count，不含 chat 对象（td_api.tl 核对）
 *   3. 逐个 chat 原样入库 + 按 chatListMain position 维护有序列表，chats 结果到达后统一刷新
 *   4. 分页：滚动到底 → send loadChats(chat_list:null)（增量加载，新会话仍经 updateNewChat 流入）；
 *      返回 404 Not Found 即全部加载完毕
 *
 * 排序：按 chatListMain position 的 (order, chat_id) 二元组降序（TDLib 契约，order 已含置顶权重）。
 * 未读：1.8.63 的 chatPosition 无 unread_count 字段（锁定版 td_api.tl 核实），
 *   未读数聚合自 chat.unread_count（updateNewChat 初值）+ updateChatReadInbox.unread_count。
 *
 * 日志红线：会话标题/最后消息内容一律不打日志（真机即真实聊天内容），仅记录数量与 chatId。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TdClient } from '../tdlib/TdClient';
import { TdUpdateRouter, TdRouteHandler } from './TdUpdateRouter';
import { TdReq, TdUpdate, TdField, TdChatList, TdType, ErrorType } from './TdConstants';
import { UserStore } from './UserStore';

const TAG: string = 'ChatListStore';
const LOG_DOMAIN: number = 0x0012;
/** 首屏/分页每页大小（TDLib 自述最优值为屏幕可见数的 10 倍；M2 取 50） */
const PAGE_SIZE: number = 50;
const GET_CHATS_TIMEOUT_MS: number = 30000;
const LOAD_CHATS_TIMEOUT_MS: number = 15000;
/** 会话操作请求（置顶/静音/删除）的响应等待上限 */
const CHAT_ACTION_TIMEOUT_MS: number = 15000;
/** TDLib 表示「列表已全部加载」的错误（HTTP 语义 404 透传） */
const ALL_LOADED_ERROR: string = 'not found';

export type ChatListObserver = () => void;

export class ChatListStore {
  private static instance: ChatListStore | null = null;

  /** chatId → TDLib chat 对象（原样存储，不建投影模型） */
  private chatById: Map<number, Record<string, Object>> = new Map();
  /** chatListMain 有序 chatId 列表：(order, chat_id) 降序 */
  private orderedIds: Array<number> = [];
  private observers: Array<ChatListObserver> = [];
  private started: boolean = false;
  private firstPageLoaded: boolean = false;
  private hasMore: boolean = true;
  private loadingMore: boolean = false;
  private actionSeq: number = 0;
  /** 通知合批标记：首屏几十个 updateNewChat 只触发一次 UI 刷新 */
  private notifyScheduled: boolean = false;

  private constructor() {
  }

  static getInstance(): ChatListStore {
    if (ChatListStore.instance === null) {
      ChatListStore.instance = new ChatListStore();
    }
    return ChatListStore.instance;
  }

  // ---------------- 生命周期 ----------------

  // 路由 handler 提为成员：重登录（reset→start）后重复 register 由 Router 去重，防双重分发
  private readonly onNewChat: TdRouteHandler = (update: Record<string, Object>): void => {
    this.upsertChat(this.readRecord(update, TdField.CHAT));
  };

  // getChat 的响应对象（防御路径：chats 结果引用了未收到的 chat 时逐个补拉）
  private readonly onChatResult: TdRouteHandler = (update: Record<string, Object>): void => {
    this.upsertChat(update);
  };

  private readonly onChatsResult: TdRouteHandler = (update: Record<string, Object>): void => {
    this.handleChatsResult(update);
  };

  private readonly onChatPosition: TdRouteHandler = (update: Record<string, Object>): void => {
    this.handleChatPosition(update);
  };

  private readonly onChatLastMessage: TdRouteHandler = (update: Record<string, Object>): void => {
    this.handleChatLastMessage(update);
  };

  private readonly onChatReadInbox: TdRouteHandler = (update: Record<string, Object>): void => {
    this.handleChatReadInbox(update);
  };

  private readonly onChatTitle: TdRouteHandler = (update: Record<string, Object>): void => {
    this.handleChatTitle(update);
  };

  private readonly onChatPhoto: TdRouteHandler = (update: Record<string, Object>): void => {
    this.handleChatPhoto(update);
  };

  private readonly onChatNotificationSettings: TdRouteHandler = (update: Record<string, Object>): void => {
    this.handleChatNotificationSettings(update);
  };

  // 复审 LOW 修复（M5）：同步 chat.last_read_outbox_message_id 存量记录（见 handler 注释）
  private readonly onChatReadOutbox: TdRouteHandler = (update: Record<string, Object>): void => {
    this.handleChatReadOutbox(update);
  };

  // 云端草稿变更（M6-1）：写入 chat.draft_message（可 null）驱动行预览刷新；
  // 本地草稿由 DraftStore 独立管理，行显示优先级在 ChatUi.buildRow 裁决
  private readonly onChatDraftMessage: TdRouteHandler = (update: Record<string, Object>): void => {
    const chatId: number = this.readNumber(update, TdField.CHAT_ID);
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chat === undefined) {
      return;
    }
    chat[TdField.DRAFT_MESSAGE] = update[TdField.DRAFT_MESSAGE];
    this.notifyChanged();
  };

  // ---------------- 头像与在线状态（M6-4） ----------------

  /** 私聊 user_id（chat.type=chatTypePrivate；非私聊返回 0） */
  privateUserIdOf(chatId: number): number {
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chat === undefined) {
      return 0;
    }
    const type: Record<string, Object> | null = this.asRecord(chat['type']);
    if (type === null) {
      return 0;
    }
    const typeObj: Object | undefined = type[TdField.TYPE];
    if (typeObj !== TdType.CHAT_TYPE_PRIVATE) {
      return 0;
    }
    return this.readNumber(type, TdField.USER_ID);
  }

  /** 私聊在线判定（在线状态由 UserStore 维护） */
  isOnline(chatId: number): boolean {
    const userId: number = this.privateUserIdOf(chatId);
    return userId !== 0 && UserStore.getInstance().isOnline(userId);
  }

  /** 头像小图 file id（chatPhotoInfo.small.id；无头像返回 0） */
  getAvatarFileId(chatId: number): number {
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chat === undefined) {
      return 0;
    }
    const photo: Record<string, Object> | null = this.asRecord(chat[TdField.PHOTO]);
    if (photo === null) {
      return 0;
    }
    const small: Record<string, Object> | null = this.asRecord(photo[TdField.SMALL]);
    if (small === null) {
      return 0;
    }
    return this.readNumber(small, TdField.ID);
  }

  /** 头像 minithumbnail 裸 base64（无返回空串；未下载完成时的先行灰度显示） */
  getAvatarMini(chatId: number): string {
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chat === undefined) {
      return '';
    }
    const photo: Record<string, Object> | null = this.asRecord(chat[TdField.PHOTO]);
    if (photo === null) {
      return '';
    }
    const mini: Record<string, Object> | null = this.asRecord(photo[TdField.MINITHUMBNAIL]);
    if (mini === null) {
      return '';
    }
    const data: Object | undefined = mini[TdField.DATA];
    return typeof data === 'string' ? data : '';
  }

  // ---------------- 服务端搜索（M6-4） ----------------

  /**
   * searchChats（离线搜全部已知会话，含未加载进 UI 的）：结果 chats.chat_ids 中
   * 未入库的会话显式 getChat 补拉（searchChats 响应同样只含 id 列表）。
   * 返回 Promise<chatIds>；error/超时 resolve 空数组（搜索失败不阻塞本地过滤）。
   */
  searchChatsServer(query: string): Promise<Array<number>> {
    const trimmed: string = query.trim();
    if (trimmed.length === 0 || !this.started) {
      return Promise.resolve(new Array<number>());
    }
    this.actionSeq += 1;
    const extra: string = `searchChats_${this.actionSeq}`;
    const promise: Promise<Array<number>> = new Promise<Array<number>>(
      (resolve: (ids: Array<number>) => void): void => {
        TdUpdateRouter.getInstance().waitForExtra(extra, GET_CHATS_TIMEOUT_MS)
          .then((update: Record<string, Object>): void => {
            const typeObj: Object | undefined = update[TdField.TYPE];
            const type: string = typeof typeObj === 'string' ? typeObj : '';
            if (type === ErrorType.INVALID) {
              resolve(new Array<number>());
              return;
            }
            const idsObj: Object | undefined = update[TdField.CHAT_IDS];
            const ids: Array<number> = Array.isArray(idsObj) ? idsObj as Array<number> : [];
            // 未入库会话补拉（updateNewChat 契约不覆盖 searchChats 结果，显式 getChat）
            for (const chatId of ids) {
              if (!this.chatById.has(chatId) && typeof chatId === 'number') {
                TdClient.getInstance().send({
                  ['@type']: TdReq.GET_CHAT,
                  'chat_id': chatId
                });
              }
            }
            resolve(ids);
          })
          .catch((reason: string): void => {
            resolve(new Array<number>());
          });
      });
    const request: Record<string, Object> = {
      ['@type']: TdReq.SEARCH_CHATS,
      'query': trimmed,
      'limit': 30
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
    return promise;
  }

  /**
   * 登录就绪后触发（幂等）：挂路由 + 拉首屏。
   * 极端时序（ready 与 start 之间恰好新产生会话导致 updateNewChat 先于注册到达）下
   * 该会话暂缺，下次 getChat / 重启后补齐——M2 已知取舍。
   */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    const router: TdUpdateRouter = TdUpdateRouter.getInstance();
    router.register(TdUpdate.NEW_CHAT, this.onNewChat);
    router.register(TdUpdate.CHAT_RESULT, this.onChatResult);
    router.register(TdUpdate.CHATS, this.onChatsResult);
    router.register(TdUpdate.CHAT_POSITION, this.onChatPosition);
    router.register(TdUpdate.CHAT_LAST_MESSAGE, this.onChatLastMessage);
    router.register(TdUpdate.CHAT_READ_INBOX, this.onChatReadInbox);
    router.register(TdUpdate.CHAT_TITLE, this.onChatTitle);
    router.register(TdUpdate.CHAT_PHOTO, this.onChatPhoto);
    router.register(TdUpdate.CHAT_NOTIFICATION_SETTINGS, this.onChatNotificationSettings);
    router.register(TdUpdate.CHAT_READ_OUTBOX, this.onChatReadOutbox);
    router.register(TdUpdate.CHAT_DRAFT_MESSAGE, this.onChatDraftMessage);
    hilog.info(LOG_DOMAIN, TAG, 'start: request first page, limit=%{public}d', PAGE_SIZE);
    this.requestFirstPage();
    // M6-4：用户对象/在线状态路由随会话列表启停（已入库私聊补拉一次）
    UserStore.getInstance().start();
    for (const chatId of this.orderedIds) {
      const userId: number = this.privateUserIdOf(chatId);
      if (userId !== 0) {
        UserStore.getInstance().ensureUser(userId);
      }
    }
  }

  /** 登出/会话结束（authState 离开 ready）后重置，下次登录重新拉取；已清空时为无副作用空操作 */
  reset(): void {
    if (!this.started && this.chatById.size === 0 && this.orderedIds.length === 0) {
      return;
    }
    this.chatById.clear();
    this.orderedIds = [];
    this.started = false;
    this.firstPageLoaded = false;
    this.hasMore = true;
    this.loadingMore = false;
    UserStore.getInstance().reset();
    hilog.info(LOG_DOMAIN, TAG, 'reset for next login');
    this.notifyChanged();
  }

  // ---------------- UI 访问器 ----------------

  getOrderedIds(): Array<number> {
    return this.orderedIds;
  }

  getChat(chatId: number): Record<string, Object> | undefined {
    return this.chatById.get(chatId);
  }

  getCount(): number {
    return this.orderedIds.length;
  }

  getTitle(chatId: number): string {
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chat === undefined) {
      return '';
    }
    const title: Object | undefined = chat[TdField.TITLE];
    return typeof title === 'string' ? title : '';
  }

  getUnreadCount(chatId: number): number {
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chat === undefined) {
      return 0;
    }
    const unread: Object | undefined = chat[TdField.UNREAD_COUNT];
    return typeof unread === 'number' ? unread : 0;
  }

  /** chatListMain position 是否置顶 */
  isPinned(chatId: number): boolean {
    const position: Record<string, Object> | null = this.getMainPosition(chatId);
    if (position === null) {
      return false;
    }
    const pinned: Object | undefined = position[TdField.IS_PINNED];
    return pinned === true;
  }

  /** 是否静音中（notification_settings.mute_for > 0；NotificationService.isMuted 同口径） */
  isMuted(chatId: number): boolean {
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chat === undefined) {
      return false;
    }
    const settings: Record<string, Object> | null = this.readRecord(chat, TdField.NOTIFICATION_SETTINGS);
    if (settings === null) {
      return false;
    }
    return this.readNumber(settings, TdField.MUTE_FOR) > 0;
  }

  // ---------------- 会话操作（M5 菜单：置顶 / 静音 / 删除） ----------------

  /**
   * 置顶/取消置顶。结果由更新流驱动：toggleChatIsPinned 返回 ok 后 TDLib 下发
   * updateChatPosition（order 含置顶权重）→ insertOrdered 自动重排，无需本地改状态。
   */
  togglePinned(chatId: number): void {
    if (chatId === 0) {
      return;
    }
    const chatList: Record<string, Object> = { ['@type']: TdChatList.MAIN };
    const request: Record<string, Object> = {
      ['@type']: TdReq.TOGGLE_CHAT_IS_PINNED,
      'chat_list': chatList,
      'chat_id': chatId,
      'is_pinned': !this.isPinned(chatId)
    };
    this.sendChatAction(request, 'togglePin', chatId);
  }

  /**
   * 静音（永久）/取消静音。基于 chat 现有 notification_settings 克隆改写 mute_for
   * （1.8.63 chatNotificationSettings 字段全集透传，避免覆盖其它设置——声音/预览等）；
   * use_default_mute_for 必须显式置 false，否则 TDLib 用默认值覆盖 mute_for。
   * 结果由 updateChatNotificationSettings 驱动（已有 handler 整体替换）。
   */
  setMuted(chatId: number, muted: boolean): void {
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chatId === 0 || chat === undefined) {
      return;
    }
    const existing: Record<string, Object> | null = this.readRecord(chat, TdField.NOTIFICATION_SETTINGS);
    const settings: Record<string, Object> = {};
    if (existing !== null) {
      // 浅拷贝现有设置全集（Record 无 forEach，经 Object.keys 逐键复制）
      const keys: Array<string> = Object.keys(existing);
      for (const key of keys) {
        settings[key] = existing[key];
      }
    }
    settings[TdField.USE_DEFAULT_MUTE_FOR] = false;
    // 永久静音 = int32 上限（官方客户端同款口径）；取消静音 = 0
    settings[TdField.MUTE_FOR] = muted ? 2147483647 : 0;
    const request: Record<string, Object> = {
      ['@type']: TdReq.SET_CHAT_NOTIFICATION_SETTINGS,
      'chat_id': chatId,
      'notification_settings': settings
    };
    this.sendChatAction(request, 'setMuted', chatId);
  }

  /**
   * 删除会话（deleteChat）。私聊/群聊均会删除该会话全部消息，群聊还对所有成员生效
   * （能否删由 chat.can_be_deleted_for_all_users 决定，被拒仅告警）；
   * 列表移除由 updateChatPosition(order=0) 驱动。
   */
  deleteChat(chatId: number): void {
    if (chatId === 0) {
      return;
    }
    const request: Record<string, Object> = {
      ['@type']: TdReq.DELETE_CHAT,
      'chat_id': chatId
    };
    this.sendChatAction(request, 'deleteChat', chatId);
  }

  /**
   * 会话动作统一发送：带 @extra 等待直接回复，被拒/超时仅记动作名与 chatId
   * （错误文案可能携带会话上下文，不打日志）。
   */
  private sendChatAction(request: Record<string, Object>, action: string, chatId: number): void {
    this.actionSeq += 1;
    const extra: string = `chatAction_${this.actionSeq}`;
    request[TdField.EXTRA] = extra;
    TdUpdateRouter.getInstance().waitForExtra(extra, CHAT_ACTION_TIMEOUT_MS)
      .then((update: Record<string, Object>): void => {
        const typeObj: Object | undefined = update[TdField.TYPE];
        if (typeObj === ErrorType.INVALID) {
          hilog.warn(LOG_DOMAIN, TAG, 'chat action rejected: action=%{public}s chat=%{public}d', action, chatId);
        }
      })
      .catch((reason: string): void => {
        hilog.warn(LOG_DOMAIN, TAG, 'chat action timeout: action=%{public}s chat=%{public}d', action, chatId);
      });
    TdClient.getInstance().send(request);
  }

  canLoadMore(): boolean {
    return this.started && this.firstPageLoaded && this.hasMore && !this.loadingMore;
  }

  /** 滚动到底分页：loadChats 增量加载；404 = 已全部加载（经 @extra 等待结果判定） */
  loadMore(): void {
    if (!this.canLoadMore()) {
      return;
    }
    this.loadingMore = true;
    this.actionSeq += 1;
    const extra: string = `loadChats_${this.actionSeq}`;
    TdUpdateRouter.getInstance().waitForExtra(extra, LOAD_CHATS_TIMEOUT_MS)
      .then((update: Record<string, Object>): void => {
        this.loadingMore = false;
        const typeObj: Object | undefined = update[TdField.TYPE];
        const type: string = typeof typeObj === 'string' ? typeObj as string : '';
        if (type === ErrorType.INVALID) {
          const msgObj: Object | undefined = update[TdField.MESSAGE];
          const msg: string = typeof msgObj === 'string' ? msgObj : '';
          if (msg.toLowerCase().includes(ALL_LOADED_ERROR)) {
            this.hasMore = false;
            hilog.info(LOG_DOMAIN, TAG, 'loadMore: all chats loaded (%{public}d)', this.orderedIds.length);
          } else {
            hilog.warn(LOG_DOMAIN, TAG, 'loadMore rejected: %{private}s', msg);
          }
        }
        // ok：新会话随后经 updateNewChat/chats 结果流入，无需此处处理
      })
      .catch((reason: string): void => {
        this.loadingMore = false;
        hilog.warn(LOG_DOMAIN, TAG, 'loadMore timeout: %{private}s', reason);
      });
    // chat_list 缺省 = null = 主列表（TDLib from_json 对可空字段缺省即 null；
    // 同时规避 ArkTS 对 Object 槽位赋 null 字面量的类型限制）
    const request: Record<string, Object> = {
      ['@type']: TdReq.LOAD_CHATS,
      'limit': PAGE_SIZE
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
  }

  /** 订阅列表变化（合批后的粗粒度通知；订阅不回放当前状态，UI 自行拉取快照） */
  addObserver(observer: ChatListObserver): void {
    if (!this.observers.includes(observer)) {
      this.observers.push(observer);
    }
  }

  removeObserver(observer: ChatListObserver): void {
    const index: number = this.observers.indexOf(observer);
    if (index >= 0) {
      this.observers.splice(index, 1);
    }
  }

  // ---------------- 请求 ----------------

  private requestFirstPage(): void {
    this.actionSeq += 1;
    const extra: string = `getChats_${this.actionSeq}`;
    // 首屏失败（网络/超时）只留日志便于真机排查；不自动重试（待真机验证项）
    TdUpdateRouter.getInstance().waitForExtra(extra, GET_CHATS_TIMEOUT_MS)
      .then((): void => {
        // 正常路径：结果以 @type=chats 走 handleChatsResult
      })
      .catch((reason: string): void => {
        hilog.warn(LOG_DOMAIN, TAG, 'getChats no response: %{private}s', reason);
      });
    const request: Record<string, Object> = {
      // chat_list 缺省即主列表（见 loadMore 注释）
      ['@type']: TdReq.GET_CHATS,
      'limit': PAGE_SIZE
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
  }

  // ---------------- 更新处理 ----------------

  /** updateNewChat / getChat 结果：chat 对象原样入库 + 应用 positions + 重排 */
  private upsertChat(chat: Record<string, Object> | null): void {
    if (chat === null) {
      return;
    }
    const chatId: number = this.readChatId(chat);
    if (chatId === 0) {
      return;
    }
    this.chatById.set(chatId, chat);
    this.applyPositionsField(chat);
    this.insertOrdered(chatId);
    // M6-4：私聊会话入库即确保用户对象在途（在线状态/精确发送者名依赖）
    const userId: number = this.privateUserIdOf(chatId);
    if (userId !== 0) {
      UserStore.getInstance().ensureUser(userId);
    }
    this.notifyChanged();
  }

  /** chats 结果（getChats/searchChats 通用）：兜底补拉缺失 chat + 整表重排（修累积误差） */
  private handleChatsResult(update: Record<string, Object>): void {
    this.firstPageLoaded = true;
    const idsObj: Object | undefined = update[TdField.CHAT_IDS];
    if (Array.isArray(idsObj)) {
      const ids: Array<number> = idsObj as Array<number>;
      let missing: number = 0;
      for (const chatId of ids) {
        if (!this.chatById.has(chatId)) {
          // 防御：按契约 updateNewChat 应已到达；未到则显式补拉
          missing += 1;
          TdClient.getInstance().send({
            ['@type']: TdReq.GET_CHAT,
            'chat_id': chatId
          });
        }
      }
      if (missing > 0) {
        hilog.info(LOG_DOMAIN, TAG, 'chats result: %{public}d chats missing, fallback getChat', missing);
      }
      const totalObj: Object | undefined = update['total_count'];
      const totalCount: number = typeof totalObj === 'number' ? totalObj : 0;
      if (totalCount > 0 && totalCount <= this.orderedIds.length) {
        this.hasMore = false;
      }
    }
    this.rebuildOrdered();
    hilog.info(LOG_DOMAIN, TAG, 'chats result handled, ordered=%{public}d', this.orderedIds.length);
    this.notifyChanged();
  }

  /**
   * updateChatPosition（1.8.63 为单数 position 字段）：
   * 仅处理 chatListMain；order==0 表示移出该列表（TDLib 契约）。
   */
  private handleChatPosition(update: Record<string, Object>): void {
    const chatId: number = this.readChatId(update);
    if (chatId === 0) {
      return;
    }
    const position: Record<string, Object> | null = this.readRecord(update, TdField.POSITION);
    if (position === null || !this.isMainList(position)) {
      return;
    }
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chat === undefined) {
      return;
    }
    this.replacePosition(chat, position);
    this.insertOrdered(chatId);
    this.notifyChanged();
  }

  /** updateChatLastMessage：预览/时间刷新 + positions（该更新可替代 updateChatPosition 下发） */
  private handleChatLastMessage(update: Record<string, Object>): void {
    const chatId: number = this.readChatId(update);
    if (chatId === 0) {
      return;
    }
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chat === undefined) {
      return;
    }
    const lastMessage: Object | undefined = update[TdField.LAST_MESSAGE];
    if (lastMessage !== undefined) {
      // TDLib 序列化可空字段为 null（非缺省），null 由消费侧按「无预览」处理
      chat[TdField.LAST_MESSAGE] = lastMessage;
    }
    const positionsObj: Object | undefined = update[TdField.POSITIONS];
    if (Array.isArray(positionsObj)) {
      chat[TdField.POSITIONS] = positionsObj;
    }
    this.insertOrdered(chatId);
    this.notifyChanged();
  }

  /** updateChatReadInbox：未读数（last_read_inbox_message_id M3 已读回执再用） */
  private handleChatReadInbox(update: Record<string, Object>): void {
    const chatId: number = this.readChatId(update);
    if (chatId === 0) {
      return;
    }
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chat === undefined) {
      return;
    }
    const unread: Object | undefined = update[TdField.UNREAD_COUNT];
    if (typeof unread === 'number') {
      chat[TdField.UNREAD_COUNT] = unread;
      this.notifyChanged();
    }
  }

  /** updateChatTitle：标题变更 */
  private handleChatTitle(update: Record<string, Object>): void {
    const chatId: number = this.readChatId(update);
    if (chatId === 0) {
      return;
    }
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chat === undefined) {
      return;
    }
    const title: Object | undefined = update[TdField.TITLE];
    if (typeof title === 'string') {
      chat[TdField.TITLE] = title;
      this.notifyChanged();
    }
  }

  /** updateChatPhoto：头像（M2 仅存储；照片展示 M3 接 downloadFile 时用） */
  private handleChatPhoto(update: Record<string, Object>): void {
    const chatId: number = this.readChatId(update);
    if (chatId === 0) {
      return;
    }
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chat === undefined) {
      return;
    }
    const photo: Object | undefined = update[TdField.PHOTO];
    if (photo !== undefined) {
      chat[TdField.PHOTO] = photo;
    }
    this.notifyChanged();
  }

  /**
   * updateChatNotificationSettings（1.8.63 schema：{ notification_settings, chat_id? }）：
   * 免打扰等设置变更整体替换对应 chat 的 notification_settings——这是
   * NotificationService.isMuted 的唯一数据源，不接此更新则 mute_for 永远停留在
   * updateNewChat 入库时的快照（复审 HIGH-2：mute_for 数据源永不刷新）。
   * chat_id 缺省（全局默认设置变更）时忽略：本仓库按会话粒度消费，全量刷新需逐 chat
   * 重拉 getChat，代价大于收益（设置类功能整体挂 M5）。
   */
  private handleChatNotificationSettings(update: Record<string, Object>): void {
    const chatId: number = this.readChatId(update);
    if (chatId === 0) {
      return;
    }
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chat === undefined) {
      return;
    }
    const settings: Record<string, Object> | null = this.readRecord(update, TdField.NOTIFICATION_SETTINGS);
    if (settings === null) {
      return;
    }
    chat[TdField.NOTIFICATION_SETTINGS] = settings;
    this.notifyChanged();
  }

  /**
   * updateChatReadOutbox（M5 复审 LOW 修复）：把 outbox 已读游标同步进 chat 存量记录。
   * 背景：MessageStore 缓存被 LRU 淘汰后重建（createCache）以 chat.last_read_outbox_message_id
   * 为已读游标种子——本仓库此前只在 updateNewChat 全量入库时拿到该字段，缓存存活期间到达的
   * outbox 推进不会落进本表，淘汰重建后已读双勾会回退到陈旧游标。此处按 max 单调同步，
   * MessageStore 自身的增量 handler 仍在（双通道，语义一致）。
   * 列表 UI 不消费该字段：不触发 UI 通知（省一次无意义重建）。
   */
  private handleChatReadOutbox(update: Record<string, Object>): void {
    const chatId: number = this.readChatId(update);
    if (chatId === 0) {
      return;
    }
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chat === undefined) {
      return;
    }
    const lastRead: number = this.readNumber(update, TdField.LAST_READ_OUTBOX_MESSAGE_ID);
    if (lastRead > this.readNumber(chat, TdField.LAST_READ_OUTBOX_MESSAGE_ID)) {
      chat[TdField.LAST_READ_OUTBOX_MESSAGE_ID] = lastRead;
    }
  }

  // ---------------- 排序（chatListMain，(order, chat_id) 降序） ----------------

  /** 全量重建（首屏 chats 结果 / 兜底）：O(n log n) */
  private rebuildOrdered(): void {
    this.orderedIds = [];
    this.chatById.forEach((chat: Record<string, Object>, chatId: number): void => {
      const order: number = this.readMainOrder(chat);
      if (order > 0) {
        this.orderedIds.push(chatId);
      }
    });
    const store: ChatListStore = this;
    this.orderedIds.sort((a: number, b: number): number => store.compareChat(a, b));
  }

  /**
   * 增量重排：先移除再线性插入。
   * 常见更新（新消息）把会话移向顶部 → 从头扫描近似 O(1)；最坏 O(n)，千级会话可接受（M2 取舍）。
   */
  private insertOrdered(chatId: number): void {
    const index: number = this.orderedIds.indexOf(chatId);
    if (index >= 0) {
      this.orderedIds.splice(index, 1);
    }
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chat === undefined) {
      return;
    }
    if (this.readMainOrder(chat) <= 0) {
      return; // order==0：不在主列表（移出/归档）
    }
    for (let i: number = 0; i < this.orderedIds.length; i++) {
      if (this.compareChat(this.orderedIds[i], chatId) > 0) {
        continue;
      }
      this.orderedIds.splice(i, 0, chatId);
      return;
    }
    this.orderedIds.push(chatId);
  }

  /** (order, chat_id) 降序比较器：返回负值表示 a 应排在 b 前 */
  private compareChat(a: number, b: number): number {
    const chatA: Record<string, Object> | undefined = this.chatById.get(a);
    const chatB: Record<string, Object> | undefined = this.chatById.get(b);
    const orderA: number = chatA === undefined ? 0 : this.readMainOrder(chatA);
    const orderB: number = chatB === undefined ? 0 : this.readMainOrder(chatB);
    if (orderA !== orderB) {
      return orderB - orderA;
    }
    return b - a;
  }

  /** chat.positions → chatListMain 的 position（无则 null） */
  private getMainPosition(chatId: number): Record<string, Object> | null {
    const chat: Record<string, Object> | undefined = this.chatById.get(chatId);
    if (chat === undefined) {
      return null;
    }
    const positionsObj: Object | undefined = chat[TdField.POSITIONS];
    if (!Array.isArray(positionsObj)) {
      return null;
    }
    const positions: Array<Object> = positionsObj as Array<Object>;
    for (const item of positions) {
      const position: Record<string, Object> | null = this.asRecord(item);
      if (position !== null && this.isMainList(position)) {
        return position;
      }
    }
    return null;
  }

  private readMainOrder(chat: Record<string, Object>): number {
    const positionsObj: Object | undefined = chat[TdField.POSITIONS];
    if (!Array.isArray(positionsObj)) {
      return 0;
    }
    const positions: Array<Object> = positionsObj as Array<Object>;
    for (const item of positions) {
      const position: Record<string, Object> | null = this.asRecord(item);
      if (position === null || !this.isMainList(position)) {
        continue;
      }
      const order: Object | undefined = position[TdField.ORDER];
      if (typeof order === 'number') {
        return order;
      }
      // FIX: TDLib 64-bit order may exceed JS Number.MAX_SAFE_INTEGER,
      // JSON parser preserves it as string; parse for sort comparison
      if (typeof order === 'string') {
        return Number(order) || 0;
      }
    }
    return 0;
  }

  /** 单个 position 更新：替换 chat.positions 中同列表项（无则追加） */
  private replacePosition(chat: Record<string, Object>, position: Record<string, Object>): void {
    const positionsObj: Object | undefined = chat[TdField.POSITIONS];
    const positions: Array<Object> = Array.isArray(positionsObj) ? positionsObj as Array<Object> : [];
    for (let i: number = 0; i < positions.length; i++) {
      const existing: Record<string, Object> | null = this.asRecord(positions[i]);
      if (existing !== null && this.isMainList(existing) === this.isMainList(position)) {
        positions[i] = position;
        chat[TdField.POSITIONS] = positions;
        return;
      }
    }
    positions.push(position);
    chat[TdField.POSITIONS] = positions;
  }

  private applyPositionsField(chat: Record<string, Object>): void {
    // chat 对象自带 positions 数组（updateNewChat 全量），原样保留即可；异常缺字段时补空数组防御
    const positionsObj: Object | undefined = chat[TdField.POSITIONS];
    if (!Array.isArray(positionsObj)) {
      chat[TdField.POSITIONS] = new Array<Object>();
    }
  }

  private isMainList(position: Record<string, Object>): boolean {
    const list: Record<string, Object> | null = this.readRecord(position, TdField.LIST);
    if (list === null) {
      return false;
    }
    const typeObj: Object | undefined = list[TdField.TYPE];
    return typeObj === TdChatList.MAIN;
  }

  // ---------------- 工具 ----------------

  private readChatId(source: Record<string, Object>): number {
    const idObj: Object | undefined = source[TdField.CHAT_ID] !== undefined
      ? source[TdField.CHAT_ID] : source[TdField.ID];
    if (typeof idObj === 'number' && Number.isFinite(idObj) && idObj !== 0) {
      return idObj;
    }
    return 0;
  }

  private readNumber(source: Record<string, Object>, field: string): number {
    const value: Object | undefined = source[field];
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value;
    }
    return 0;
  }

  private readRecord(source: Record<string, Object>, field: string): Record<string, Object> | null {
    const value: Object | undefined = source[field];
    return this.asRecord(value);
  }

  private asRecord(value: Object | undefined): Record<string, Object> | null {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return null;
  }

  /** 通知合批：同一宏任务内多次变更只触发一次 UI 刷新（首屏 50 个 updateNewChat 场景） */
  private notifyChanged(): void {
    if (this.notifyScheduled) {
      return;
    }
    this.notifyScheduled = true;
    setTimeout((): void => {
      this.notifyScheduled = false;
      for (const observer of this.observers) {
        try {
          observer();
        } catch (err) {
          hilog.error(LOG_DOMAIN, TAG, 'observer error: %{private}s', JSON.stringify(err));
        }
      }
    }, 0);
  }
}
