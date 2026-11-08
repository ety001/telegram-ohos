import { hilog } from '@kit.PerformanceAnalysisKit';
import { createClient, executeSync, send, startReceiving, stopReceiving } from 'libtdnapi.so';

const TAG: string = 'TdClient';
const LOG_DOMAIN: number = 0x0011;

/** TDLib 更新回调：参数为已 JSON.parse 的更新对象，按 @type 字段区分与分发 */
export type TdUpdateHandler = (update: Record<string, Object>) => void;

/**
 * TDLib 单例客户端（M1）。
 *
 * - client 生命周期单例管理：首次 getInstance 时 createClient
 * - send/execute 纯 JSON 透传：object → JSON.stringify → 桥，回复/更新在 ArkTS 侧
 *   JSON.parse（桥不做协议解析）
 * - onUpdate 注册首个回调时启动桥侧接收线程；后续注册只追加分发列表
 */
export class TdClient {
  private static instance: TdClient | null = null;

  private clientId: number = 0;
  private receiving: boolean = false;
  private handlers: Array<TdUpdateHandler> = [];

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

  /** 桥侧 client_id（透传给 send/execute 时由本类内部填写） */
  getClientId(): number {
    return this.clientId;
  }

  /** 异步请求（td_send）：回复经 onUpdate 的更新流送达 */
  send(request: Record<string, Object>): void {
    send(this.clientId, JSON.stringify(request));
  }

  /**
   * 同步请求（td_execute）：登录前的配置类请求（getVersion 等）用。
   * 返回值已 JSON.parse；桥返回空串（td_execute 罕见 null）会在此抛异常，由调用方捕获。
   */
  execute(request: Record<string, Object>): Record<string, Object> {
    const response: string = executeSync(this.clientId, JSON.stringify(request));
    return JSON.parse(response) as Record<string, Object>;
  }

  /**
   * 注册更新回调；首次注册时启动接收线程。
   * startReceiving 幂等（桥侧已运行返回 false），此处用 receiving 位保证只启动一次。
   */
  onUpdate(handler: TdUpdateHandler): void {
    this.handlers.push(handler);
    if (this.receiving) {
      return;
    }
    this.receiving = startReceiving(this.clientId, (update: string): void => {
      this.dispatch(update);
    });
    if (this.receiving) {
      hilog.info(LOG_DOMAIN, TAG, '接收线程已启动, clientId=%{public}d', this.clientId);
    }
  }

  /** 停止接收线程并清空回调（页面卸载/重建时调用；未启动时为幂等空操作） */
  dispose(): void {
    if (this.receiving) {
      stopReceiving();
      this.receiving = false;
      hilog.info(LOG_DOMAIN, TAG, '接收线程已停止');
    }
    this.handlers = [];
  }

  /** 桥回调入口：解析失败只告警不中断（保护 TSF 回调链路） */
  private dispatch(update: string): void {
    let parsed: Record<string, Object>;
    try {
      parsed = JSON.parse(update) as Record<string, Object>;
    } catch (error) {
      hilog.warn(LOG_DOMAIN, TAG, '更新解析失败: %{public}s', update.substring(0, 200));
      return;
    }
    for (const handler of this.handlers) {
      handler(parsed);
    }
  }
}
