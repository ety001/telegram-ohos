// libtdnapi.so —— ArkTS ↔ TDLib（tdjson）NAPI 桥，原创实现。
//
// 设计约束（M1）：
//   - 只封装 tdjson 新式四函数 API（td_create_client_id/td_send/td_receive/td_execute，
//     均可从任意线程调用、以 client_id 寻址）；不使用已废弃的 td_json_client_* 旧式句柄接口。
//   - 纯 JSON 字符串透传，桥内零协议解析；ArkTS 侧 JSON.parse。
//   - 单 client：M1 只有一个 client，接收线程全局一份（多 client 是后续里程碑的事）。
//
// 正确性四要点（对应 docs/PLAN.md M1 验收，复审必查）：
//   1. td_receive 返回的 const char* 生命周期仅在下次 td_* 调用前有效
//      → 接收线程内立即 std::string 拷贝，再移交 JS 线程；
//   2. TSF call_js_callback 内创建 napi_value 需要句柄作用域
//      → 显式 napi_open_handle_scope / napi_close_handle_scope；
//   3. 线程启动/停止竞态
//      → 状态机（Idle/Running/Stopping）+ 互斥锁：start 幂等（已运行直接拒绝）、
//        stop 阻塞 join 到线程退出后才回 Idle，停机未完成期间不允许再 start；
//   4. TSF 资源不泄漏
//      → 接收线程退出前 napi_release_threadsafe_function（它持有唯一线程引用，
//        不释放则 TSF 与 JS 回调引用永不回收）；入队失败/队列被 abort 残留的
//        payload 在 call_js_callback（env/js_callback 为 null 的路径）或入队失败分支 delete。

#include <napi/native_api.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

// TDLib tdjson C API（新式四函数）。仓库只入库二进制无头文件，按官方
// td_json_client.h 原型自行声明；符号由 libs/arm64-v8a/libtdjson.so 提供。
// ⚠️ td_execute 是全局函数，只收 request 不收 client_id（M3 真机 SEGV 根因修复：
//    误传 client_id 会被当作字符串指针，strlen((char*)1) → SIGSEGV@0x1）。
extern "C" {
int td_create_client_id();
void td_send(int client_id, const char *request);
const char *td_receive(double timeout);
const char *td_execute(const char *request);
}

namespace {

// td_receive 超时（秒）：兼顾空闲 CPU 唤醒频率与 stopReceiving 的停机延迟上界
// （stop 置位后，接收线程最迟在一个超时周期内醒来退出 → join ≤ 1s 返回）。
constexpr double kReceiveTimeoutSec = 1.0;

// ----------------------------- 接收线程状态机（要点 3） -----------------------------
// Idle → (startReceiving) → Running → (stopReceiving) → Stopping → (join 完成) → Idle
// 全部迁移持 g_rx_mutex；接收循环本体不持锁（只看原子停止位），不会与 stop 死锁。
enum class RxState { Idle, Running, Stopping };

std::mutex g_rx_mutex;
RxState g_rx_state = RxState::Idle;
std::thread g_rx_thread;                      // joinable 与否由状态机保证
std::atomic<bool> g_rx_stop{false};
napi_threadsafe_function g_rx_tsf = nullptr;  // Running 期间有效；发布先于线程启动

// ----------------------------- TSF 回调（要点 2 / 要点 4） -----------------------------
// 在 JS 主线程被调起。data 是接收线程 new 出来的 std::string*，所有权在此移交。
void CallJs(napi_env env, napi_value js_callback, void * /*context*/, void *data) {
  // unique_ptr 接管所有权：本函数任何 return 路径都会释放，杜绝队列残留泄漏（要点 4）。
  std::unique_ptr<std::string> update(static_cast<std::string *>(data));
  // TSF 已关闭（abort/环境拆除）时 env/js_callback 可能为 null：只剩释放数据的职责。
  if (env == nullptr || js_callback == nullptr) {
    return;
  }
  napi_handle_scope scope;
  if (napi_open_handle_scope(env, &scope) != napi_ok) {
    return;  // 作用域都开不出来，只能丢弃本条 update
  }
  napi_value argv;
  if (napi_create_string_utf8(env, update->c_str(), update->size(), &argv) == napi_ok) {
    napi_value undefined;
    if (napi_get_undefined(env, &undefined) == napi_ok) {
      napi_call_function(env, js_callback, undefined, 1, &argv, nullptr);
    }
  }
  napi_close_handle_scope(env, scope);
}

// TSF 销毁时回调。刻意不碰 g_rx_tsf：finalizer 与下一次 startReceiving 写入新 TSF
// 可能并发，覆写会悬挂新指针；桥无 context 资源，留空实现即可。
void TsfFinalize(napi_env /*env*/, void * /*finalize_data*/, void * /*context*/) {}

// ----------------------------- 接收循环（要点 1） -----------------------------
void ReceiveLoop(int /*client_id*/) {
  while (!g_rx_stop.load(std::memory_order_acquire)) {
    // 新式 API 无句柄：td_receive 拉取所有 client 的 update，本桥单 client 等价。
    const char *update = td_receive(kReceiveTimeoutSec);
    if (update == nullptr) {
      continue;  // 超时未收到，回到循环头检查停止位
    }
    // 要点 1：返回指针在下次 td_* 调用前失效——立即深拷贝成自有 string，
    // 后续的 napi_create_string_utf8 在 JS 线程基于这份拷贝进行。
    std::string *payload = new std::string(update);
    napi_status st = napi_call_threadsafe_function(g_rx_tsf, payload, napi_tsfn_nonblocking);
    if (st == napi_closing) {
      delete payload;  // TSF 已在拆除（如环境销毁）：投递通道不复存在
      break;           // 跳出循环走收尾 release，避免对着 closing 态空转
    }
    if (st != napi_ok) {
      delete payload;  // 其它入队失败：就地释放，不泄漏
    }
    // 队列为无界（max_queue_size=0），非阻塞调用不会 napi_queue_full，无需重试逻辑。
  }
  // 要点 4：本线程持有 TSF 的唯一线程引用（initial_thread_count=1），
  // 退出前必须 release，否则 TSF、其 JS 回调引用与排队数据永不回收。
  // 用 graceful 模式：已排队 update 仍会送到 JS 侧后再销毁。
  // （TSF 已被 abort 时此处会返回非 ok，忽略即可——引用计数已由 abort 侧清算。）
  napi_release_threadsafe_function(g_rx_tsf, napi_tsfn_release);
}

// ----------------------------- 参数读取小工具 -----------------------------
bool GetClientIdArg(napi_env env, const napi_value *argv, int *out) {
  return napi_get_value_int32(env, argv[0], out) == napi_ok;
}

std::string GetStringArg(napi_env env, napi_value value) {
  size_t len = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
    return std::string();
  }
  std::string out(len, '\0');
  size_t copied = 0;
  if (napi_get_value_string_utf8(env, value, &out[0], len + 1, &copied) != napi_ok) {
    return std::string();
  }
  out.resize(copied);
  return out;
}

