---
name: telegram-ohos 鸿蒙原生 Telegram 客户端开发计划
overview: 基于 TDLib + ArkUI 的鸿蒙 PC 原生 Telegram 客户端（自用不上架），从工程骨架到 MVP 全流程的实施计划。
todos:
  - id: m0-scaffold
    content: M0 DevEco 工程骨架（API 26、权限声明）+ 三栏占位页（PR #1 已 merge；真机侧载待工具链就绪后冒烟）
    status: completed
  - id: m1-tdlib-build
    content: M1 交叉编译 TDLib → libtdjson.so v1.8.63（三轮复审通过：路径泄漏 552→0、SONAME 修正、strip 34MB；PR #2 已 merge）
    status: completed
  - id: ci-build-workflow
    content: GitHub Actions 编译流水线（PR #3 已 merge；首跑实测通过 21m16s，产物 bot 自动回库，校验全绿）
    status: completed
  - id: m1-napi-bridge
    content: M1 NAPI 桥（四函数 API + TSF 接收线程 + 连通验证 UI；NDK 实编+hvigor 整包双验证；PR #4 已 merge；真机 td_execute 待真机）
    status: completed
  - id: m2-auth
    content: M2 登录链路（状态机/凭证/代理/流程页 + 分发框架；PR #5 已 merge；真机端到端登录待真机+代理实操）
    status: completed
  - id: m2-chat-list
    content: M2 会话列表 + 响应式地基（PR #6 已 merge；断点 sm/md/lg、三形态 deviceTypes、ChatPage 占位；真实数据一致性/帧率/断点切换待真机）
    status: completed
  - id: m3-messaging
    content: M3 消息收发（乐观 UI 三态 + ChatPanel 组件化 + 已读回执；PR #7 已 merge；真机端到端收发待真机）
    status: completed
  - id: m3-media
    content: M3 媒体与文件（图片/视频/文件渲染下载 + AVPlayer 播放 + 用户目录保存；PR #8 已 merge；真机媒体 7 项验证挂账）
    status: completed
  - id: m3-notifications
    content: M3 本地通知（触发规则矩阵 + wantAgent 点击路由；PR #9 已 merge；真机 5 项验证挂账）
    status: completed
  - id: m4-keepalive
    content: M4 双端后台与保活（TASK_KEEPING 长时任务 + 生命周期接线；PR #10 已 merge；真机最小化 >24h 实测与手机端 TASK_KEEPING 行为待真机）
    status: completed
  - id: m5-polish
    content: M5 精选打磨（富文本 entities 渲染 + 会话操作菜单置顶/静音/删除 + 遗留 LOW 修复 + 版本 0.2.0；PR #11 已 merge；延后登记：LazyForEach 迁移/emoji 自绘面板/主题切换/URL 指纹窄边界/首屏超时重试——均无真机性能数据前不猜优化）
    status: completed
---

# telegram-ohos 鸿蒙原生 Telegram 客户端开发计划

## 1. 目标与边界

- **目标**：鸿蒙 PC（HarmonyOS 7，API 26）原生 Telegram 客户端，日常可用的单机自用 IM。
- **边界**：仅自用，不上架应用市场；仅 PC/2in1 形态；不做语音/视频通话；不含 Push Kit。
- **交付物**：可侧载的签名 HAP + 本仓库。

## 2. 已拍板决策（2026-04 会话确认）

| 决策点 | 选择 | 理由 |
|---|---|---|
| 技术路线 | **TDLib (tdjson) + ArkUI 自研** | 5 个社区移植先例、补丁极小、Boost 协议零限制；纯 ArkTS 实现 MTProto 工作量爆炸 |
| 目标设备 | **PC + 手机 + 平板，UI 全自适应**（2026-04 变更，原仅 PC） | 全设备覆盖；代价：deviceTypes 含 phone 后，PC 端最小化也不再豁免后台管控，双端保活均依赖长时任务 |
| MVP 范围 | **精简版** | 文本收发 + 图片/视频/文件 + 本地通知；贴纸/语音/通话留二期 |
| TDLib 二进制 | **两步走** | 先社区脚本快速起步，后接入自有流水线固化（openssl/zlib 仓库内已有） |
| UI 设计 | **完全自研**（评估 TelegramHarmony 后弃用其参考价值） | 其无 LICENSE 且协议层有 CRITICAL 缺陷；PC-only 桌面交互按本项目需求全新设计 |
| 编译迁移 | **双轨**：GitHub Actions 为主 + 本机兜底（调研结论 docs/CI-RESEARCH.md） | 本机 aarch64 全量 65 分钟风扇狂转；私有库 runner 2C/8G 全量约 30-50 分钟，SDK 安装 Action / 缓存 / 产物回库范式均有现成生态 |

