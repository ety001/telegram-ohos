/**
 * 贴纸仓库（M7-A2）。单例。面板数据源：已安装贴纸包 + 按需全量贴纸 + 最近贴纸。
 *
 * 数据流：InputPanel 贴纸 tab → StickerStore.ensureInstalled()/ensureSet(id)/ensureRecent()
 * →（@extra 等待 + 观察者通知）→ 网格渲染。
 *
 * 缓存策略：installed sets 全量驻存；选中 set 全量贴纸 LRU ≤4 个（贴纸 vector 可达数百，
 * 逐条含 file 对象）；recent stickers 全量驻存。发送走 MessageStore.sendSticker（不入本仓库）。
 *
 * 日志红线：不记贴纸包名/emoji（用户内容特征），仅记数量与 set_id。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TdClient } from '../tdlib/TdClient';
import { TdUpdateRouter, TdRouteHandler } from './TdUpdateRouter';
import { TdReq, TdField, TdType, ErrorType } from './TdConstants';

const TAG: string = 'StickerStore';
const LOG_DOMAIN: number = 0x0012;
const STICKER_TIMEOUT_MS: number = 20000;
/** 全量贴纸 set 缓存上限（LRU） */
const SET_CACHE_LIMIT: number = 4;
// 注意：TDLib JSON 接口 int64 序列化为字符串（tl_json.h JsonString）——set_id 全链 string

export type StickerStoreObserver = () => void;

export class StickerStore {
  private static instance: StickerStore | null = null;

  /** 已安装贴纸包（stickerSetInfo 数组，官方顺序） */
  private installedSets: Array<Record<string, Object>> = new Array<Record<string, Object>>();
  private installedRequested: boolean = false;
  /** set 全量贴纸缓存：set_id（int64 字符串）→ sticker 数组（LRU：recentOrder 队首最新） */
  private setStickers: Map<string, Array<Record<string, Object>>> = new Map();
  private recentOrder: Array<string> = [];
  private setInFlight: Set<string> = new Set();
  /** 最近贴纸（getRecentStickers is_attached=false） */
  private recentStickers: Array<Record<string, Object>> = new Array<Record<string, Object>>();
  private recentRequested: boolean = false;
  private actionSeq: number = 0;
  private observers: Array<StickerStoreObserver> = [];

  private constructor() {
  }

  static getInstance(): StickerStore {
    if (StickerStore.instance === null) {
      StickerStore.instance = new StickerStore();
    }
    return StickerStore.instance;
  }

  // 登录后路由就绪由调用方（ChatPanel 面板开启）触发 ensure*，无需注册 update 路由
  // （贴纸数据全部走 @extra 请求-响应；1.8.63 贴纸更新流 updateInstalledStickerSets 等
  //  未消费——面板每次展开 ensure 幂等刷新，可接受滞后）

  /** 已安装贴纸包（未就绪返回空数组） */
  getInstalled(): Array<Record<string, Object>> {
    return this.installedSets;
  }

  /** set 全量贴纸（未就绪返回空数组；setId 为 int64 字符串） */
  getSetStickers(setId: string): Array<Record<string, Object>> {
    const arr: Array<Record<string, Object>> | undefined = this.setStickers.get(setId);
    return arr === undefined ? new Array<Record<string, Object>>() : arr;
  }

  static readString(record: Record<string, Object>, field: string): string {
    const value: Object | undefined = record[field];
    return typeof value === 'string' ? value : '';
  }

  /** 最近贴纸 */
  getRecent(): Array<Record<string, Object>> {
    return this.recentStickers;
  }

  /** 面板开启入口（幂等）：拉已安装包 + 最近贴纸 */
  ensureBase(): void {
    this.ensureInstalled();
    this.ensureRecent();
  }

