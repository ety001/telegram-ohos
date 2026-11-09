/**
 * TDLib 更新流路由器（M2）。
 *
 * 职责：
 * - 按 @type 将 update 分发到注册的 handler（handler 异常隔离：单个 handler 抛错不影响其他 handler 与接收链路）
 * - 按 @extra 支持"请求-响应"式等待（testProxy 等带 extra 的回复）：waitForExtra(extra, timeoutMs)
 * - fallback 通道：未按类型注册的 update 进入 fallback（兼容旧 onUpdate 行为）
 *
 * 分发入口唯一：TdClient.dispatch → TdUpdateRouter.dispatch。
 */
import { TdField } from './TdConstants';

export type TdRouteHandler = (update: Record<string, Object>) => void;

interface ExtraWaiter {
  extra: string;
  resolve: (update: Record<string, Object>) => void;
  reject: (reason: string) => void;
  timerId: number;
}

export class TdUpdateRouter {
  private static instance: TdUpdateRouter | null = null;

  private typeRoutes: Map<string, Array<TdRouteHandler>> = new Map();
  private fallbackHandlers: Array<TdRouteHandler> = [];
  private extraWaiters: Map<string, ExtraWaiter> = new Map();

  private constructor() {
  }

  static getInstance(): TdUpdateRouter {
    if (TdUpdateRouter.instance === null) {
      TdUpdateRouter.instance = new TdUpdateRouter();
    }
    return TdUpdateRouter.instance;
  }

  /** 按更新类型注册 handler（同一类型多 handler 依注册顺序依次调用） */
  register(updateType: string, handler: TdRouteHandler): void {
    let list: Array<TdRouteHandler> | undefined = this.typeRoutes.get(updateType);
    if (list === undefined) {
      list = [];
      this.typeRoutes.set(updateType, list);
    }
    if (!list.includes(handler)) {
      list.push(handler);
    }
  }

  unregister(updateType: string, handler: TdRouteHandler): void {
    const list: Array<TdRouteHandler> | undefined = this.typeRoutes.get(updateType);
    if (list === undefined) {
      return;
    }
    const index: number = list.indexOf(handler);
    if (index >= 0) {
      list.splice(index, 1);
    }
  }

  /** fallback：接收所有未被类型路由消费的 update（含未注册类型），行为兼容 M1 onUpdate */
  registerFallback(handler: TdRouteHandler): void {
    if (!this.fallbackHandlers.includes(handler)) {
      this.fallbackHandlers.push(handler);
    }
  }

  unregisterFallback(handler: TdRouteHandler): void {
    const index: number = this.fallbackHandlers.indexOf(handler);
    if (index >= 0) {
      this.fallbackHandlers.splice(index, 1);
    }
  }

  /** 等待带指定 @extra 的回复（TDLib 会将请求的 @extra 原样附在对应回复上） */
  waitForExtra(extra: string, timeoutMs: number): Promise<Record<string, Object>> {
    const existing: ExtraWaiter | undefined = this.extraWaiters.get(extra);
    if (existing !== undefined) {
      return Promise.reject(`duplicate extra waiter: ${extra}`);
    }
    return new Promise<Record<string, Object>>((resolve: (v: Record<string, Object>) => void,
      reject: (r: string) => void): void => {
      const timerId: number = setTimeout((): void => {
        this.extraWaiters.delete(extra);
        reject(`timeout waiting extra: ${extra}`);
      }, timeoutMs);
      const waiter: ExtraWaiter = { extra: extra, resolve: resolve, reject: reject, timerId: timerId };
      this.extraWaiters.set(extra, waiter);
    });
  }

  /**
   * 主动作废一个 @extra 等待：请求侧 send 抛错等场景须立即 reject 等待者并清 timer，
   * 而非让 waiter 挂到超时才感知（调用方 catch 分支据此做状态救济）。
   * 等待者不存在（已 resolve/已超时）返回 false，幂等。
   */
  rejectExtra(extra: string, reason: string): boolean {
    const waiter: ExtraWaiter | undefined = this.extraWaiters.get(extra);
    if (waiter === undefined) {
      return false;
    }
    this.extraWaiters.delete(extra);
    clearTimeout(waiter.timerId);
    waiter.reject(reason);
    return true;
  }

  /**
   * 唯一分发入口（TdClient.dispatch 调用）。
   * 路由顺序：@extra 等待匹配 → 类型路由 → fallback。
   */
  dispatch(update: Record<string, Object>): void {
    this.dispatchExtra(update);
    const typeObj: Object | undefined = update[TdField.TYPE];
    const type: string = typeof typeObj === 'string' ? typeObj as string : '';
    const list: Array<TdRouteHandler> | undefined = this.typeRoutes.get(type);
    if (list !== undefined) {
      for (const handler of list) {
        this.safeInvoke(handler, update, type);
      }
      return;
    }
    for (const handler of this.fallbackHandlers) {
      this.safeInvoke(handler, update, 'fallback');
    }
  }

  private dispatchExtra(update: Record<string, Object>): void {
    const extraObj: Object | undefined = update[TdField.EXTRA];
    if (typeof extraObj !== 'string') {
      return;
    }
    const waiter: ExtraWaiter | undefined = this.extraWaiters.get(extraObj as string);
    if (waiter === undefined) {
      return;
    }
    this.extraWaiters.delete(waiter.extra);
    clearTimeout(waiter.timerId);
    waiter.resolve(update);
  }

  private safeInvoke(handler: TdRouteHandler, update: Record<string, Object>, scope: string): void {
    try {
      handler(update);
    } catch (err) {
      // handler 异常隔离：单个 handler 失败不影响其他 handler 与接收链路
      console.error(`TdUpdateRouter handler error in ${scope}: ${JSON.stringify(err)}`);
    }
  }
}
