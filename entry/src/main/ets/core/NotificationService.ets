/**
 * 本地通知服务（M3，PLAN §5「本地通知 + 点击路由」）。单例。
 *
 * 数据流（与 MessageStore/ChatListStore 平行的第三条路由支路，Router 多 handler 依注册序分发）：
 *   TdClient 接收线程 → TdUpdateRouter（updateNewMessage）→ 本服务 → notificationManager.publish
 *
 * 触发规则矩阵（handleNewMessage 逐条短路）：
 *   1. is_outgoing            → 不通知（自己发的）
 *   2. AuthService 未 ready    → 不通知（登录态之外无消息语义）
 *   3. chat 免打扰（TDLib chat.notification_settings.mute_for > 0）→ 不通知
 *   4. 该会话正打开且应用前台 → 不通知（用户正在看；活跃会话由 ChatPanel activate/deactivate 接线，
 *      前后台由 EntryAbility onForeground/onBackground 接线）
 *   5. 其余（应用后台 / 会话未打开）→ publish 本地通知
 *
 * 通知内容（NotificationBasicContent，简版统一基本通知；分组/渠道 M5）：
 *   title = 会话标题（ChatListStore.getTitle，缺省 Telegram）
 *   text  = 消息预览（MessageContent.previewTextOf：文本压空白单行截 80 字，媒体给占位文案）
 *   additionalText = 同会话连续未读时追加「N 条新消息」
 *   通知内容含聊天内容仅进用户可见面（通知面板），永不进日志。
 *
 * 去重合并：通知 id 由 chatId 一对一映射（负 id 会话折为非负，见 notificationIdOf），
 *   同会话连续消息 publish 同 id → 系统按同 id 覆盖更新（官方契约：同 ID 新通知替换旧通知）。
 *
 * 点击路由（官方机制，Notification Kit「为通知添加行为意图」）：
 *   publish 时 request.wantAgent 携带 want(bundleName+abilityName+parameters.chatId)，
 *   operationType=START_ABILITY；EntryAbility 为 singleton 启动模式，点击通知后
 *   冷启动走 onCreate(want)、存活态走 onNewWant(want)，chatId 从 want.parameters 取回
 *   → handleLaunchWant → 观察者（Index）路由：sm 推 ChatPage / md-lg 选中会话。
 *
 * 授权引导：首次 publish 前调 requestEnableNotification(context)（一次弹窗）；
 *   用户拒绝（1600004）后记录状态静默降级不再请求（SDK 契约：拒绝后该 API 也不再弹窗），
 *   每次回前台用 isNotificationEnabledSync 自愈（用户从系统设置手动开启后无需重启应用）。
 *
 * 日志红线：通知标题/正文（即聊天内容）一律不打日志，仅记录 chatId/数量/状态码。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, WantAgent, Want, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { TdUpdateRouter, TdRouteHandler } from './TdUpdateRouter';
import { ChatListStore } from './ChatListStore';
import { AuthService, AppAuthState } from './AuthService';
import { MessageContent } from './MessageContent';
import { ConfigStore } from './ConfigStore';
import { TdUpdate, TdField } from './TdConstants';

const TAG: string = 'NotificationService';
const LOG_DOMAIN: number = 0x0012;
/** 通知正文预览截断长度（字符，按码点计） */
const PREVIEW_MAX_CHARS: number = 80;
/** 弹窗已在展示（并发首消息窗口），保持未判定态不降级 */
const ERROR_DIALOG_SHOWN: number = 1600013;
/** 点击路由 want 参数键（wantAgent parameters → onNewWant/onCreate want.parameters） */
const WANT_KEY_CHAT_ID: string = 'chatId';
/** 点击路由目标 ability（module.json5 mainElement） */
const ABILITY_NAME: string = 'EntryAbility';
/** 兜底标题（chat 未入库/标题为空时；通知 title 不允许空串） */
const FALLBACK_TITLE: string = 'Telegram';

/** 授权状态（应用生命周期内记忆，不落盘：SDK 侧自有持久判定） */
class PermissionState {
  static readonly UNKNOWN: string = 'unknown';
  static readonly GRANTED: string = 'granted';
  static readonly DENIED: string = 'denied';
}