napi_value MakeBool(napi_env env, bool value) {
  napi_value result = nullptr;
  napi_get_boolean(env, value, &result);
  return result;
}

napi_value MakeUndefined(napi_env env) {
  napi_value result = nullptr;
  napi_get_undefined(env, &result);
  return result;
}

void ThrowError(napi_env env, const char *message) {
  napi_throw_error(env, "tdnapi_error", message);
}

}  // namespace

// 导出符号刻意带 tdnapi_ 前缀（extern "C" + 默认可见性）：供交叉编译脚本
// nm -D 门禁校验；裸名 send 会与 libc send(2) 发生符号抢占，必须避开。
// JS 侧名字（属性描述符）仍是 createClient/send/executeSync/startReceiving/stopReceiving。

// JS: createClient(): number —— td_create_client_id()
extern "C" napi_value tdnapi_createClient(napi_env env, napi_callback_info /*info*/) {
  napi_value result = nullptr;
  if (napi_create_int32(env, td_create_client_id(), &result) != napi_ok) {
    ThrowError(env, "createClient: napi_create_int32 失败");
    return nullptr;
  }
  return result;
}

// JS: send(clientId: number, request: string): void —— td_send（异步，回复走接收线程）
extern "C" napi_value tdnapi_send(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc != 2) {
    ThrowError(env, "send: 需要 (clientId: number, request: string)");
    return nullptr;
  }
  int client_id = 0;
  if (!GetClientIdArg(env, argv, &client_id)) {
    ThrowError(env, "send: clientId 不是 number");
    return nullptr;
  }
  std::string request = GetStringArg(env, argv[1]);
  if (request.empty()) {
    ThrowError(env, "send: request 不是非空 string");
    return nullptr;
  }
  td_send(client_id, request.c_str());  // TDLib 侧自行拷贝，本串出栈即安全
  return MakeUndefined(env);
}

// JS: executeSync(clientId: number, request: string): string —— td_execute（同步）
// 适用：登录前的配置类请求（getVersion/setOption 等），不依赖接收线程。
// 注意：td_execute 是全局函数、与 client 无关——clientId 参数保留仅为 JS 侧签名兼容，实现忽略。
extern "C" napi_value tdnapi_executeSync(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc != 2) {
    ThrowError(env, "executeSync: 需要 (clientId: number, request: string)");
    return nullptr;
  }
  int client_id = 0;
  if (!GetClientIdArg(env, argv, &client_id)) {
    ThrowError(env, "executeSync: clientId 不是 number");
    return nullptr;
  }
  std::string request = GetStringArg(env, argv[1]);
  if (request.empty()) {
    ThrowError(env, "executeSync: request 不是非空 string");
    return nullptr;
  }
  const char *result = td_execute(request.c_str());
  // 要点 1 同源：返回指针在下次 td_* 调用前失效，立即复制进 napi string
  napi_value out = nullptr;
  if (result != nullptr && napi_create_string_utf8(env, result, NAPI_AUTO_LENGTH, &out) != napi_ok) {
    ThrowError(env, "executeSync: napi_create_string_utf8 失败");
    return nullptr;
  }
  return out;
}

