/**
 * 媒体下载状态仓库（M3-media）。单例。
 *
 * 数据流：
 *   请求侧：UI → downloadFile(fileId, priority, offset, limit) → TDLib downloadFile（@extra 关联）
 *   回报侧：updateFile.file（进度/完成）与 downloadFile 响应（file 对象，同样携带最新状态）
 *           → applyFile → entries 状态机 → onFileChanged(fileId) → MessageBubble 等订阅者
 *
 * TDLib 契约（1.8.63 td_api.tl@f06b0bac）：
 * - downloadFile(file_id:int32, priority:int32 1-32, offset:int53, limit:int53, synchronous:Bool)
 *   返回 file；进度与完成统一经 updateFile 推送（同步参数 false 时响应仅是启动后瞬时快照）；
 * - 同一 file_id 重复 downloadFile 由 TDLib 自身去重合并（FileManager 按 file_id 记账），
 *   桥接层只做状态跟踪 + 请求侧去重（active/ready 态不重发，避免重复改优先级）；
 * - localFile.is_downloading_completed = 本地副本完整可读，path 即沙盒内绝对路径。
 *
 * 状态机（entries）：
 *   active（is_downloading_active，progress = downloaded_size/expected_size 百分比）
 *   ready（is_downloading_completed && path 非空）
 *   failed（downloadFile 响应 error / 超时兜底——updateFile 仍在流动时不误判）
 *   trackFile：消息 content 自带的 file 对象（TDLib 自动下载或历史缓存）直接入表做种子，
 *   后续 updateFile 天然接续。
 *
 * 日志红线：本地路径/文件名不入日志（路径含 TDLib 沙盒文件名，可能带用户内容特征），仅记 fileId/进度。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileUri } from '@kit.CoreFileKit';
import { TdClient } from '../tdlib/TdClient';
import { TdUpdateRouter, TdRouteHandler } from './TdUpdateRouter';
import { TdReq, TdUpdate, TdField, ErrorType } from './TdConstants';

const TAG: string = 'FileDownloadStore';
const LOG_DOMAIN: number = 0x0012;
/** downloadFile 响应等待上限：响应只做 error 检出与瞬时快照，超时不判失败（updateFile 仍在推） */
const DOWNLOAD_RESPONSE_TIMEOUT_MS: number = 30000;
/** 下载优先级（TDLib 1-32）：媒体自动预载低优先，用户点击触发的下载最高 */
export class DownloadPriority {
  static readonly THUMBNAIL: number = 8;
  static readonly PHOTO: number = 16;
  static readonly USER_ACTION: number = 32;
}

/** 下载条目状态 */
export class DownloadState {
  static readonly ACTIVE: string = 'active';
  static readonly READY: string = 'ready';
  static readonly FAILED: string = 'failed';
}

interface DownloadEntry {
  fileId: number;
  state: string;
  /** 0-100；-1 = 尺寸未知 */
  progress: number;
  /** 本地绝对路径（ready 态非空） */
  path: string;
}

export type FileDownloadObserver = (fileId: number) => void;

export class FileDownloadStore {
  private static instance: FileDownloadStore | null = null;

  private entries: Map<number, DownloadEntry> = new Map();
  private observers: Array<FileDownloadObserver> = [];
  private started: boolean = false;
  private seq: number = 0;

  private constructor() {
  }

  static getInstance(): FileDownloadStore {
    if (FileDownloadStore.instance === null) {
      FileDownloadStore.instance = new FileDownloadStore();
    }
    return FileDownloadStore.instance;
  }

  // 路由 handler 提为成员：重登录（reset→start）后重复 register 由 Router 去重
  private readonly onUpdateFile: TdRouteHandler = (update: Record<string, Object>): void => {
    const file: Record<string, Object> | null = this.readRecord(update, TdField.FILE);
    if (file !== null) {
      this.applyFile(file);
    }
  };

