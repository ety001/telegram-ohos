/**
 * TDLib 单例客户端（M2 增强）。
 *
 * - 纯 JSON 透传：object → JSON.stringify → 桥（libtdnapi.so），回复/更新在 ArkTS 侧 JSON.parse
 * - 更新分发统一走 TdUpdateRouter（类型路由 + @extra 等待 + fallback）
 * - onUpdate/onUpdateFallback 为兼容入口（fallback 通道），AuthService 等用 Router 的类型路由
 * - dispose 负责发送 close 并停机（EntryAbility.onDestroy 调用）
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { createClient, executeSync, send, startReceiving, stopReceiving } from 'libtdnapi.so';
import { TdUpdateRouter, TdRouteHandler } from '../core/TdUpdateRouter';
import { TdReq, TdUpdate, TdField } from '../core/TdConstants';

const TAG: string = 'TdClient';
const LOG_DOMAIN: number = 0x0011;

/** TDLib 更新回调：参数为已 JSON.parse 的更新对象，按 @type 字段区分与分发 */
export type TdUpdateHandler = TdRouteHandler;

export class TdClient {
  private static instance: TdClient | null = null;

  private clientId: number = 0;
  private receiving: boolean = false;
  private disposed: boolean = false;

  private constructor() {
    this.clientId = createClient();
  }

  /** 全局单例入口 */
  static getInstance(): TdClient {
    if (TdClient.instance === null) {
      TdClient.instance = new TdClient();
    }
    return TdClient.instance;
  }

  /** 桥侧 client_id */
  getClientId(): number {
    return this.clientId;
  }

  /** 异步请求（td_send）：回复经更新流送达；可带 @extra 配合 Router.waitForExtra */
  send(request: Record<string, Object>): void {
    if (this.disposed) {
      return;
    }
    send(this.clientId, JSON.stringify(request));
  }

  /**
   * 同步请求（td_execute）：仅限登录前的配置类纯内存请求（getVersion 等），
   * 勿用于可触发网络/IO 的请求（那类走 send + 更新流）。
   * 桥返回空串时抛带语义的异常（NAPI 复审遗留修复）。
   */
  execute(request: Record<string, Object>): Record<string, Object> {
    const response: string = executeSync(this.clientId, JSON.stringify(request));
    if (response.length === 0) {
      throw new Error(`td_execute empty response for ${request[TdField.TYPE]}`);
    }
    return JSON.parse(response) as Record<string, Object>;
  }

  /** 显式启动接收线程（应用初始化时调用；幂等） */
  start(): void {
    this.ensureReceiving();
  }

  /**
   * fallback 通道：接收所有未被类型路由消费的 update（M1 兼容入口）。
   * 首次注册时启动接收线程；重复注册由 Router 去重。
   */
  onUpdate(handler: TdUpdateHandler): void {
    this.ensureReceiving();
    TdUpdateRouter.getInstance().registerFallback(handler);
  }

  offUpdate(handler: TdUpdateHandler): void {
    TdUpdateRouter.getInstance().unregisterFallback(handler);
  }

  /** 应用退出：发送 close（TDLib 收尾）→ 停接收线程（EntryAbility.onDestroy 调用） */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    const closeReq: Record<string, Object> = { ['@type']: TdReq.CLOSE };
    try {
      send(this.clientId, JSON.stringify(closeReq));
    } catch (err) {
      // 进程退出场景：close 发送失败无需处理
    }
    if (!this.receiving) {
      return;
    }
    // TDLib 关闭契约：close 后须等到 updateAuthorizationStateClosed（DB 刷盘/关闭完成的标志）
    // 再停接收线程；上限 2s 兜底（M2 复审 MEDIUM 修复：原实现立即停线程违反一致性契约）。
    const finishStop: () => void = (): void => {
      TdUpdateRouter.getInstance().unregister(TdUpdate.AUTHORIZATION_STATE, closedWatcher);
      if (this.receiving) {
        stopReceiving();
        this.receiving = false;
        hilog.info(LOG_DOMAIN, TAG, '接收线程已停止（dispose，等 Closed 完成/超时）');
      }
    };
    const closedWatcher: TdRouteHandler = (update: Record<string, Object>): void => {
      const typeObj: Object | undefined = update['authorization_state'];
      if (typeof typeObj !== 'object' || typeObj === null) {
        return;
      }
      const state = typeObj as Record<string, Object>;
      if (state['@type'] === 'authorizationStateClosed') {
        clearTimeout(guardTimer);
        finishStop();
      }
    };
    const guardTimer: number = setTimeout(finishStop, 2000);
    TdUpdateRouter.getInstance().register(TdUpdate.AUTHORIZATION_STATE, closedWatcher);
  }

  /** 首次注册时启动接收线程；startReceiving 桥侧幂等 */
  private ensureReceiving(): void {
    if (this.receiving || this.disposed) {
      return;
    }
    this.receiving = startReceiving(this.clientId, (update: string): void => {
      this.dispatch(update);
    });
    if (this.receiving) {
      hilog.info(LOG_DOMAIN, TAG, '接收线程已启动, clientId=%{public}d', this.clientId);
    }
  }

  /** 桥回调入口：解析失败只告警不中断；分发唯一出口是 TdUpdateRouter */
  private dispatch(update: string): void {
    let parsed: Record<string, Object>;
    try {
      parsed = JSON.parse(update) as Record<string, Object>;
    } catch (error) {
      // 日志隐私：更新原文走 %{private}s（登录后可能含聊天内容，禁止 %{public}s）
      hilog.warn(LOG_DOMAIN, TAG, '更新解析失败: %{private}s', update.substring(0, 200));
      return;
    }
    this.ensureReceiving();
    TdUpdateRouter.getInstance().dispatch(parsed);
  }
}