## 3. 调研结论依据（详见 docs/RESEARCH.md）

1. **TDLib 可行性：高**。Eclipse Oniro 官方生态 Tele4Watch（TDLib 1.8.63 真机跑通）、Telegram-HarmonyOS（活跃）、tdnapi（NAPI 封装+类型声明）均可复用；必需补丁仅 2 处（platform.h 加 TD_OHOS 宏、ThreadPthread.h 排除 pthread affinity）。libtdjson.so ≈ 19MB。
2. **平台能力**：`@ohos.net.socket` TCP/TLS 仅需 INTERNET 权限；PC-only 应用最小化不触发 UIAbility 后台化；TASK_KEEPING 在 PC/2in1 免 ACL；本地通知需用户授权一次。
3. **平台限制**：Push Kit 对不上架应用有每日 2~5 条频控 → 弃用，走"常驻长连接 + 本地通知"；剪贴板读取用 PasteButton 安全控件；调试证书约 6 个月有效期需重签。
4. **版本对应**：HarmonyOS 7.0 = API 26；DevEco 需配 API 26 SDK。用户自有真机（PC/手机/平板）确认均为 HarmonyOS 7（API 26），`compatibleSdkVersion: "26.0.0"` 全设备可装，无需降档。

## 4. 系统架构

```
┌─ ArkUI (ArkTS, API 26) ──────────────┐
│ 会话列表 / 聊天页 / 设置（含代理页） │
│ 状态管理 V2（@ObservedV2/@Trace）    │
└──────────┬───────────────────────────┘
           │ JSON 字符串（NAPI，threadsafe function 回调）
┌──────────▼───────────────────────────┐
│ libtdnapi.so（自研 NAPI 桥，C++）    │
│ 参考：tdnapi + tdlib_napi.cpp        │
└──────────┬───────────────────────────┘
           │ td_json_client C API（4 函数）
┌──────────▼───────────────────────────┐
│ libtdjson.so（TDLib，交叉编译）      │
│ MTProto ↔ Telegram DC（可走代理）    │
│ 本地数据库由 TDLib 自管（全开降内存）│
└──────────────────────────────────────┘
```

关键原则：

- **UI 不实现任何协议逻辑**，全部经 TDLib JSON API（td_send/td_receive/td_execute）。
- TDLib 数据库/文件目录放应用沙盒（`context.filesDir` / `context.cacheDir`）。
- 更新流（`update*`）单线程接收 → ArkTS 侧按 class 分发到状态仓库。

### UI 信息架构（自研，桌面三栏）

```
┌──┬────────────┬───────────────────────────────┐
│导│ 会话列表    │ 聊天区                         │
│航│ ┌────────┐ │  ┌─────────────────────────┐  │
│条│ │搜索框   │ │  │ 消息流（按天分组）        │  │
│  │ ├────────┤ │  │  MessageBubble / 媒体    │  │
│头│ │置顶会话 │ │  ├─────────────────────────┤  │
│像│ ├────────┤ │  │ ReplyPreview（回复引用）  │  │
│/ │ │普通会话 │ │  ├─────────────────────────┤  │
│未│ │未读角标  │ │  │ 输入区：emoji/附件/发送   │  │
│读│ └────────┘ │  └─────────────────────────┘  │
│/ │            │                               │
│设│            │                               │
│置│            │                               │
└──┴────────────┴───────────────────────────────┘
```