  /** 已安装包（在途去重） */
  ensureInstalled(): void {
    if (this.installedRequested) {
      return;
    }
    this.installedRequested = true;
    this.actionSeq += 1;
    const extra: string = `stickerSets_${this.actionSeq}`;
    TdUpdateRouter.getInstance().waitForExtra(extra, STICKER_TIMEOUT_MS)
      .then((update: Record<string, Object>): void => {
        this.installedRequested = false;
        const typeObj: Object | undefined = update[TdField.TYPE];
        if (typeObj === ErrorType.INVALID || typeObj !== TdType.RESULT_STICKER_SETS) {
          return;
        }
        const setsObj: Object | undefined = update[TdField.SETS];
        const sets: Array<Object> = Array.isArray(setsObj) ? setsObj as Array<Object> : [];
        const parsed: Array<Record<string, Object>> = new Array<Record<string, Object>>();
        for (const item of sets) {
          const rec: Record<string, Object> | null = this.asRecord(item);
          if (rec !== null) {
            parsed.push(rec);
          }
        }
        this.installedSets = parsed;
        hilog.info(LOG_DOMAIN, TAG, 'installed sets: %{public}d', parsed.length);
        this.notifyChanged();
      })
      .catch((reason: string): void => {
        this.installedRequested = false;
      });
    const stickerType: Record<string, Object> = { ['@type']: TdType.STICKER_TYPE_REGULAR };
    const request: Record<string, Object> = {
      ['@type']: TdReq.GET_INSTALLED_STICKER_SETS,
      'sticker_type': stickerType
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
  }

  /** 最近贴纸（在途去重） */
  ensureRecent(): void {
    if (this.recentRequested) {
      return;
    }
    this.recentRequested = true;
    this.actionSeq += 1;
    const extra: string = `recentStickers_${this.actionSeq}`;
    TdUpdateRouter.getInstance().waitForExtra(extra, STICKER_TIMEOUT_MS)
      .then((update: Record<string, Object>): void => {
        this.recentRequested = false;
        const typeObj: Object | undefined = update[TdField.TYPE];
        if (typeObj === ErrorType.INVALID || typeObj !== TdType.RESULT_STICKERS) {
          return;
        }
        const listObj: Object | undefined = update[TdField.STICKERS];
        this.recentStickers = this.parseStickers(listObj);
        this.notifyChanged();
      })
      .catch((reason: string): void => {
        this.recentRequested = false;
      });
    const request: Record<string, Object> = {
      ['@type']: TdReq.GET_RECENT_STICKERS,
      'is_attached': false
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
  }

  /** set 全量贴纸按需拉取（LRU 缓存 ≤4；在途去重；setId 为 int64 字符串） */
  ensureSet(setId: string): void {
    if (setId.length === 0 || this.setStickers.has(setId) || this.setInFlight.has(setId)) {
      if (setId.length > 0) {
        this.touchLru(setId);
      }
      return;
    }
    this.setInFlight.add(setId);
    this.actionSeq += 1;
    const extra: string = `stickerSet_${this.actionSeq}`;
    TdUpdateRouter.getInstance().waitForExtra(extra, STICKER_TIMEOUT_MS)
      .then((update: Record<string, Object>): void => {
        this.setInFlight.delete(setId);
        const typeObj: Object | undefined = update[TdField.TYPE];
        if (typeObj === ErrorType.INVALID || typeObj !== TdType.RESULT_STICKER_SET) {
          return;
        }
        const stickersObj: Object | undefined = update[TdField.STICKERS];
        const stickers: Array<Record<string, Object>> = this.parseStickers(stickersObj);
        this.setStickers.set(setId, stickers);
        this.touchLru(setId);
        hilog.info(LOG_DOMAIN, TAG, 'set stickers: %{public}d', stickers.length);
        this.notifyChanged();
      })
      .catch((reason: string): void => {
        this.setInFlight.delete(setId);
      });
    const request: Record<string, Object> = {
      ['@type']: TdReq.GET_STICKER_SET,
      'set_id': setId
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
  }

  /** 登出清空 */
  reset(): void {
    this.installedSets = new Array<Record<string, Object>>();
    this.installedRequested = false;
    this.setStickers.clear();
    this.recentOrder = [];
    this.setInFlight.clear();
    this.recentStickers = new Array<Record<string, Object>>();
    this.recentRequested = false;
    this.notifyChanged();
    hilog.info(LOG_DOMAIN, TAG, 'reset');
  }

  addObserver(observer: StickerStoreObserver): void {
    if (!this.observers.includes(observer)) {
      this.observers.push(observer);
    }
  }

  removeObserver(observer: StickerStoreObserver): void {
    const index: number = this.observers.indexOf(observer);
    if (index >= 0) {
      this.observers.splice(index, 1);
    }
  }

  private parseStickers(listObj: Object | undefined): Array<Record<string, Object>> {
    const list: Array<Object> = Array.isArray(listObj) ? listObj as Array<Object> : [];
    const parsed: Array<Record<string, Object>> = new Array<Record<string, Object>>();
    for (const item of list) {
      const rec: Record<string, Object> | null = this.asRecord(item);
      if (rec !== null) {
        parsed.push(rec);
      }
    }
    return parsed;
  }

  private touchLru(setId: string): void {
    const index: number = this.recentOrder.indexOf(setId);
    if (index >= 0) {
      this.recentOrder.splice(index, 1);
    }
    this.recentOrder.unshift(setId);
    while (this.recentOrder.length > SET_CACHE_LIMIT) {
      const evicted: string | undefined = this.recentOrder.pop();
      if (evicted === undefined) {
        break;
      }
      this.setStickers.delete(evicted);
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

  private asRecord(value: Object | undefined): Record<string, Object> | null {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return null;
  }
}
