/**
 * libtdnapi.so —— ArkTS ↔ TDLib NAPI 桥的类型声明（纯 JSON 字符串透传，无协议解析）。
 * 实现见 entry/src/main/cpp/tdnapi_bridge.cpp。
 */

/** 创建 TDLib client，返回 client_id（td_create_client_id） */
export const createClient: () => number;

/** 异步发送请求（td_send）；回复经 startReceiving 的回调送达 */
export const send: (clientId: number, request: string) => void;

/** 同步执行请求（td_execute）；登录前的配置类请求（如 getVersion）用 */
export const executeSync: (clientId: number, request: string) => string;

/**
 * 启动后台接收线程：td_receive 循环 + threadsafe function 回推。
 * 返回 false = 参数非法或已在接收（幂等）；true = 已启动
 */
export const startReceiving: (clientId: number, callback: (update: string) => void) => boolean;

/** 停止接收线程（join + TSF 释放）；未启动时也返回 true（幂等） */
export const stopReceiving: () => boolean;