- **导航条**（窄列）：头像、未读汇总、设置入口。
- **会话列表**：搜索框、置顶/免打扰标记、未读角标、最后消息预览。
- **聊天区**：消息流按天分组；ReplyPreview 回复引用；输入区含 emoji 面板、附件、发送按钮。
- **PC 特性**：窗口尺寸/位置记忆、Ctrl+F 全局搜索、Esc 收起子面板、右键上下文菜单。

### UI 响应式（三形态自适应）

- **断点**（ArkUI windowWidth 断点）：sm(<600vp 手机) / md(600~840vp 平板竖屏、PC 窄窗口) / lg(≥840vp PC、平板横屏)。
- **sm 单栏栈**：会话列表页 → 聊天页推入；导航条收纳为底栏/顶栏；处理安全区（状态栏/挖孔/手势条）与系统返回手势。
- **md/lg 三栏**：复用 PC 三栏布局；md 可降级为两栏（列表+聊天，导航条收纳）。
- **组件化地基（M2 必须落地）**：ChatListPanel / ChatPanel 做成可嵌入组件，页面只是容器——同一份 UI 三形态复用；监听窗口尺寸实时切断点（PC 自由窗口缩放同样受益）。
- **deviceTypes**：扩展为 `["2in1", "tablet", "phone"]`（M2 PR 落地）。

## 5. 里程碑与验收标准

### M0 工程骨架与侧载通路（约 0.5 周）
- DevEco 工程（API 26，`deviceTypes: ["2in1"]`）；声明 INTERNET / KEEP_BACKGROUND_RUNNING / 通知权限。
- DevEco 自动签名 → `hdc app install` → 真机启动显示占位页。
- **验收**：HAP 在鸿蒙 PC 上安装、启动、日志可查。

### M1 TDLib 移植与 NAPI 桥（约 1~1.5 周）
- 交叉编译链：host 侧 gperf + `prepare_cross_compiling`（或 TD_GENERATE_SOURCE_FILES）→ OHOS NDK `ohos.toolchain.cmake` 编 `tdjson`。
- 应用社区补丁 2 处；openssl/zlib 复用已移植版本。
- NAPI 桥：四函数 + `napi_threadsafe_function` 后台接收线程 + 批量回调。
- 代理支持立项：TDLib `addProxy`（SOCKS5/MTProto），设置页透出（国内网络刚需）。
- **验收**：真机 `td_execute(getVersion)` 返回版本号；`td_send` 初始化数据库成功；代理连通 DC。

### M2 登录与会话骨架（约 1~1.5 周）
- `setTdlibParameters`（三个 database 全开）→ 手机号 → 验证码 → 2FA 密码 → `authorizationStateReady`。
- 会话列表：`getChats`/`loadChats` + LazyForEach；更新流分发框架（按 TDLib class 路由）。
- **响应式地基**：断点工具 + ChatListPanel 组件化；deviceTypes 扩展为 `["2in1","tablet","phone"]`；手机安全区与单栏栈路由。
- **验收**：真实账号登录成功，会话列表与官方客户端一致；PC/手机/平板三形态断点均真机可用（用户已确认具备真机）。

### M3 核心聊天 MVP（约 1.5~2 周）
- 消息列表 + `sendMessage`（文本）+ 已读回执（`viewMessages`）。
- 图片下载展示（downloadFile + Image）、视频预览（AVPlayer）、文件下载 + DocumentViewPicker 保存。
- 本地通知（`notificationManager.publish`，含 requestEnableNotification 引导）+ 点击路由到会话。
- **验收**：真实聊天收发文本/图片；新消息弹通知；最小化期间通知可用。

