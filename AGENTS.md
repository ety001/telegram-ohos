# AGENTS.md — 工程约定

## 提交规范

- Conventional Commits，subject 用中文：`feat: 会话列表支持置顶`
- 一次提交只做一件事；不发无关文件的混合提交。

## 脱敏硬规则（每次提交前执行）

仓库永不包含以下内容，提交前自查（含新增文件全文与 diff）：

1. 账号手机号、验证码、登录凭据
2. API key、token、密码
3. 签名证书 / Profile / keystore（统一放 `local/`，已被 .gitignore）
4. 本机绝对路径、内部域名、内网 IP
5. 真实聊天内容截图或导出
6. **任何第三方项目的代码与文档原文**——本项目代码全部原创（已评估 TelegramHarmony 等现有实现，均不作为代码或设计来源）；`patches/` 中的上游 diff 上下文行与出处声明属正当引用，除外

快速扫描（文本）：

```sh
git diff --cached | grep -nEi '([0-9]{11}|\+86|token|secret|password|api[_-]?key|BEGIN (RSA|EC|OPENSSH))'
```

有命中 → 人工确认是否误报，未确认前不提交。

二进制产物（.so 等）额外扫描（`git diff` 对二进制失明，本条由 M1 复审血的教训换来的）：

```sh
strings <待入库二进制> | grep -nE '/home/|/storage/|/Users/|/data/' | head -20
```

命中判读（良性白名单，不算违规）：
- `tg://` 开头的深链 URI（TDLib 内置设置页路径，如 `tg://settings/data/`）
- `/srv/workspace/llvm-release/...`（华为 OHOS NDK 预编译 libc++abi/libunwind 自带的厂商 CI 路径，任何机器同版 SDK 构建结果一致）
- `/usr/tmp`、`/var/tmp`（libc 标准回退目录）

本机路径命中 → 禁止入库，先修编译，两层手段缺一不可：
1. 编译期：native 产物统一加 `-ffile-prefix-map=<源码路径>=td` 重映射（根治 `__FILE__` 宏与 DWARF 路径）；
2. 静态依赖兜底：预编译静态库（如 openssl）内固化的配置路径 `-ffile-prefix-map` 管不到，需等长字节清洗（见 `scripts/build_tdlib.sh` 的 `sanitize_host_paths`），并在入库前设门禁校验（非 0 即停）。

## 构建注意

- 目标 API 26（HarmonyOS 7，真机三件套 PC/手机/平板均为该版本）；`deviceTypes: ["2in1","tablet","phone"]` 三形态自适应（2026-04 变更）。注意：含 phone 后 PC 端最小化同样触发后台管控，双端保活依赖长时任务（见 PLAN.md M4）。
- TDLib 版本锁定在 `patches/` 对应的版本；升级 = 重放补丁 + 全量回归，独立任务处理。
- 交叉编译 TDLib：host 侧需 gperf 与 CMake ≥3.10，先 `prepare_cross_compiling` 再用 OHOS NDK 工具链编 `tdjson`。
- libtdjson.so 实测体积：unstripped ≈53MB，`llvm-strip --strip-unneeded` 后 ≈34MB（静态并入 openssl/libc++ 且无 LTO 所致；社区参考值 19MB 为 Android LTO+strip 口径，勿混淆）。**入库产物一律 strip 后提交**，unstripped 副本另存（GitHub Release）供崩溃符号化。
- TDLib 数据库/文件目录一律放应用沙盒（`context.filesDir`/`cacheDir`），禁止写共享目录。
- 网络策略：协议流量全部走 TDLib；应用内代理设置（SOCKS5/MTProto）是必备功能，不是可选。
- 发版物（HAP 等发布包）必须随附 LICENSE、NOTICE、THIRD-PARTY-NOTICES 三件套（Apache-2.0 §4 与各第三方许可的分发义务）。

## 目录规划（随里程碑逐步落地）

```
entry/src/main/ets/       # ArkUI 页面与状态
entry/src/main/cpp/       # NAPI 桥（tdnapi）
libs/arm64-v8a/           # libtdjson.so 等预编译产物
patches/                  # TDLib 源码补丁（版本化）
scripts/                  # 构建 / 签名 / 脱敏扫描脚本
docs/                     # 计划与调研文档
local/                    # 本地签名材料（不入库）
```
