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
6. **任何第三方项目的代码与文档原文**——本项目代码全部原创（已评估 TelegramHarmony 等现有实现，均不作为代码或设计来源）

快速扫描：

```sh
git diff --cached | grep -nEi '([0-9]{11}|\+86|token|secret|password|api[_-]?key|BEGIN (RSA|EC|OPENSSH))'
```

有命中 → 人工确认是否误报，未确认前不提交。

## 构建注意

- 目标 API 26（HarmonyOS 7 PC），`deviceTypes` 只留 `2in1`，勿加 `phone`（会触发手机后台挂起逻辑）。
- TDLib 版本锁定在 `patches/` 对应的版本；升级 = 重放补丁 + 全量回归，独立任务处理。
- 交叉编译 TDLib：host 侧需 gperf 与 CMake ≥3.10，先 `prepare_cross_compiling` 再用 OHOS NDK 工具链编 `tdjson`。
- libtdjson.so 约 19MB，属正常体积，不要尝试裁剪符号表来"优化"。
- TDLib 数据库/文件目录一律放应用沙盒（`context.filesDir`/`cacheDir`），禁止写共享目录。
- 网络策略：协议流量全部走 TDLib；应用内代理设置（SOCKS5/MTProto）是必备功能，不是可选。

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