### M4 双端后台与保活（约 0.5~1 周）
- 背景：deviceTypes 含 phone 后，PC 端最小化同样触发后台管控——两端保活统一依赖长时任务。
- PC：TASK_KEEPING（免 ACL）兜底；手机：评估 VOIP / DATA_TRANSFER（16kB/60s 心跳约束）长时任务方案 + 常驻通知。
- **手机端备选方案评估结论（2026-04，真机实测指引）**——现方案双端统一 TASK_KEEPING（KeepAliveService 同一 API 调用），备选逐一排除：
  - **TASK_KEEPING（现方案）**：API 26 SDK 口径为「计算任务（PC/2in1 设备）」，PC/2in1 免 ACL；手机端自 API 21 起对非 PC/2in1 设备要求系统 ACL（`ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM`），本项目不申请（权限红线）→ 手机端申请预期 9800005 被拒，KeepAliveService 已按确定性拒绝处理（进程内闩锁不再自动重试 + 对冲 stop 清系统残留）。**待真机实测**：若个别版本/渠道灰度放行，属灰度用法——申请类型（计算任务）与实际业务（长连接保活）不完全相符，系统一致性校验（申请类型与实际业务不符/业务已结束）存在被查杀/取消风险，不能作为长期依赖；实测口径 = 最小化 >24h 收消息是否送达。
  - **DATA_TRANSFER（备选，弃用）**：语义为非托管上传/下载，系统持续校验后台流量与进度——调研口径约 16kB/60s 流量门槛（长时间不足则判无传输业务、任务被取消），官方约束「进度超过 10 分钟不更新任务会被取消」，且 API 20+ 新增挂起理由 SYSTEM_SUSPEND_DATA_TRANSFER_LOW_SPEED（数据传输速率过低）；TDLib 长连接空闲期心跳流量远低于门槛，纯保活场景不满足约束，除非叠加 dummy 流量对抗校验（对抗系统管控，不可取）。
  - **VOIP（备选，弃用）**：API 13+ 面向「具有音视频业务的聊天类应用」通话退后台场景，本 MVP 无通话功能，申请类型与实际业务不符风险最高（一致性校验查杀 + 系统可能校验实际音频流），语义失实也违背按需申请原则。
  - 结论：手机端短期接受「后台冻结期消息延迟、前台恢复即追平」的已知限制（冻结期本地通知同样不可达）；可选增强走自建通知桥（TG Bot 转发提醒）；TASK_KEEPING 手机端真机行为（确定拒绝 or 灰度放行）列为 M4 真机实测项，据实测结论再定是否升格或换桥接方案。
- 手机端冻结期消息延迟属已知限制，前台恢复即追平；可选增强：自建通知桥（TG Bot 转发提醒）。
- **验收**：PC 最小化 >24h 消息送达；手机端给出保活实测结论与明确的限制说明。

### M5 打磨（约 1 周，持续迭代）
- emoji 面板 + RichEditor 图文混排；会话搜索/置顶/免打扰；深色模式；代理设置页；崩溃与 ANR 治理。
- **验收**：连续一周日常使用无致命问题。

### 二期候选（不排期）
贴纸/GIF 全量、语音消息、定时消息、多账号、语音视频通话（工作量大，评估后再定）。

## 6. 风险与缓解

| 风险 | 缓解 |
|---|---|
| TDLib 升级需重放补丁 | 锁定 1.8.x 版本，升级视为独立任务 |
| libtdjson 体积/内存 | 全数据库开启 + 媒体缓存上限 + LTO 裁剪 |
| 调试证书过期（约 6 个月） | 写重签脚本，记到期时间，到期前提醒 |
| 无系统级推送 | 常驻长连接 + 本地通知；不依赖 Push Kit；手机端可加自建通知桥兜底 |
| 国内直连 Telegram 不通 | 应用内置代理设置（SOCKS5/MTProto，走本机代理） |
| 社区预编译产物不可信 | 仅作起步，M1 结束前替换为自编产物（校验 SHA256） |

## 7. 脱敏与安全（硬性规则）

- 仓库**永不**提交：账号手机号、验证码、API key、证书/Profile 文件、本机绝对路径、内部域名/IP。
- 签名材料放 `local/`（.gitignore）；提交前跑脱敏扫描（见 AGENTS.md）。
- 调研文档仅保留公开资料与 URL。

## 8. 长期维护

- TDLib 版本锁定策略 + 补丁集版本化管理（patches/ 目录）。
- 重签流水线脚本化：`scripts/renew-signing.sh`（到期提醒走 cron）。
- 每次发版打 tag（`v0.x.y`），保留可回退 HAP。