export type ChatRouteObserver = (chatId: number) => void;

export class NotificationService {
  private static instance: NotificationService | null = null;

  private started: boolean = false;
  private permission: string = PermissionState.UNKNOWN;
  /** 首次授权请求在途（并发的首屏消息共用同一次弹窗，避免 1600013） */
  private permissionPromise: Promise<boolean> | null = null;
  /** 应用前后台（EntryAbility onForeground/onBackground 接线；默认前台） */
  private foreground: boolean = true;
  /** 当前正被查看的会话（ChatPanel activate/deactivate 接线；0 = 无） */
  private activeChatId: number = 0;
  /** 授权弹窗与 wantAgent 构建所需（EntryAbility.onCreate 接线） */
  private abilityContext: common.UIAbilityContext | null = null;
  private bundleName: string = '';
  /** 同会话连续未读计数（通知被打开会话/登出清零；additionalText 展示「N 条新消息」） */
  private pendingByChat: Map<number, number> = new Map();
  /** 点击路由待跳转会话（冷启动时 Index 未就绪先暂存，aboutToAppear 消费） */
  private pendingChatId: number = 0;
  private chatRouteObservers: Array<ChatRouteObserver> = [];

  private constructor() {
  }

  static getInstance(): NotificationService {
    if (NotificationService.instance === null) {
      NotificationService.instance = new NotificationService();
    }
    return NotificationService.instance;
  }

  // ---------------- 生命周期 ----------------

  // 路由 handler 提为成员：重复 start 由 Router 去重（沿 MessageStore/ChatListStore 风格）
  private readonly onNewMessage: TdRouteHandler = (update: Record<string, Object>): void => {
    const message: Record<string, Object> | null = NotificationService.asRecord(update[TdField.MESSAGE]);
    if (message === null) {
      return;
    }
    this.handleNewMessage(message);
  };