// JS: startReceiving(clientId: number, callback: (update: string) => void): boolean
// 返回 false = 参数非法或已在接收（幂等，见要点 3）；true = 接收线程已启动。
extern "C" napi_value tdnapi_startReceiving(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc != 2) {
    ThrowError(env, "startReceiving: 需要 (clientId: number, callback: function)");
    return MakeBool(env, false);
  }
  int client_id = 0;
  napi_valuetype callback_type = napi_undefined;
  if (!GetClientIdArg(env, argv, &client_id)
      || napi_typeof(env, argv[1], &callback_type) != napi_ok
      || callback_type != napi_function) {
    ThrowError(env, "startReceiving: clientId 不是 number 或 callback 不是 function");
    return MakeBool(env, false);
  }

  // 要点 3：状态迁移整体持锁；非 Idle（Running/Stopping）一律拒绝重复启动。
  // Stopping 也拒绝：停机 join 未完成前不允许 start（旧线程尚未释放 TSF）。
  {
    std::lock_guard<std::mutex> lock(g_rx_mutex);
    if (g_rx_state != RxState::Idle) {
      return MakeBool(env, false);
    }
    g_rx_state = RxState::Running;
  }

  napi_value resource_name = nullptr;
  napi_create_string_utf8(env, "tdnapiReceive", NAPI_AUTO_LENGTH, &resource_name);
  napi_threadsafe_function tsf = nullptr;
  // 无界队列 + initial_thread_count=1（接收线程持有）；call_js_callback 留空由通用 CallJs 兜底
  napi_status st = napi_create_threadsafe_function(
      env, argv[1], nullptr, resource_name, 0, 1, nullptr, TsfFinalize, nullptr, CallJs, &tsf);
  if (st != napi_ok) {
    std::lock_guard<std::mutex> lock(g_rx_mutex);
    g_rx_state = RxState::Idle;
    ThrowError(env, "startReceiving: napi_create_threadsafe_function 失败");
    return nullptr;
  }

  g_rx_tsf = tsf;  // 发布先于线程创建（happens-before），接收线程可安全读取
  g_rx_stop.store(false, std::memory_order_release);
  try {
    g_rx_thread = std::thread(ReceiveLoop, client_id);
  } catch (...) {
    // 线程没起来：TSF 线程引用由本次 abort 释放，状态回 Idle
    napi_release_threadsafe_function(g_rx_tsf, napi_tsfn_abort);
    g_rx_tsf = nullptr;
    std::lock_guard<std::mutex> lock(g_rx_mutex);
    g_rx_state = RxState::Idle;
    ThrowError(env, "startReceiving: 接收线程创建失败");
    return nullptr;
  }
  return MakeBool(env, true);
}

// JS: stopReceiving(): boolean —— 干净停机：置停止位 → join 接收线程 → 状态回 Idle。
// 线程退出前自行 release TSF（要点 4）。未启动时停止视为成功（幂等）。
// 注意：join 延迟上界 = kReceiveTimeoutSec（td_receive 醒来周期），会阻塞 JS 线程 ≤1s。
extern "C" napi_value tdnapi_stopReceiving(napi_env env, napi_callback_info /*info*/) {
  std::unique_lock<std::mutex> lock(g_rx_mutex);
  if (g_rx_state != RxState::Running) {
    return MakeBool(env, true);  // 幂等：Idle/Stopping 均无需处理
  }
  g_rx_state = RxState::Stopping;
  g_rx_stop.store(true, std::memory_order_release);
  lock.unlock();

  g_rx_thread.join();  // 接收循环内完成 TSF release；循环不持 g_rx_mutex，无死锁

  lock.lock();
  g_rx_state = RxState::Idle;  // join 完成才放行下一次 startReceiving（要点 3）
  return MakeBool(env, true);
}

// ----------------------------- 模块注册 -----------------------------
static napi_value Init(napi_env env, napi_value exports) {
  const napi_property_descriptor desc[] = {
      {"createClient", nullptr, tdnapi_createClient, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"send", nullptr, tdnapi_send, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"executeSync", nullptr, tdnapi_executeSync, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"startReceiving", nullptr, tdnapi_startReceiving, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"stopReceiving", nullptr, tdnapi_stopReceiving, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  if (napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc) != napi_ok) {
    return nullptr;
  }
  return exports;
}

NAPI_MODULE(tdnapi, Init)
