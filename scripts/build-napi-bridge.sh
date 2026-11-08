#!/usr/bin/env bash
#
# NAPI 桥（libtdnapi.so）交叉编译 + 自检脚本 —— 目标 aarch64-linux-ohos (arm64-v8a)
#
# 用途：hvigor 不可用环境下对 entry/src/main/cpp/ 做实编验证（M1）。
#   - OHOS NDK toolchain 直编 CMake 工程，链接仓库 libs/arm64-v8a/libtdjson.so
#   - 产物落临时目录（默认 /tmp 下，--build-dir 可改），不入库：
#     正式产物由 hvigor 整包构建（entry/build-profile.json5 externalNativeOptions）生成
#   - 自检四门禁（任一失败即退出非 0）：
#       1. 架构   ：readelf Machine = AArch64
#       2. 链接   ：DT_NEEDED 含 libtdjson.so 与 libace_napi.z.so（链接闭包证明）
#       3. 符号   ：nm -D 五个导出符号 tdnapi_createClient/tdnapi_send/tdnapi_executeSync/
#                   tdnapi_startReceiving/tdnapi_stopReceiving 全命中
#                   （JS 侧 API 名无 tdnapi_ 前缀；ELF 符号加前缀防与 libc send(2) 抢占）
#       4. 脱敏   ：strip 后 strings 无本机路径（AGENTS.md 二进制扫描规则，含白名单豁免）
#
# 依赖：OHOS SDK（--sdk / OHOS_NDK_HOME / harmonybrew Cellar 自动发现，同 build_tdlib.sh）
#
# 整包（hvigor）编译与真机 td_execute 验证：待 hvigor 就绪后验证。

set -euo pipefail

# ----------------------------- 可调参数 -----------------------------
BREW_PREFIX_DEFAULT="$HOME/.harmonybrew"
BUILD_DIR_DEFAULT="${TMPDIR:-/tmp}/telegram-ohos-tdnapi-build"

# ----------------------------- 仓库定位（脚本可从任意 cwd 调用） -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CPP_DIR="$REPO_ROOT/entry/src/main/cpp"

SDK_ROOT=""
NDK_ROOT=""
BREW_PREFIX="$BREW_PREFIX_DEFAULT"
BUILD_DIR="$BUILD_DIR_DEFAULT"
JOBS="$(nproc 2>/dev/null || echo 1)"
CLEAN=0

usage() {
  cat <<USAGE
用法：scripts/build-napi-bridge.sh [选项]

NAPI 桥（libtdnapi.so）交叉编译 + 自检脚本 —— 目标 aarch64-linux-ohos (arm64-v8a)
hvigor 不可用时的实编验证通路；产物入临时目录不入库（正式产物由 hvigor 生成）。

SDK 入口（优先级从高到低，同 build_tdlib.sh）：
  --sdk PATH           OHOS SDK 根目录（内含 native/）；等价环境变量 OHOS_NDK_HOME
  --ndk PATH           直接指 native/ 目录本身，优先级低于 --sdk/OHOS_NDK_HOME

选项：
  --build-dir PATH     构建目录（默认 $BUILD_DIR_DEFAULT，仓库外）
  --jobs N, -j N       并行度（默认 nproc）
  --brew-prefix PATH   harmonybrew 前缀（默认 ~/.harmonybrew）
  --clean              删除构建目录后退出
  -h, --help           显示本帮助
USAGE
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sdk)          SDK_ROOT="$2"; shift 2 ;;
    --ndk)          NDK_ROOT="$2"; shift 2 ;;
    --build-dir)    BUILD_DIR="$2"; shift 2 ;;
    --jobs|-j)      JOBS="$2"; shift 2 ;;
    --brew-prefix)  BREW_PREFIX="$2"; shift 2 ;;
    --clean)        CLEAN=1; shift ;;
    -h|--help)      usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done