  /** 登录就绪后触发（幂等）：挂 updateFile 路由。由 Index 会话仓库生命周期同步调用 */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    TdUpdateRouter.getInstance().register(TdUpdate.UPDATE_FILE, this.onUpdateFile);
    hilog.info(LOG_DOMAIN, TAG, 'started');
  }

  /** 登出重置：清状态表（TDLib 侧文件缓存由其自管，重登后按新 file id 重建） */
  reset(): void {
    if (!this.started && this.entries.size === 0) {
      return;
    }
    this.entries.clear();
    this.started = false;
    hilog.info(LOG_DOMAIN, TAG, 'reset for next login');
  }

  // ---------------- 请求 ----------------

  /**
   * 下载文件（去重：同 file_id 已 active/ready 时不重发——并发请求合并为首次的状态流）。
   * offset/limit 传 0/0 = 全量下载。
   */
  downloadFile(fileId: number, priority: number, offset: number, limit: number): void {
    if (fileId === 0 || !this.started) {
      return;
    }
    const existing: DownloadEntry | undefined = this.entries.get(fileId);
    if (existing !== undefined && existing.state !== DownloadState.FAILED) {
      return; // active 合并 / ready 复用；failed 允许重发
    }
    this.ensureEntry(fileId);
    this.seq += 1;
    const extra: string = `downloadFile_${this.seq}`;
    TdUpdateRouter.getInstance().waitForExtra(extra, DOWNLOAD_RESPONSE_TIMEOUT_MS)
      .then((update: Record<string, Object>): void => {
        const typeObj: Object | undefined = update[TdField.TYPE];
        if (typeof typeObj === 'string' && typeObj === ErrorType.INVALID) {
          const entry: DownloadEntry | undefined = this.entries.get(fileId);
          if (entry !== undefined && entry.state !== DownloadState.READY) {
            entry.state = DownloadState.FAILED;
            this.notify(fileId);
          }
          hilog.warn(LOG_DOMAIN, TAG, 'downloadFile rejected: file=%{public}d code=%{public}s',
            fileId, `${update['code']}`);
          return;
        }
        // 正常响应：file 快照（同步 false 时多为 active 态，完成态仍以 updateFile 为准）
        this.applyFile(update);
      })
      .catch((reason: string): void => {
        // 响应超时不判失败：updateFile 进度流仍在（慢网络大文件常态）
        hilog.warn(LOG_DOMAIN, TAG, 'downloadFile no response: file=%{public}d', fileId);
      });
    const request: Record<string, Object> = {
      ['@type']: TdReq.DOWNLOAD_FILE,
      'file_id': fileId,
      'priority': priority,
      'offset': offset,
      'limit': limit,
      'synchronous': false
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
    hilog.info(LOG_DOMAIN, TAG, 'downloadFile: file=%{public}d priority=%{public}d', fileId, priority);
  }

  /**
   * 状态种子：消息 content 携带的 file 对象直接入表（不入请求）。
   * 场景：TDLib 自动下载已进行中（is_downloading_active）或历史文件缓存已完成（completed+path）。
   */
  trackFile(file: Record<string, Object> | null): void {
    if (file === null) {
      return;
    }
    const fileId: number = this.readNumber(file, TdField.ID);
    if (fileId === 0) {
      return;
    }
    this.ensureEntry(fileId);
    this.applyFile(file);
  }

  // ---------------- 状态访问 ----------------

  isReady(fileId: number): boolean {
    const entry: DownloadEntry | undefined = this.entries.get(fileId);
    return entry !== undefined && entry.state === DownloadState.READY;
  }

  isActive(fileId: number): boolean {
    const entry: DownloadEntry | undefined = this.entries.get(fileId);
    return entry !== undefined && entry.state === DownloadState.ACTIVE;
  }

  isFailed(fileId: number): boolean {
    const entry: DownloadEntry | undefined = this.entries.get(fileId);
    return entry !== undefined && entry.state === DownloadState.FAILED;
  }

  /** 0-100；未跟踪/未知返回 -1 */
  getProgress(fileId: number): number {
    const entry: DownloadEntry | undefined = this.entries.get(fileId);
    return entry === undefined ? -1 : entry.progress;
  }

  /** ready 态的本地绝对路径（TDLib filesDir 沙盒内），否则空串 */
  getLocalPath(fileId: number): string {
    const entry: DownloadEntry | undefined = this.entries.get(fileId);
    return entry === undefined || entry.state !== DownloadState.READY ? '' : entry.path;
  }

  /** ready 态的 Image 可显示 URI（沙盒路径须转 file:// 应用 URI），否则空串 */
  getReadyUri(fileId: number): string {
    const path: string = this.getLocalPath(fileId);
    return path.length > 0 ? fileUri.getUriFromPath(path) : '';
  }

  addObserver(observer: FileDownloadObserver): void {
    if (!this.observers.includes(observer)) {
      this.observers.push(observer);
    }
  }

  removeObserver(observer: FileDownloadObserver): void {
    const index: number = this.observers.indexOf(observer);
    if (index >= 0) {
      this.observers.splice(index, 1);
    }
  }

  // ---------------- 状态机 ----------------

  /** 新建条目（active 未知进度）；已存在返回 false 且不覆盖现状态 */
  private ensureEntry(fileId: number): boolean {
    if (this.entries.has(fileId)) {
      return false;
    }
    const entry: DownloadEntry = { fileId: fileId, state: DownloadState.ACTIVE, progress: -1, path: '' };
    this.entries.set(fileId, entry);
    return true;
  }

  /** file 对象 → 状态机推进（updateFile 与 downloadFile 响应共用；未跟踪 id 忽略） */
  private applyFile(file: Record<string, Object>): void {
    const fileId: number = this.readNumber(file, TdField.ID);
    if (fileId === 0) {
      return;
    }
    const entry: DownloadEntry | undefined = this.entries.get(fileId);
    if (entry === undefined) {
      return; // 非本仓库发起/未跟踪的文件更新（如 chat 头像）不消费
    }
    const local: Record<string, Object> | null = this.readRecord(file, TdField.LOCAL);
    const completed: boolean = local !== null && local[TdField.IS_DOWNLOADING_COMPLETED] === true;
    const path: string = local === null ? '' : this.readString(local, TdField.PATH);
    if (completed && path.length > 0) {
      const changed: boolean = entry.state !== DownloadState.READY || entry.path !== path;
      entry.state = DownloadState.READY;
      entry.path = path;
      entry.progress = 100;
      if (changed) {
        hilog.info(LOG_DOMAIN, TAG, 'file ready: file=%{public}d', fileId);
        this.notify(fileId);
      }
      return;
    }
    const active: boolean = local !== null && local[TdField.IS_DOWNLOADING_ACTIVE] === true;
    let progress: number = -1;
    if (local !== null) {
      const downloaded: number = this.readNumber(local, TdField.DOWNLOADED_SIZE);
      const expected: number = this.readNumber(file, TdField.EXPECTED_SIZE);
      const exact: number = this.readNumber(file, TdField.SIZE);
      const total: number = expected > 0 ? expected : exact;
      if (downloaded > 0 && total > 0) {
        progress = Math.min(99, Math.floor(downloaded * 100 / total));
      }
    }
    const stateChanged: boolean = active !== (entry.state === DownloadState.ACTIVE);
    const progressChanged: boolean = progress !== entry.progress;
    if (active) {
      entry.state = DownloadState.ACTIVE;
    } else if (entry.state === DownloadState.FAILED) {
      // 保持 failed（等待用户侧重发 downloadFile）
    }
    // 非 active 非 completed 非 failed：TDLib 侧下载被取消/尚未开始，保留现进度等下一次驱动
    entry.progress = progress >= 0 ? progress : entry.progress;
    if (stateChanged || progressChanged) {
      this.notify(fileId);
    }
  }

  private notify(fileId: number): void {
    for (const observer of this.observers) {
      try {
        observer(fileId);
      } catch (err) {
        hilog.error(LOG_DOMAIN, TAG, 'observer error: %{private}s', JSON.stringify(err));
      }
    }
  }

  // ---------------- 工具 ----------------

  private readRecord(source: Record<string, Object>, field: string): Record<string, Object> | null {
    const value: Object | undefined = source[field];
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return null;
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
}
