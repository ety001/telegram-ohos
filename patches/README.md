# TDLib OHOS 补丁集

本目录版本化管理交叉编译 TDLib 所需的全部源码补丁。

## 锁定版本

| 项 | 值 |
|---|---|
| TDLib 版本 | **1.8.63**（`project(TDLib VERSION 1.8.63)`） |
| 上游 commit | `f06b0bac65278b03d26414c096080e7bfecfef52`（"Update version to 1.8.63"） |
| 上游仓库 | https://github.com/tdlib/td |
| 构建方式 | 见 `scripts/build_tdlib.sh`（两阶段：host 生成 TL 源码 → OHOS NDK 交叉编译 tdjson） |

> 为什么 pin commit 而不是 tag：上游自 1.8.0 后不再打 release tag，锁定 commit `f06b0bac65278b03d26414c096080e7bfecfef52`（"Update version to 1.8.63"）。
> 版本自校验由构建脚本完成：源码 CMakeLists 的 `project(TDLib VERSION …)` 必须与 `--td-version` 一致，否则构建即失败。
> 产物 SONAME 固定为 `libtdjson.so`（与文件名一致）——NAPI 桥按文件名链接与 dlopen，版本化 SONAME 会导致设备加载失败（见补丁 0003）。

## 补丁清单

| 补丁 | 改动 | 目的 |
|---|---|---|
| `0001-add-ohos-platform-support.patch` | `tdutils/td/utils/port/platform.h` 新增 `__OHOS__ → TD_OHOS` 平台识别；`config.h` 把 `TD_OHOS` 并入 epoll/eventfd（Linux）组；`uname.cpp` OS 名返回 `HarmonyOS` | OHOS musl 内核语义与 Linux 一致（epoll/eventfd 可用），但宏需在 `__linux__` 分支之前识别，否则 TDLib 落到通用 Linux 路径 |
| `0002-disable-thread-affinity-on-ohos.patch` | `tdutils/td/utils/port/detail/ThreadPthread.h` 线程亲和性条件追加 `&& !TD_OHOS` | OHOS musl 不提供 `pthread_setaffinity_np` 等 affinity API，禁用 `TD_HAVE_THREAD_AFFINITY` 后该能力退化为不可用（TDLib 仅在显式设置线程亲和时才调用，默认路径不受影响） |
| `0003-unversioned-soname-libtdjson-so-on-ohos.patch` | `CMakeLists.txt` 的 `set_property(TARGET tdjson PROPERTY SOVERSION …)` 在 `CMAKE_SYSTEM_NAME STREQUAL "OHOS"` 时跳过 | SONAME 必须与文件名 `libtdjson.so` 一致：NAPI 桥按文件名链接，DT_NEEDED 记录的是 SONAME，版本化 SONAME 会让设备加载器找不到文件。脚本再经 `-DCMAKE_SHARED_LINKER_FLAGS="-Wl,-soname,libtdjson.so"` 显式注入（CMake 自身的 SOVERSION 注入位于链接命令末尾、会覆盖 linker flags，故需本补丁先移除） |

## 补丁来源

改动均为最小必要修改，思路参考社区先例（与本项目调研记录 docs/RESEARCH.md §一.2 对应）：

- ErBWs/tdlib-ohos-build 的 `td-add-ohos-platform.patch`（平台宏 + epoll/eventfd 组）
- eclipse-oniro4openharmony/app-Tele4Watch 的 `build_tdlib_ohos.ps1`（真机验证 1.8.63；线程亲和排除）

## 升级流程

1. 修改 `scripts/build_tdlib.sh` 中 `TD_VERSION` / `TD_COMMIT`（新版本对应 "Update version to X.Y.Z" 提交）。
2. 重放补丁：`git apply` 失败时手工修冲突并重新生成 patch 文件（在 TDLib 源码树内 `git diff > <repo>/patches/xxx.patch`）。
3. **TL 生成物自动失效**：`td/generate/auto/` 被 td 仓库 `.gitignore` 忽略，`checkout -f` 不会清理它，版本切换后残留旧 TL 生成物会编出旧协议。构建脚本在 `auto/` 内维护 stamp 文件（内容 = `TD_COMMIT`），检测到不一致即删除整个 `auto/` 目录并强制重跑 `prepare_cross_compiling`，升级时无需手工干预。
4. 全量重编 + 真机回归（见 AGENTS.md「构建注意」）。入库产物由脚本自动 `llvm-strip --strip-unneeded`（≈53MB → ≈34MB）；unstripped 原件保留在构建目录 `<workdir>/build/td-ohos-arm64/libtdjson.so.unstripped`（在仓库外、不入 git），供崩溃符号化。`SHA256SUMS` 由脚本生成，勿手改。