log()  { printf '\033[1;32m[build-napi-bridge]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[build-napi-bridge][FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

if [[ "$CLEAN" == "1" ]]; then
  log "清理构建目录: $BUILD_DIR"
  rm -rf "$BUILD_DIR"
  log "清理完成"
  exit 0
fi

[[ -f "$CPP_DIR/CMakeLists.txt" ]] || die "缺 $CPP_DIR/CMakeLists.txt"
[[ -f "$REPO_ROOT/libs/arm64-v8a/libtdjson.so" ]] || die "缺 libs/arm64-v8a/libtdjson.so"

# ----------------------------- 依赖自动发现（同 build_tdlib.sh 范式） -----------------------------
cellar_latest() {  # $1=Formula 名
  local d
  d="$(ls -d "$BREW_PREFIX/Cellar/$1"/*/ 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n "$d" ]] || return 1
  echo "${d%/}"
}

if [[ -z "$SDK_ROOT" && -n "${OHOS_NDK_HOME:-}" ]]; then
  SDK_ROOT="$OHOS_NDK_HOME"
  log "SDK 来自环境变量 OHOS_NDK_HOME: $SDK_ROOT"
fi
if [[ -n "$SDK_ROOT" ]]; then
  if [[ -d "$SDK_ROOT/native" ]]; then
    NDK_ROOT="$SDK_ROOT/native"
  elif [[ -x "$SDK_ROOT/llvm/bin/clang" ]]; then
    log "--sdk/OHOS_NDK_HOME 目录无 native/ 子目录，按 native/ 目录本身对待: $SDK_ROOT"
    NDK_ROOT="$SDK_ROOT"
  else
    die "--sdk/OHOS_NDK_HOME 指向的目录下既无 native/ 也无 llvm/bin/clang: $SDK_ROOT"
  fi
fi
if [[ -z "$NDK_ROOT" ]]; then
  NDK_ROOT="$(cellar_latest ohos-sdk-native)" \
    || die "未找到 ohos-sdk-native，用 --sdk <含 native/ 的 SDK 根目录> 或环境变量 OHOS_NDK_HOME 指定"
fi
[[ -x "$NDK_ROOT/llvm/bin/clang" ]] || die "SDK 缺少 llvm/bin/clang: $NDK_ROOT"

# toolchain 文件双路径探测：位置随 SDK 版本在 build/cmake/ 与 build-tools/cmake/ 间变化
TOOLCHAIN_FILE=""
for _cand in "$NDK_ROOT/build/cmake/ohos.toolchain.cmake" "$NDK_ROOT/build-tools/cmake/ohos.toolchain.cmake"; do
  if [[ -f "$_cand" ]]; then
    TOOLCHAIN_FILE="$_cand"
    break
  fi
done
[[ -n "$TOOLCHAIN_FILE" ]] \
  || die "NDK 缺少 ohos.toolchain.cmake（已探测 build/cmake/ 与 build-tools/cmake/ 两处）: $NDK_ROOT"

CMAKE="$NDK_ROOT/build-tools/cmake/bin/cmake"
NINJA="$NDK_ROOT/build-tools/cmake/bin/ninja"
[[ -x "$CMAKE" ]] || CMAKE="$(command -v cmake || true)"
[[ -x "$NINJA" ]] || NINJA="$(command -v ninja || true)"
[[ -n "$CMAKE" ]] || die "缺少 cmake（SDK 内 build-tools/cmake/bin/cmake 不存在且 PATH 无 cmake）"
[[ -n "$NINJA" ]] || die "缺少 ninja（SDK 内 build-tools/cmake/bin/ninja 不存在且 PATH 无 ninja）"

READELF="$NDK_ROOT/llvm/bin/llvm-readelf"
NM="$NDK_ROOT/llvm/bin/llvm-nm"
STRIP="$NDK_ROOT/llvm/bin/llvm-strip"
STRINGS="$NDK_ROOT/llvm/bin/llvm-strings"
for t in "$READELF" "$NM" "$STRIP" "$STRINGS"; do
  [[ -x "$t" ]] || die "NDK 缺少 llvm 工具: $t"
done

# ----------------------------- 配置 + 编译 -----------------------------
log "NDK: $NDK_ROOT | toolchain: $TOOLCHAIN_FILE"
log "cmake: $CMAKE | ninja: $NINJA | jobs: $JOBS"
log "构建目录: $BUILD_DIR（不入库）"

mkdir -p "$BUILD_DIR"
"$CMAKE" -S "$CPP_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
  -DOHOS_ARCH=arm64-v8a \
  -DOHOS_STL=c++_shared \
  -DCMAKE_BUILD_TYPE=Release
"$CMAKE" --build "$BUILD_DIR" --target tdnapi -- -j"$JOBS"

SO_FILE="$BUILD_DIR/libtdnapi.so"
[[ -f "$SO_FILE" ]] || die "构建产物缺失: $SO_FILE"

# ----------------------------- 门禁 1：架构 -----------------------------
machine="$("$READELF" -h "$SO_FILE" | awk '/^  Machine:/ && !seen {print $2; seen=1}')"
[[ "$machine" == "AArch64" ]] || die "门禁1 架构不符：Machine=${machine:-无法解析}（期望 AArch64）"
log "门禁1 架构: AArch64 ✓"

# ----------------------------- 门禁 2：链接闭包 -----------------------------
needed="$("$READELF" -d "$SO_FILE" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')"
for want in libtdjson.so libace_napi.z.so; do
  grep -qx "$want" <<<"$needed" \
    || die "门禁2 链接缺失：DT_NEEDED 无 $want（实际: $(echo "$needed" | tr '\n' ' ')）"
done
log "门禁2 链接: libtdjson.so + libace_napi.z.so 均在 DT_NEEDED ✓"

# ----------------------------- 门禁 3：导出符号 -----------------------------
missing_syms=""
for sym in tdnapi_createClient tdnapi_send tdnapi_executeSync tdnapi_startReceiving tdnapi_stopReceiving; do
  "$NM" -D "$SO_FILE" | awk -v s="$sym" '$2=="T" && $3==s {found=1} END {exit !found}' \
    || missing_syms="$missing_syms $sym"
done
[[ -z "$missing_syms" ]] \
  || die "门禁3 导出符号缺失:$missing_syms（对应 JS API createClient/send/executeSync/startReceiving/stopReceiving）"
log "门禁3 符号: 五个桥接口全部导出（tdnapi_ 前缀） ✓"

# 同时确认 TDLib 四函数来自 libtdjson.so 的未解析引用（U），证明符号约定正确
for sym in td_create_client_id td_send td_receive td_execute; do
  "$NM" -D --undefined-only "$SO_FILE" | grep -qw "$sym" \
    || die "门禁3 补充：未解析引用缺 $sym（桥未正确引用 tdjson 四函数）"
done
log "门禁3 补充: td_create_client_id/td_send/td_receive/td_execute 为 U 引用 ✓"

# ----------------------------- 门禁 4：脱敏（strip 后 strings 扫描） -----------------------------
"$STRIP" --strip-unneeded "$SO_FILE"
# 白名单（AGENTS.md）：tg:// 深链、NDK 厂商 CI 路径、libc 标准回退目录
leaks="$("$STRINGS" "$SO_FILE" \
  | grep -E '/home/|/storage/|/Users/|/data/' \
  | grep -vE '^tg://|/srv/workspace/llvm-release/|^/usr/tmp$|^/var/tmp$' || true)"
[[ -z "$leaks" ]] || { printf '本机路径泄漏:\n%s\n' "$leaks" >&2; die "门禁4 脱敏：strip 后仍含本机路径，禁止入库"; }
log "门禁4 脱敏: strings 无本机路径（白名单豁免后零命中） ✓"

log "完成：$SO_FILE ($(du -h "$SO_FILE" | cut -f1), 临时产物不入库；正式产物由 hvigor 整包构建生成)"
