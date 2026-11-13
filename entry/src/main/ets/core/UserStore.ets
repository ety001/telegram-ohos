/**
 * 用户仓库（M6-4）。单例。私聊用户对象 + 在线状态缓存。
 *
 * 数据流：
 * - updateUserStatus（TDLib 周期推送）→ 状态写回用户缓存（无缓存则丢弃，首次 getUser 后由
 *   TDLib 侧最新状态补齐——updateUserStatus 会在 getUser 响应前后的任意时刻重推）；
 * - user 结果对象（getUser 响应）→ 全量缓存；
 * - ensureUser：无缓存时发 getUser（在途去重），到达/变更后观察者通知。
 *
 * 在线判定：userStatusOnline.expires > now（TDLib 语义：expires 为在线到期 Unix 秒，
 * 用户下线时会先推 userStatusOffline；冗余判 expires 防漏推）。
 *
 * 生命周期：随 ChatListStore start/reset 同步（Index 登录态分支调用）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TdClient } from '../tdlib/TdClient';
import { TdUpdateRouter, TdRouteHandler } from './TdUpdateRouter';
import { TdReq, TdUpdate, TdField, TdType, ErrorType } from './TdConstants';

const TAG: string = 'UserStore';
const LOG_DOMAIN: number = 0x0012;
const USER_TIMEOUT_MS: number = 10000;

export type UserStoreObserver = () => void;

export class UserStore {
  private static instance: UserStore | null = null;

  /** userId → user 对象（TDLib user 原样） */
  private users: Map<number, Record<string, Object>> = new Map();
  /** 在线状态快照：userId → status 对象（与 user.status 冗余，独立维护防 user 对象未拉到） */
  private statusByUser: Map<number, Record<string, Object>> = new Map();
  private pendingUsers: Set<number> = new Set();
  private observers: Array<UserStoreObserver> = [];
  private started: boolean = false;
  private actionSeq: number = 0;

  private constructor() {
  }

  static getInstance(): UserStore {
    if (UserStore.instance === null) {
      UserStore.instance = new UserStore();
    }
    return UserStore.instance;
  }

  private readonly onUserStatus: TdRouteHandler = (update: Record<string, Object>): void => {
    const userId: number = this.readNumber(update, TdField.USER_ID);
    if (userId === 0) {
      return;
    }
    const status: Record<string, Object> | null = this.asRecord(update[TdField.STATUS]);
    if (status === null) {
      return;
    }
    this.statusByUser.set(userId, status);
    const user: Record<string, Object> | undefined = this.users.get(userId);
    if (user !== undefined) {
      user[TdField.STATUS] = status;
    }
    this.notifyChanged();
  };

  private readonly onUserResult: TdRouteHandler = (update: Record<string, Object>): void => {
    const userId: number = this.readNumber(update, TdField.ID);
    if (userId === 0) {
      return;
    }
    // 已收到的在线状态比 user 对象内嵌的更新（状态推送与对象拉取时序不定）——合并保留最新
    const latestStatus: Record<string, Object> | undefined = this.statusByUser.get(userId);
    if (latestStatus !== undefined) {
      update[TdField.STATUS] = latestStatus;
    }
    this.users.set(userId, update);
    this.pendingUsers.delete(userId);
    this.notifyChanged();
  };

  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    const router: TdUpdateRouter = TdUpdateRouter.getInstance();
    router.register(TdUpdate.USER_STATUS, this.onUserStatus);
    router.register(TdUpdate.USER, this.onUserResult);
    hilog.info(LOG_DOMAIN, TAG, 'started');
  }

  reset(): void {
    if (!this.started && this.users.size === 0 && this.statusByUser.size === 0) {
      return;
    }
    this.users.clear();
    this.statusByUser.clear();
    this.pendingUsers.clear();
    this.started = false;
    this.notifyChanged();
    hilog.info(LOG_DOMAIN, TAG, 'reset');
  }

  /** 无缓存则异步 getUser（在途去重）；命中缓存为无操作 */
  ensureUser(userId: number): void {
    if (userId === 0 || !this.started) {
      return;
    }
    if (this.users.has(userId) || this.pendingUsers.has(userId)) {
      return;
    }
    this.pendingUsers.add(userId);
    this.actionSeq += 1;
    const extra: string = `getUser_${this.actionSeq}`;
    TdUpdateRouter.getInstance().waitForExtra(extra, USER_TIMEOUT_MS)
      .then((): void => {
        this.pendingUsers.delete(userId); // 结果经 onUserResult 入库；此处兜底解在途锁
      })
      .catch((reason: string): void => {
        this.pendingUsers.delete(userId);
      });
    const request: Record<string, Object> = {
      ['@type']: TdReq.GET_USER,
      'user_id': userId
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
  }

  isOnline(userId: number): boolean {
    const user: Record<string, Object> | undefined = this.users.get(userId);
    let status: Record<string, Object> | null | undefined = undefined;
    if (user !== undefined) {
      status = this.asRecord(user[TdField.STATUS]);
    }
    if (status === null || status === undefined) {
      status = this.statusByUser.get(userId) ?? null;
    }
    if (status === null || status === undefined) {
      return false;
    }
    const typeObj: Object | undefined = status[TdField.TYPE];
    if (typeObj !== TdType.USER_STATUS_ONLINE) {
      return false;
    }
    const expires: number = this.readNumber(status, TdField.EXPIRES);
    return expires === 0 || expires > Math.floor(Date.now() / 1000);
  }

  /**
   * 私聊状态行文案（顶栏用；官方语义：在线=windowActiveTextFg，其余=historyStatusFg）。
   * 返回 null = 无状态可显示（未拉到用户/非在线类状态缺时间）。
   */
  statusText(userId: number): string | null {
    const user: Record<string, Object> | undefined = this.users.get(userId);
    let status: Record<string, Object> | null | undefined = undefined;
    if (user !== undefined) {
      status = this.asRecord(user[TdField.STATUS]);
    }
    if (status === null || status === undefined) {
      status = this.statusByUser.get(userId) ?? null;
    }
    if (status === null || status === undefined) {
      return null;
    }
    const typeObj: Object | undefined = status[TdField.TYPE];
    const type: string = typeof typeObj === 'string' ? typeObj : '';
    if (type === TdType.USER_STATUS_ONLINE) {
      return '在线';
    }
    if (type === TdType.USER_STATUS_OFFLINE) {
      const wasOnline: number = this.readNumber(status, TdField.WAS_ONLINE); // userStatusOffline.was_online
      if (wasOnline > 0) {
        return `最后见于 ${UserStore.formatWasOnline(wasOnline)}`;
      }
      return null;
    }
    if (type === 'userStatusRecently') {
      return '最近在线';
    }
    if (type === 'userStatusLastWeek') {
      return '最近一周在线';
    }
    if (type === 'userStatusLastMonth') {
      return '最近一月在线';
    }
    return null;
  }

  /** was_online 时间戳 → 人性化文案（今天=HH:mm / 昨天 / 具体日期） */
  private static formatWasOnline(unixSeconds: number): string {
    const now: Date = new Date();
    const then: Date = new Date(unixSeconds * 1000);
    const sameDay: boolean = now.getFullYear() === then.getFullYear() &&
      now.getMonth() === then.getMonth() && now.getDate() === then.getDate();
    if (sameDay) {
      const hh: string = `${then.getHours()}`.padStart(2, '0');
      const mm: string = `${then.getMinutes()}`.padStart(2, '0');
      return `${hh}:${mm}`;
    }
    const yesterday: Date = new Date(now.getTime() - 86400000);
    const isYesterday: boolean = yesterday.getFullYear() === then.getFullYear() &&
      yesterday.getMonth() === then.getMonth() && yesterday.getDate() === then.getDate();
    if (isYesterday) {
      return '昨天';
    }
    return `${then.getMonth() + 1}月${then.getDate()}日`;
  }

  /** 展示名（first+last；无缓存空串） */
  displayName(userId: number): string {
    const user: Record<string, Object> | undefined = this.users.get(userId);
    if (user === undefined) {
      return '';
    }
    const first: string = this.readString(user, TdField.FIRST_NAME);
    const last: string = this.readString(user, TdField.LAST_NAME);
    const name: string = `${first} ${last}`.trim();
    return name;
  }

  addObserver(observer: UserStoreObserver): void {
    if (!this.observers.includes(observer)) {
      this.observers.push(observer);
    }
  }

  removeObserver(observer: UserStoreObserver): void {
    const index: number = this.observers.indexOf(observer);
    if (index >= 0) {
      this.observers.splice(index, 1);
    }
  }

  private notifyChanged(): void {
    for (const observer of this.observers) {
      try {
        observer();
      } catch (err) {
        hilog.error(LOG_DOMAIN, TAG, 'observer error: %{private}s', JSON.stringify(err));
      }
    }
  }

  private readNumber(source: Record<string, Object>, field: string): number {
    const value: Object | undefined = source[field];
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value;
    }
    return 0;
  }

  private readString(source: Record<string, Object>, field: string): string {
    const value: Object | undefined = source[field];
    return typeof value === 'string' ? value : '';
  }

  private asRecord(value: Object | undefined): Record<string, Object> | null {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return null;
  }
}