  /** 登录就绪后触发（幂等）：挂 updateNewMessage 路由。由 Index 会话仓库生命周期同步调用 */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    TdUpdateRouter.getInstance().register(TdUpdate.NEW_MESSAGE, this.onNewMessage);
    hilog.info(LOG_DOMAIN, TAG, 'started');
  }

  /** 登出/会话结束（authState 离开 ready）：清在途状态并撤下已发通知（授权状态为应用级，保留） */
  reset(): void {
    const notified: Array<number> = [];
    this.pendingByChat.forEach((count: number, chatId: number): void => {
      notified.push(chatId);
    });
    this.pendingByChat.clear();
    this.pendingChatId = 0;
    this.activeChatId = 0;
    for (const chatId of notified) {
      notificationManager.cancel(NotificationService.notificationIdOf(chatId))
        .catch((err: BusinessError): void => {
          hilog.warn(LOG_DOMAIN, TAG, 'cancel on reset failed: %{public}d', err.code);
        });
    }
    hilog.info(LOG_DOMAIN, TAG, 'reset for next login, canceled=%{public}d', notified.length);
  }

  /** EntryAbility.onCreate 接线：授权弹窗（requestEnableNotification 需 UIAbilityContext）与
   *  wantAgent 目标（bundleName）依赖上下文 */
  attach(context: common.UIAbilityContext): void {
    this.abilityContext = context;
    try {
      this.bundleName = context.abilityInfo.bundleName;
    } catch (err) {
      // 读取异常仅置空降级：wantAgent 的 want 以 bundleName+abilityName 定位目标 ability，
      // bundleName 为空时点击拉起可能失效——失败面收敛为「点击通知不路由」（通知本体展示
      // 与撤下均不受影响，消息仍在会话内可见）；本路径仅在 abilityInfo 读取抛错时到达（防御性）
      this.bundleName = '';
      hilog.warn(LOG_DOMAIN, TAG, 'read bundleName failed: %{private}s', JSON.stringify(err));
    }
  }

  /** EntryAbility onForeground/onBackground 接线：前台时正打开的会话视为「用户正在看」不通知；
   *  回前台顺带自愈授权状态（用户可能已从系统设置开启通知） */
  setForeground(foreground: boolean): void {
    this.foreground = foreground;
    if (foreground && this.permission === PermissionState.DENIED) {
      this.healPermissionIfEnabled();
    }
  }

  /** ChatPanel activate/deactivate 接线：当前正被查看的会话（0 = 无）。切到该会话即撤其通知（已读） */
  setActiveChat(chatId: number): void {
    this.activeChatId = chatId;
    if (chatId !== 0) {
      this.clearChatNotification(chatId);
    }
  }

  // ---------------- 通知触发（updateNewMessage） ----------------

  private handleNewMessage(message: Record<string, Object>): void {
    const chatId: number = NotificationService.readNumber(message, TdField.CHAT_ID);
    if (chatId === 0) {
      return;
    }
    // 规则 1：自己发的不通知
    if (message[TdField.IS_OUTGOING] === true) {
      return;
    }
    // 规则 2：非登录就绪态不通知
    if (AuthService.getInstance().getAuthState() !== AppAuthState.READY) {
      return;
    }
    // 规则 3：会话免打扰（TDLib 侧 mute 设置）不通知
    if (this.isMuted(chatId)) {
      return;
    }
    // 规则 4：用户正在看该会话（会话正打开且应用前台）不通知
    if (this.foreground && this.activeChatId === chatId) {
      return;
    }
    // 规则 5：应用后台 / 会话未打开 → 发布
    this.publishForChat(chatId, message);
  }

  /** chat.notification_settings.mute_for > 0 → 免打扰（1.8.63 schema：chatNotificationSettings.mute_for；
   *  数据源由 ChatListStore 的 updateChatNotificationSettings handler 实时刷新，复审 HIGH-2） */
  private isMuted(chatId: number): boolean {
    const chat: Record<string, Object> | undefined = ChatListStore.getInstance().getChat(chatId);
    if (chat === undefined) {
      return false;
    }
    const settings: Record<string, Object> | null =
      NotificationService.asRecord(chat[TdField.NOTIFICATION_SETTINGS]);
    if (settings === null) {
      return false;
    }
    return NotificationService.readNumber(settings, TdField.MUTE_FOR) > 0;
  }

  private publishForChat(chatId: number, message: Record<string, Object>): void {
    // 通知内容仅进用户可见面，不落任何日志（红线）
    const title: string = this.resolveTitle(chatId);
    const previewPromise: Promise<string> = ConfigStore.getNotifyPreview()
      .catch((): boolean => true)
      .then((showPreview: boolean): string => {
        // 预览关（M6-8）：正文固定文案，不泄露消息内容（标题仍为会话名）
        if (!showPreview) {
          return '你有一条新消息';
        }
        return NotificationService.truncate(
          MessageContent.previewTextOf(message), PREVIEW_MAX_CHARS);
      });

    this.ensurePermission()
      .then((granted: boolean): void => {
        if (!granted) {
          return; // 用户拒绝/不可用：静默降级（状态已记录，不再骚扰）
        }
        previewPromise.then((text: string): void => {
          // 授权后才计数（拒绝期消息不进「N 条新消息」，授权自愈后从 1 起算）
          const count: number = (this.pendingByChat.get(chatId) ?? 0) + 1;
          this.pendingByChat.set(chatId, count);
          const additional: string = count > 1 ? `${count} 条新消息` : '';
          this.buildWantAgent(chatId).then((agent: WantAgent): void => {
            this.publish(chatId, agent, title, text, additional);
          }).catch((err: BusinessError): void => {
            hilog.warn(LOG_DOMAIN, TAG, 'getWantAgent failed: %{public}d', err.code);
            this.rollbackPending(chatId); // 通知未发布，计数回滚（见 rollbackPending 注释）
          });
        });
      });
  }

  private publish(chatId: number, agent: WantAgent, title: string, text: string, additional: string): void {
    const basic: notificationManager.NotificationBasicContent = {
      title: title,
      text: text.length > 0 ? text : '新消息'
    };
    if (additional.length > 0) {
      basic.additionalText = additional;
    }
    const request: notificationManager.NotificationRequest = {
      id: NotificationService.notificationIdOf(chatId),
      // 社交通信类槽位（LEVEL_HIGH：通知中心/铃声/振动/锁屏默认开启；横幅默认关闭——
      // 横幅为用户侧系统设置项，应用不可控。槽位/分组细化 M5）
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: basic
      },
      // 点击通知触发 wantAgent（官方「为通知添加行为意图」机制）→ EntryAbility onCreate/onNewWant
      wantAgent: agent
    };
    notificationManager.publish(request)
      .then((): void => {
        hilog.info(LOG_DOMAIN, TAG, 'published: chat=%{public}s count=%{public}d', `${chatId}`,
          this.pendingByChat.get(chatId) ?? 0);
      })
      .catch((err: BusinessError): void => {
        // 失败不重试不打扰（通知为增强通道，消息本体已在会话内）；
        // 回滚本条计数（复审 LOW-7）：失败的通知从未上屏，留着会让同会话下一条多算「N 条新消息」
        this.rollbackPending(chatId);
        hilog.warn(LOG_DOMAIN, TAG, 'publish failed: %{public}d', err.code);
      });
  }

  /** 通知 id 与 chatId 一对一双射（通知 id 习惯取非负；TDLib 群组/频道/密聊 id 为负）：
   *  chatId ≥ 0 → 2*chatId；chatId < 0 → 2*(-chatId) - 1。同会话同 id → 系统侧覆盖合并 */
  private static notificationIdOf(chatId: number): number {
    if (chatId >= 0) {
      return 2 * chatId;
    }
    return -2 * chatId - 1;
  }

  /** 撤下该会话的通知（用户打开会话已读/登出清理） */
  private clearChatNotification(chatId: number): void {
    if (!this.pendingByChat.has(chatId)) {
      return;
    }
    this.pendingByChat.delete(chatId);
    notificationManager.cancel(NotificationService.notificationIdOf(chatId))
      .catch((err: BusinessError): void => {
        hilog.warn(LOG_DOMAIN, TAG, 'cancel failed: %{public}d', err.code);
      });
  }

  /** publish/getWantAgent 失败回滚该会话的一条计数（未上屏的通知不计入「N 条新消息」）；
   *  并发同会话消息交错到账的极端时序下计数偏差 ±1——计数仅用于附加文案，取舍可接受 */
  private rollbackPending(chatId: number): void {
    const count: number = this.pendingByChat.get(chatId) ?? 0;
    if (count <= 1) {
      this.pendingByChat.delete(chatId);
    } else {
      this.pendingByChat.set(chatId, count - 1);
    }
  }

  private resolveTitle(chatId: number): string {
    const title: string = ChatListStore.getInstance().getTitle(chatId).trim();
    return title.length > 0 ? title : FALLBACK_TITLE;
  }

  // ---------------- 授权 ----------------

  /** 首次发布前引导授权（一次弹窗）；拒绝后记录状态静默降级。UNKNOWN→请求；GRANTED→直通；DENIED→短路 */
  private ensurePermission(): Promise<boolean> {
    if (this.permission === PermissionState.GRANTED) {
      return Promise.resolve(true);
    }
    if (this.permission === PermissionState.DENIED) {
      return Promise.resolve(false);
    }
    if (this.permissionPromise !== null) {
      return this.permissionPromise; // 弹窗在途：并发的首屏消息共用同一次请求
    }
    const context: common.UIAbilityContext | null = this.abilityContext;
    if (context === null) {
      return Promise.resolve(false); // 上下文未接线（attach 前无消息可发，防御）
    }
    const promise: Promise<boolean> = notificationManager.requestEnableNotification(context)
      .then((): boolean => {
        this.permissionPromise = null;
        this.permission = PermissionState.GRANTED;
        hilog.info(LOG_DOMAIN, TAG, 'notification enabled');
        return true;
      })
      .catch((err: BusinessError): boolean => {
        this.permissionPromise = null;
        if (err.code === ERROR_DIALOG_SHOWN) {
          return false; // 弹窗已展示（并发窗口）：不降级判定，等用户在弹窗上的选择落定
        }
        // 1600004（用户拒绝/未开启）与其他失败一律记拒绝：静默降级不再请求，
        // 回前台时 isNotificationEnabledSync 自愈（用户从系统设置开启的场景）
        this.permission = PermissionState.DENIED;
        hilog.info(LOG_DOMAIN, TAG, 'notification disabled (user), code=%{public}d', err.code);
        return false;
      });
    this.permissionPromise = promise;
    return promise;
  }

  /** 回前台自愈：用户已在系统设置开启通知 → 恢复 GRANTED（无需重启应用） */
  private healPermissionIfEnabled(): void {
    try {
      if (notificationManager.isNotificationEnabledSync()) {
        this.permission = PermissionState.GRANTED;
        hilog.info(LOG_DOMAIN, TAG, 'notification re-enabled in settings');
      }
    } catch (err) {
      hilog.warn(LOG_DOMAIN, TAG, 'query enabled failed: %{private}s', JSON.stringify(err));
    }
  }

  // ---------------- 点击路由 ----------------

  /** wantAgent 构建（同步抛错转 rejection 统一走调用方 catch：无路由信息的通知不发布，防点击无响应） */
  private buildWantAgent(chatId: number): Promise<WantAgent> {
    // 键须为字符串字面量（arkts-identifiers-as-prop-names，沿工程约定），读取侧用 WANT_KEY_CHAT_ID 常量
    const want: Want = {
      bundleName: this.bundleName,
      abilityName: ABILITY_NAME,
      parameters: { 'chatId': chatId }
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      // 11+ 推荐字段：actionType/actionFlags（operationType/wantAgentFlags 已废弃）
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      return wantAgent.getWantAgent(info);
    } catch (err) {
      // 参数类同步抛错（401）：转 rejection 统一走调用方 catch（缺路由的通知不发布）
      hilog.warn(LOG_DOMAIN, TAG, 'getWantAgent threw: %{private}s', JSON.stringify(err));
      return new Promise<WantAgent>((resolve: (v: WantAgent) => void,
        reject: (r: BusinessError) => void): void => {
        reject(err as BusinessError);
      });
    }
  }

  /** EntryAbility onCreate（冷启动）/ onNewWant（存活态，singleton）接线：解析通知点击携带的 chatId */
  handleLaunchWant(want: Want): void {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined || params === null) {
      return;
    }
    const value: Object | undefined = params[WANT_KEY_CHAT_ID];
    let chatId: number = 0;
    if (typeof value === 'number' && Number.isFinite(value)) {
      chatId = value;
    } else if (typeof value === 'string') {
      // want 参数经系统侧序列化可能字符串化，防御双形态；非数字载荷 parseInt 得 NaN，直接忽略
      const parsed: number = Number.parseInt(value);
      if (!Number.isFinite(parsed)) {
        return;
      }
      chatId = parsed;
    }
    if (chatId === 0) {
      return;
    }
    this.pendingChatId = chatId;
    hilog.info(LOG_DOMAIN, TAG, 'notification click: chat=%{public}s', `${chatId}`);
    this.notifyChatRoute(chatId);
  }

  /** 冷启动暂存消费（Index aboutToAppear / 登录就绪时机）；取出即清，防重复路由 */
  consumePendingChatId(): number {
    const chatId: number = this.pendingChatId;
    this.pendingChatId = 0;
    return chatId;
  }

  addChatRouteObserver(observer: ChatRouteObserver): void {
    if (!this.chatRouteObservers.includes(observer)) {
      this.chatRouteObservers.push(observer);
    }
  }

  removeChatRouteObserver(observer: ChatRouteObserver): void {
    const index: number = this.chatRouteObservers.indexOf(observer);
    if (index >= 0) {
      this.chatRouteObservers.splice(index, 1);
    }
  }

  private notifyChatRoute(chatId: number): void {
    for (const observer of this.chatRouteObservers) {
      try {
        observer(chatId);
      } catch (err) {
        hilog.error(LOG_DOMAIN, TAG, 'route observer error: %{private}s', JSON.stringify(err));
      }
    }
  }

  // ---------------- 工具 ----------------

  /** 按码点截断：单码点字符（含 BMP 内 CJK）不会劈半；字素簇（ZWJ 组合 emoji、
   *  国旗等多码点序列）可能被切在簇中间——展示层单行省略场景可容忍，暂不引 ICU 分簇 */
  private static truncate(text: string, maxChars: number): string {
    if (text.length <= maxChars) {
      return text;
    }
    return Array.from(text).slice(0, maxChars).join('');
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
