# 调研报告（2026-04）

> 结论先行：**TDLib + ArkUI 自研鸿蒙 PC 客户端完全可行**。本文记录调研证据，供实施期回查。

## 一、TDLib 移植 HarmonyOS (aarch64-linux-ohos) 可行性

### 1. 官方态度与社区先例

TDLib 官方平台列表无 HarmonyOS，但声明 "should also work on other *nix systems with or without minimal effort"。社区已有多个成功移植：

| 项目 | 说明 | 状态 |
|---|---|---|
| [eclipse-oniro4openharmony/app-Tele4Watch](https://github.com/eclipse-oniro4openharmony/app-Tele4Watch) | Eclipse Oniro 官方生态，TDLib 1.8.63 + N-API bridge，含完整构建文档 | Apache-2.0，真机（Watch 5）跑通 |
| [kharkilirov1/Telegram-HarmonyOS](https://github.com/kharkilirov1/Telegram-HarmonyOS) | ArkTS/ArkUI + TDLib + `tdlib_napi.cpp` 桥，API 22+ | 活跃（2026-11 仍在推送） |
| [jhuix-ohos/ohos-native-build](https://github.com/jhuix-ohos/ohos-native-build) | 内置 tdnapi：TDLib NAPI 封装 + ArkTS 类型声明 + hvigor 共享包 | 最完整的编译+封装方案 |
| [ErBWs/tdlib-ohos-build](https://github.com/ErBWs/tdlib-ohos-build) | 纯 Shell 构建脚本 + 平台补丁 | 轻量参考 |
| [YuanChu-Tec/tdlib-harmony-builder](https://github.com/YuanChu-Tec/tdlib-harmony-builder) | 自动化构建器，支持 API 9/12/23 | 2026-06 仍在更新 |
| [tg-oh](https://gitcode.com/qdzwwqd/tg-oh) | 中文鸿蒙原生 TG 客户端（ArkTS + TDLib） | 参考 |

### 2. 必需补丁（仅 2 处，社区有现成 patch）

1. `tdutils/td/utils/port/platform.h`：新增 `#elif defined(__OHOS__) → TD_OHOS`，config.h 把 TD_OHOS 并入 epoll/eventfd 组（见 [ErBWs 补丁](https://github.com/ErBWs/tdlib-ohos-build/blob/main/patches/td-add-ohos-platform.patch)）。
2. `tdutils/td/utils/port/detail/ThreadPthread.h`：pthread affinity 条件加 `&& !defined(__OHOS__)`（OHOS musl 缺该 API，见 [Tele4Watch 构建脚本](https://github.com/eclipse-oniro4openharmony/app-Tele4Watch/blob/main/scripts/build_tdlib_ohos.ps1)）。

### 3. 构建要点

- 依赖：C++17 编译器、OpenSSL 1.1.1/3.x（官方推荐 3.x）、zlib、gperf（host 构建期）、CMake ≥3.10。PHP 仅低内存拆分编译需要。
- **两阶段**：host 先 `prepare_cross_compiling`（生成 TL 源码）→ OHOS NDK `ohos.toolchain.cmake`（`-DOHOS_ARCH=arm64-v8a`）交叉编 `tdjson` 目标。
- 产物：libtdjson.so ≈ 19MB（Android arm64 实测参考值）；启用 LTO 可显著减小。
- 编译期内存：低内存模式 clang 约 0.8GB；运行期开启全部数据库（message/chat info/file database）可显著降 RAM。

### 4. 接口选型：td_json_client

新式 4 函数 C API：`td_create_client_id / td_send / td_receive / td_execute`。JSON 接口跨 ABI 稳定（语义化版本），ArkTS 侧直接 JSON.parse。官方注明旧式 `td_json_client_create` 将在 2.0.0 移除，勿用。

现成 NAPI 封装可参考：
- [tdnapi Index.d.ts（ArkTS 类型声明）](https://github.com/jhuix-ohos/ohos-native-build/blob/main/scripts/tdnapi/src/src/main/cpp/types/libtdnapi/Index.d.ts)
- [Telegram-HarmonyOS tdlib_napi.cpp](https://github.com/kharkilirov1/Telegram-HarmonyOS/blob/main/entry/src/main/cpp/tdlib_napi.cpp)（threadsafe function + 50 条/批合并回调，教科书式）

### 5. 协议

Boost Software License 1.0：允许任意使用/修改/闭源链接，仅要求保留版权声明。自用零限制。

## 二、鸿蒙平台能力与限制（HarmonyOS 7 PC）

### 版本对应

HarmonyOS 5.0=API12 → 6.0=API20 → 6.1=API23 → **7.0=API26**（2026-08 正式发布）。鸿蒙 PC 已支持 26.0.0。参考：[API 对应表](https://secnotes.cn/hoapi/)、[HarmonyOS 7 PC 发布](https://www.ithome.com/0/999/399.htm)。

### ✅ 可用

- **网络**：`@ohos.net.socket` TCP/UDP/TLS/WebSocket 对三方开放，仅需 `ohos.permission.INTERNET`（normal 级）。[API 文档](https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-socket)
- **PC 保活红利（本项目关键）**：PC-only 应用（deviceTypes 不含 phone）最小化不触发 UIAbility 后台化，长连接自然维持；TASK_KEEPING 长时任务在 PC/2in1 免 ACL。[窗口生命周期文档](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/windowmanager/window-overview.md)、[长时任务文档](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/task-management/continuous-task.md)
- **本地通知**：`notificationManager.publish()` 免权限，需用户授权一次通知开关；PC 端无"退后台关闭通道"限制。[文档](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-notification-kit/js-apis-notificationManager.md)
- **ArkUI**：LazyForEach 长列表、Image、AVPlayer、DocumentViewPicker（免权限）、RichEditor、应用内 emoji 面板均可三方使用。
- **侧载**：开发者模式 + DevEco 自动签名（免费开发者账号）+ `hdc app install`。参考教程：[鸿蒙 PC 侧载 HAP](https://xoyozo.net/Blog/Details/how-to-sideload-hap-packages-on-harmonyos-pc)

### ⚠️ 受限

- **Push Kit**：需 AGC 开通 + Profile 含推送能力；未上架应用默认按营销类频控 **每设备每日 2~5 条** → 本项目弃用，走常驻长连接 + 本地通知。
- **剪贴板读取**：ACL 受限权限 → 用 PasteButton 安全控件（用户点按免权限）。
- **调试证书**：有效期约 6 个月（开发者账号），到期需重签重装 → 脚本化重签 + 到期提醒。
- **长时任务**：需 KEEP_BACKGROUND_RUNNING + 常驻通知 + 类型一致性校验；TASK_KEEPING 仅 PC/2in1 免 ACL。

### ❌ 不可行 / 无官方路径

- 不上架拿到正式级系统离线推送
- Telegram 官方鸿蒙客户端（不存在，无官方计划）
- 手机端"无限保活"（一致性校验 + 冻结机制封死）——本项目不涉及

## 三、已评估项目：TelegramHarmony（2026-04 评估后弃用参考）

> 结论：**不作为参考，UI 完全自研。** 理由：无 LICENSE、协议层自曝 CRITICAL 缺陷、项目已停滞。本节保留调研证据备查。

### 基本盘（2026-04 实测）

| 维度 | 事实 | 来源 |
|---|---|---|
| 技术路线 | 纯 ArkTS 手写 MTProto 2.0（Layer 214），**无 TDLib、零第三方依赖**、无原生代码 | README + 代码结构 |
| 规模 | 协议层 ≈13K 行（AES-IGE/AuthKey/TL 序列化/传输）+ UI 层 ≈25K 行 | wc -l 实测 |
| API 版本 | compatible 5.0.0(12) / target 6.0.2(22) | build-profile.json5 |
| 完成度 | 自评 72%，但**水分明显**：文本/图片/语音发送均标注 "✅ Mock" | docs/FEATURE_PROGRESS.md |
| 已知缺陷 | 自曝 CRITICAL：accessHash 回退 0 致发送失败；无请求重试；媒体发送是占位符（返回假消息，未实际上传） | docs/MESSAGE_FLOW_ISSUES.md |
| 许可证 | **GitHub license: null**（无 LICENSE 文件）→ 默认保留所有权利，**不可复制代码** | GitHub API |
| 活跃度 | 单次 Initial commit（2026-01-23），此后零推送，疑似停滞 | GitHub API pushed_at |
| 星标 | 47 stars / 8 forks | GitHub API |

### 评估后的决策（2026-04）

1. **协议层：维持 TDLib 路线。** 其踩的坑（access_hash 管理、指数退避重试、媒体上传、DC 切换）恰好全是 TDLib 开箱即解决的问题；自写 MTProto 的长期维护成本（Telegram layer 升级要自己跟）远超收益。
2. **UI：不参考其设计，完全自研。** 自研桌面三栏信息架构见 PLAN.md §4（导航条/会话列表/聊天区 + PC 特性）。
3. 本地参考库 clone 已清理，不再保留。

## 四、同类项目速览（供 UI/交互参考）

- [Gramony](https://github.com/Gramony/Gramony)、[Homogram](https://github.com/HomoArk/Homogram)（Rust grammers 路线）、[Web-Telegram-for-OpenHarmony](https://github.com/XHXYT/Web-Telegram-for-OpenHarmony)（Web 封装路线，非本项目路线）
