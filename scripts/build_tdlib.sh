#!/usr/bin/env bash
#
# TDLib (tdjson) 交叉编译脚本 —— 目标 aarch64-linux-ohos (arm64-v8a)
#
# 两阶段构建：
#   阶段1 host  ：prepare_cross_compiling 生成 TL 源码（需要 gperf + host clang）
#   阶段2 cross ：OHOS NDK toolchain 编译 tdjson（openssl/zlib 静态链入）
#
# 依赖（三端可用：鸿蒙 PC / GitHub Actions / 其它 x64 Linux；详见 -h）：
#   - OHOS SDK：--sdk <含 native/ 的目录> 或环境变量 OHOS_NDK_HOME（显式唯一入口）；
#     未指定时回落鸿蒙 PC 本机兜底（harmonybrew Cellar 自动发现，ohos-sdk-native 本身即 native/ 目录）
#   - NDK 内 toolchain 文件双路径探测（位置随 SDK 版本变化）：
#     native/build/cmake/ 与 native/build-tools/cmake/ 下的 ohos.toolchain.cmake
#   - cmake/ninja：优先 SDK 内置（build-tools/cmake/bin），缺失回落 PATH（CI 由 apt 提供）
#   - host 侧 clang/clang++/gperf：优先 harmonybrew，前缀不存在时回落 PATH（CI 由 apt 提供）
#   - openssl（静态库 libcrypto.a/libssl.a，arm64-ohos 目标）
#   - zlib（静态库 libz.a，arm64-ohos 目标）

set -euo pipefail

# ----------------------------- 可调参数（默认值） -----------------------------
TD_VERSION_DEFAULT="1.8.63"
TD_COMMIT_DEFAULT="f06b0bac65278b03d26414c096080e7bfecfef52"  # "Update version to 1.8.63"
BREW_PREFIX_DEFAULT="$HOME/.harmonybrew"
WORKDIR_DEFAULT="$HOME/DevEco"              # 下含 td-src/（源码）与 build/（两个构建目录），均在仓库外
JOBS_DEFAULT="$(nproc 2>/dev/null || echo 1)"  # 默认取核数；可用内存 < 2G 时由 clamp_jobs 自动压回 1

# ----------------------------- 仓库定位（脚本可从任意 cwd 调用） -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_ROOT/libs/arm64-v8a"            # 产物目录（--out 可覆盖为 CI staging 目录）

# ----------------------------- 参数解析 -----------------------------
SDK_ROOT=""                                 # --sdk / OHOS_NDK_HOME：指向含 native/ 的 SDK 根目录
NDK_ROOT=""                                 # --ndk（兼容旧参）：直接指 native/ 目录；--sdk 优先
TD_VERSION="$TD_VERSION_DEFAULT"
TD_COMMIT="$TD_COMMIT_DEFAULT"
BREW_PREFIX="$BREW_PREFIX_DEFAULT"
WORKDIR="$WORKDIR_DEFAULT"
JOBS="$JOBS_DEFAULT"
OPENSSL_ROOT=""
ZLIB_ROOT=""
USE_CCACHE=0
CLEAN=0

usage() {
  cat <<USAGE
用法：scripts/build_tdlib.sh [选项]
      scripts/build_tdlib.sh --clean [--workdir PATH]   # 只清理，不编译

TDLib (tdjson) 交叉编译脚本 —— 目标 aarch64-linux-ohos (arm64-v8a)

两阶段构建：
  阶段1 host  ：prepare_cross_compiling 生成 TL 源码（需要 gperf + host clang）
  阶段2 cross ：OHOS NDK toolchain 编译 tdjson（openssl/zlib 静态链入）

SDK 入口（优先级从高到低）：
  --sdk PATH           OHOS SDK 根目录（内含 native/）；等价环境变量 OHOS_NDK_HOME。
                       显式传入时完全以传入为准（CI/跨端唯一入口）；本机不传则回落
                       harmonybrew Cellar 自动发现（ohos-sdk-native 本身即 native/ 目录）
  --ndk PATH           （兼容旧参）直接指 native/ 目录本身，优先级低于 --sdk/OHOS_NDK_HOME

选项：
  --jobs N, -j N       并行度（默认 nproc；可用内存 < 2G 时自动降为 1）
  --ccache             启用 ccache（注入 CMAKE_C(XX)_COMPILER_LAUNCHER=ccache；PATH 内无 ccache 时报错）
  --out DIR            产物（libtdjson.so + SHA256SUMS）输出目录（默认 <repo>/libs/arm64-v8a/）；
                       strip/泄漏门禁/unstripped 副本流程不受影响（unstripped 仍在构建目录）
  --clean              子命令：删除 <workdir>/build/ 下两个构建目录与 TL 生成 stamp 后退出
  --td-version X.Y.Z   TDLib 版本号，须与源码 CMakeLists 的 project VERSION 一致
  --td-commit SHA      TDLib 上游 commit（默认 $TD_COMMIT_DEFAULT，见脚本顶部同名变量）
  --brew-prefix PATH   harmonybrew 前缀（默认 ~/.harmonybrew；不存在时 host 工具回落 PATH 发现）
  --workdir PATH       构建工作目录（默认 ~/DevEco，下含 td-src/ 与 build/）
  --openssl-root PATH  openssl 根目录（含 lib/libcrypto.a、lib/libssl.a，aarch64-ohos）
  --zlib-root PATH     zlib 根目录（含 lib/libz.a，aarch64-ohos）
  -h, --help           显示本帮助

产物：--out 指定目录（默认 <repo>/libs/arm64-v8a/）下 libtdjson.so（已 strip）+ SHA256SUMS（脚本生成）
      unstripped 原件保留在 <workdir>/build/td-ohos-arm64/（不入库），供崩溃符号化
USAGE
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sdk)          SDK_ROOT="$2"; shift 2 ;;
    --ndk)          NDK_ROOT="$2"; shift 2 ;;
    --td-version)   TD_VERSION="$2"; shift 2 ;;
    --td-commit)    TD_COMMIT="$2"; shift 2 ;;
    --brew-prefix)  BREW_PREFIX="$2"; shift 2 ;;
    --workdir)      WORKDIR="$2"; shift 2 ;;
    --jobs|-j)      JOBS="$2"; shift 2 ;;
    --openssl-root) OPENSSL_ROOT="$2"; shift 2 ;;
    --zlib-root)    ZLIB_ROOT="$2"; shift 2 ;;
    --out)          OUT_DIR="$2"; shift 2 ;;
    --ccache)       USE_CCACHE=1; shift ;;
    --clean)        CLEAN=1; shift ;;
    -h|--help)      usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done

log()  { printf '\033[1;32m[build_tdlib]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[build_tdlib][FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------- 路径推导（--clean 也依赖，先于依赖发现） -----------------------------
TD_SRC="$WORKDIR/td-src"
HOST_BUILD="$WORKDIR/build/td-host"
CROSS_BUILD="$WORKDIR/build/td-ohos-arm64"
# auto/ 生成物陷阱：td/generate/auto/ 被 td 仓库 .gitignore 忽略，checkout -f 不会清理它；
# 版本切换后残留的旧 TL 生成物会被交叉阶段照常编译（编出旧协议）。
# 对策：auto/ 内记录 stamp（内容=TD_COMMIT），执行时比对——不一致则整目录删除并强制重生成。
AUTO_DIR="$TD_SRC/td/generate/auto"
AUTO_STAMP="$AUTO_DIR/.td-commit-stamp"

# ----------------------------- --clean 子命令（不编译，提前退出） -----------------------------
do_clean() {
  log "清理构建目录: $HOST_BUILD"
  rm -rf "$HOST_BUILD"
  log "清理构建目录: $CROSS_BUILD"
  rm -rf "$CROSS_BUILD"
  if [[ -e "$AUTO_STAMP" ]]; then
    rm -f "$AUTO_STAMP"
    log "已删除 TL 生成 stamp（$AUTO_STAMP），下次构建将强制重生成 auto/"
  else
    log "无 TL 生成 stamp（$AUTO_STAMP），跳过"
  fi
  log "清理完成（TDLib 源码 $TD_SRC 保留，如需彻底重来请手工删除）"
}
if [[ "$CLEAN" == "1" ]]; then
  do_clean
  exit 0
fi

mkdir -p "$WORKDIR"

# ----------------------------- 依赖自动发现 -----------------------------
# 发现唯一匹配的 Cellar 目录；多个版本时取最新
cellar_latest() {  # $1=Formula 名
  local d
  d="$(ls -d "$BREW_PREFIX/Cellar/$1"/*/ 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n "$d" ]] || return 1
  echo "${d%/}"
}

# ---- SDK / NDK 解析：--sdk > OHOS_NDK_HOME > --ndk > harmonybrew Cellar 本机兜底 ----
if [[ -z "$SDK_ROOT" && -n "${OHOS_NDK_HOME:-}" ]]; then
  SDK_ROOT="$OHOS_NDK_HOME"
  log "SDK 来自环境变量 OHOS_NDK_HOME: $SDK_ROOT"
fi
if [[ -n "$SDK_ROOT" ]]; then
  if [[ -d "$SDK_ROOT/native" ]]; then
    NDK_ROOT="$SDK_ROOT/native"
  elif [[ -x "$SDK_ROOT/llvm/bin/clang" ]]; then
    # 宽容处理：个别工具链/Action 习惯把变量直接指到 native/ 目录
    log "--sdk/OHOS_NDK_HOME 目录无 native/ 子目录，按 native/ 目录本身对待: $SDK_ROOT"
    NDK_ROOT="$SDK_ROOT"
  else
    die "--sdk/OHOS_NDK_HOME 指向的目录下既无 native/ 也无 llvm/bin/clang: $SDK_ROOT"
  fi
fi
if [[ -z "$NDK_ROOT" ]]; then
  # 本机兜底：harmonybrew Cellar 自动发现（ohos-sdk-native 本身即 native/ 目录）
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
[[ -f "$NDK_ROOT/sysroot/usr/include/pthread.h" ]] || die "NDK 缺少 sysroot: $NDK_ROOT"

# cmake/ninja：优先 SDK 内置，缺失回落 PATH（CI 由 apt 提供）
CMAKE="$NDK_ROOT/build-tools/cmake/bin/cmake"
NINJA="$NDK_ROOT/build-tools/cmake/bin/ninja"
[[ -x "$CMAKE" ]] || CMAKE="$(command -v cmake || true)"
[[ -x "$NINJA" ]] || NINJA="$(command -v ninja || true)"
[[ -n "$CMAKE" ]] || die "缺少 cmake（SDK 内 build-tools/cmake/bin/cmake 不存在且 PATH 无 cmake）——CI 里 apt install cmake，本机检查 SDK 安装"
[[ -n "$NINJA" ]] || die "缺少 ninja（SDK 内 build-tools/cmake/bin/ninja 不存在且 PATH 无 ninja）——CI 里 apt install ninja-build，本机检查 SDK 安装"

# host 工具链：优先 harmonybrew（鸿蒙 PC）；前缀不存在时回落 PATH（CI/其它 Linux 由 apt 提供）
if [[ -d "$BREW_PREFIX" ]]; then
  HOST_CC="$BREW_PREFIX/bin/clang"
  HOST_CXX="$BREW_PREFIX/bin/clang++"
  GPERF="$BREW_PREFIX/bin/gperf"
else
  log "harmonybrew 前缀不存在（$BREW_PREFIX），host 工具改从 PATH 发现（CI/非鸿蒙环境属预期）"
  HOST_CC="$(command -v clang || command -v gcc || true)"
  HOST_CXX="$(command -v clang++ || command -v g++ || true)"
  GPERF="$(command -v gperf || true)"
fi
[[ -x "$HOST_CC" ]]  || die "缺少 host C 编译器: ${HOST_CC:-PATH 未发现}——本机装 harmonybrew；CI 里 apt install clang"
[[ -x "$HOST_CXX" ]] || die "缺少 host 编译器: ${HOST_CXX:-PATH 未发现}——本机装 harmonybrew；CI 里 apt install clang"
[[ -x "$GPERF" ]]    || die "缺少 gperf: ${GPERF:-PATH 未发现}（阶段1 生成 TL 源码必需）——apt install gperf / harmonybrew install gperf"

# ccache 开关：提前校验，别等编到一半才失败（CI 已随 apt 安装；本机无则提示安装）
CCACHE_ARGS=()
if [[ "$USE_CCACHE" == "1" ]]; then
  command -v ccache >/dev/null 2>&1 \
    || die "--ccache 已启用但 PATH 内无 ccache——CI 随 apt 安装；本机用 harmonybrew/系统包管理器安装后重试"
  CCACHE_ARGS=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
  log "ccache 已启用（CMAKE_C(XX)_COMPILER_LAUNCHER）"
fi

if [[ -z "$OPENSSL_ROOT" ]]; then
  OPENSSL_ROOT="$(cellar_latest openssl@4 || cellar_latest openssl@3 || true)"
  [[ -n "$OPENSSL_ROOT" ]] || die "未找到 openssl（尝试 openssl@4/openssl@3），用 --openssl-root 指定"
fi
for f in include/openssl/ssl.h lib/libcrypto.a lib/libssl.a; do
  [[ -f "$OPENSSL_ROOT/$f" ]] || die "openssl 目录不完整（缺 $f）: $OPENSSL_ROOT"
done

if [[ -z "$ZLIB_ROOT" ]]; then
  ZLIB_ROOT="$(cellar_latest zlib-ng-compat || cellar_latest zlib || true)"
  [[ -n "$ZLIB_ROOT" ]] || die "未找到 zlib（尝试 zlib-ng-compat/zlib），用 --zlib-root 指定"
fi
for f in include/zlib.h lib/libz.a; do
  [[ -f "$ZLIB_ROOT/$f" ]] || die "zlib 目录不完整（缺 $f）: $ZLIB_ROOT"
done

# 架构断言：静态库首成员必须是 AArch64 —— harmonybrew 同名 Formula 也可能装了 host 版本，
# 误链架构不符的库要到链接期才报错且信息晦涩，这里提前用 llvm-readelf 拦截
assert_aarch64_static_lib() {  # $1=归档路径 $2=名称
  local machine
  machine="$("$NDK_ROOT/llvm/bin/llvm-readelf" -h "$1" 2>/dev/null | awk '/^  Machine:/ && !seen {gsub(/[^A-Za-z0-9]/,"",$2); print $2; seen=1}')"
  [[ "$machine" == "AArch64" ]] \
    || die "$2 首成员 Machine=${machine:-无法解析}（期望 AArch64）: $1 —— 静态库目标架构不符，请检查 --openssl-root/--zlib-root"
}
assert_aarch64_static_lib "$OPENSSL_ROOT/lib/libcrypto.a" "libcrypto.a"
assert_aarch64_static_lib "$OPENSSL_ROOT/lib/libssl.a"    "libssl.a"
assert_aarch64_static_lib "$ZLIB_ROOT/lib/libz.a"         "libz.a"

# 内存护栏：可用内存 < 2G 时并行度压到 1（可用 lld 峰值另见 AGENTS.md 构建注意）
clamp_jobs() {
  local avail_mb
  avail_mb="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 99999)"
  if [[ "$avail_mb" -lt 2048 && "$JOBS" -gt 1 ]]; then
    log "可用内存 ${avail_mb}MB < 2G，并行度 $JOBS -> 1"
    JOBS=1
  fi
}

# ----------------------------- 阶段0：源码获取与校验 -----------------------------
fetch_td_source() {
  if [[ ! -d "$TD_SRC/.git" ]]; then
    log "clone TDLib -> $TD_SRC"
    mkdir -p "$TD_SRC"
    git clone https://github.com/tdlib/td "$TD_SRC"
  fi
  log "校验并 checkout $TD_VERSION（commit $TD_COMMIT）"
  git -C "$TD_SRC" fetch -q origin "$TD_COMMIT" 2>/dev/null \
    || git -C "$TD_SRC" fetch -q origin  # 部分镜像不支持按 SHA fetch，退回全量 fetch
  git -C "$TD_SRC" cat-file -e "$TD_COMMIT^{commit}" 2>/dev/null \
    || die "TDLib 仓库中不存在 commit $TD_COMMIT"
  git -C "$TD_SRC" checkout -q -f "$TD_COMMIT"

  # 版本自校验：CMakeLists 的 project VERSION 必须与 TD_VERSION 一致
  # （sed 而非 grep -P：后者是 GNU 扩展，toybox/busybox 环境没有）
  local ver_in_cmake
  ver_in_cmake="$(sed -n 's/^project(TDLib VERSION \([0-9][0-9.]*\).*/\1/p' "$TD_SRC/CMakeLists.txt" | head -1)"
  [[ "$ver_in_cmake" == "$TD_VERSION" ]] \
    || die "源码版本($ver_in_cmake)与 --td-version($TD_VERSION) 不一致，检查 --td-commit"
}

# ----------------------------- 阶段0.5：补丁应用（幂等） -----------------------------
apply_patches() {
  local patch_dir="$REPO_ROOT/patches" p applied=0 skipped=0
  for p in "$patch_dir"/*.patch; do
    [[ -e "$p" ]] || die "patches/ 目录为空"
    if git -C "$TD_SRC" apply --check "$p" 2>/dev/null; then
      git -C "$TD_SRC" apply "$p"
      applied=$((applied+1))
      log "应用补丁: $(basename "$p")"
    elif git -C "$TD_SRC" apply --reverse --check "$p" 2>/dev/null; then
      skipped=$((skipped+1))
      log "补丁已生效，跳过: $(basename "$p")"
    else
      die "补丁无法应用（且不是已应用状态）: $p —— 上游代码可能已变化，需重放补丁"
    fi
  done
  log "补丁处理完成：新应用 $applied 个 / 已生效 $skipped 个"
}

# ----------------------------- 阶段1：host 生成 TL 源码 -----------------------------
build_host() {
  log "阶段1/2：host 构建（生成 TL 源码，需要 gperf）"
  local regenerate=0
  # 哨兵文件用 td_api.h：本版 TL 生成器把 td_api/telegram_api 拆成 _0..9.cpp，
  # 不存在统一的 td_api.cpp（旧脚本检查该文件恒不成立）
  if [[ -f "$AUTO_STAMP" && "$(cat "$AUTO_STAMP" 2>/dev/null || true)" == "$TD_COMMIT" \
        && -f "$AUTO_DIR/td/telegram/td_api.h" ]]; then
    :
  else
    if [[ -d "$AUTO_DIR" ]]; then
      log "auto/ 生成物与 TD_COMMIT($TD_COMMIT) 不一致（stamp 缺失或版本切换），删除后强制重生成"
      rm -rf "$AUTO_DIR"
    fi
    regenerate=1
  fi
  if [[ ! -f "$HOST_BUILD/build.ninja" ]]; then
    CC="$HOST_CC" CXX="$HOST_CXX" "$CMAKE" -S "$TD_SRC" -B "$HOST_BUILD" -G Ninja \
      -DCMAKE_MAKE_PROGRAM="$NINJA" \
      "${CCACHE_ARGS[@]}" \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DTD_ENABLE_JNI=OFF \
      -DGPERF_EXECUTABLE="$GPERF"
  fi
  if [[ "$regenerate" == "1" ]]; then
    "$CMAKE" --build "$HOST_BUILD" --target prepare_cross_compiling -- -j"$JOBS"
    mkdir -p "$AUTO_DIR"
    printf '%s\n' "$TD_COMMIT" > "$AUTO_STAMP"
  else
    log "TL 源码已存在且 stamp 匹配 TD_COMMIT，增量跳过（强制重生成：rm -rf $AUTO_DIR）"
  fi
  [[ -f "$AUTO_DIR/td/telegram/td_api.h" ]] || die "TL 源码生成失败"
}

# ----------------------------- 阶段2：交叉编译 tdjson -----------------------------
build_cross() {
  log "阶段2/2：交叉编译 tdjson（arm64-v8a, OHOS NDK toolchain）"
  clamp_jobs
  if [[ ! -f "$CROSS_BUILD/build.ninja" ]]; then
    # -ffile-prefix-map：把 $TD_SRC 绝对前缀重映射为 "td"，对 __FILE__（CHECK/LOG 宏内嵌
    #   .rodata 的源码路径）与 DWARF 同时生效，从根上杜绝本机路径编进产物（AGENTS.md 二进制扫描规则）。
    #   C/C++ 都要加（td 内含 sqlite3.c 等纯 C 源）。
    # -Wl,-soname,libtdjson.so：SONAME 与文件名保持一致。NAPI 桥按文件名 libtdjson.so 链接，
    #   若 SONAME 带版本号（如 libtdjson.so.1.8.63），设备加载器会按 SONAME 找文件而失败；
    #   配合 patches/0003（OHOS 下跳过 CMake 的 SOVERSION 注入）本 flag 才能生效。
    "$CMAKE" -S "$TD_SRC" -B "$CROSS_BUILD" -G Ninja \
      -DCMAKE_MAKE_PROGRAM="$NINJA" \
      -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
      "${CCACHE_ARGS[@]}" \
      -DOHOS_ARCH=arm64-v8a \
      -DOHOS_STL=c++_static \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_TESTING=OFF \
      -DTD_ENABLE_JNI=OFF \
      -DCMAKE_C_FLAGS="-ffile-prefix-map=$TD_SRC=td" \
      -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$TD_SRC=td" \
      -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-soname,libtdjson.so" \
      -DOPENSSL_USE_STATIC_LIBS=TRUE \
      -DOPENSSL_INCLUDE_DIR="$OPENSSL_ROOT/include" \
      -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_ROOT/lib/libcrypto.a" \
      -DOPENSSL_SSL_LIBRARY="$OPENSSL_ROOT/lib/libssl.a" \
      -DZLIB_INCLUDE_DIR="$ZLIB_ROOT/include" \
      -DZLIB_LIBRARY="$ZLIB_ROOT/lib/libz.a"
  fi
  "$CMAKE" --build "$CROSS_BUILD" --target tdjson -- -j"$JOBS"
}

# ----------------------------- 产物收集与自检 -----------------------------
# 本机路径兜底清洗：预编译静态库（openssl 等）在编译期就把 OPENSSLDIR/MODULESDIR 等
# 绝对路径固化进了 .a 的 .rodata，-ffile-prefix-map 只作用于本脚本编译的源码、管不到它们。
# 此处对链接产物做等长字节替换（前缀 → 等长占位符，文件布局不变，路径指向不存在的位置，
# 运行时行为不变：设备上本就没有这些目录，openssl 配置加载本来就是空跑）。
sanitize_host_paths() {  # $1=ELF 文件
  local py
  py="$BREW_PREFIX/bin/python3"; [[ -x "$py" ]] || py="$(command -v python3 || true)"
  [[ -n "$py" ]] || die "sanitize_host_paths 需要 python3（$BREW_PREFIX/bin/python3 或 PATH）"
  "$py" - "$1" "$HOME" "$BREW_PREFIX" "$WORKDIR" "$TD_SRC" <<'PYEOF'
import sys

path, prefixes = sys.argv[1], sys.argv[2:]
uniq = sorted({p.rstrip("/") for p in prefixes if p}, key=len, reverse=True)
with open(path, "rb") as fh:
    data = fh.read()
hits = []
for p in uniq:
    pb = p.encode()
    if pb in data:
        # 等长占位："/opt" + 'x' 填充，保证不产生新的 /home|/storage|/Users 前缀且偏移不变
        repl = (b"/opt" + b"x" * len(pb))[: len(pb)]
        hits.append((p, data.count(pb)))
        data = data.replace(pb, repl)
if hits:
    with open(path, "wb") as fh:
        fh.write(data)
for p, n in hits:
    print(f"[build_tdlib] sanitize: {p} x{n} -> 等长占位符")
PYEOF
}

collect_artifacts() {
  local so_file="$CROSS_BUILD/libtdjson.so" machine soname leak_count
  # 补丁 0003 后产物即 $CROSS_BUILD/libtdjson.so（无版本后缀、无 symlink）
  [[ -f "$so_file" ]] || die "构建产物缺失: $so_file"

  machine="$("$NDK_ROOT/llvm/bin/llvm-readelf" -h "$so_file" | awk '/Machine:/ && !seen {print $2; seen=1}')"
  [[ "$machine" == "AArch64" ]] || die "产物不是 AArch64 ELF: $machine"

  soname="$("$NDK_ROOT/llvm/bin/llvm-readelf" -d "$so_file" | sed -n 's/.*Library soname: \[\(.*\)\]/\1/p')"
  [[ "$soname" == "libtdjson.so" ]] \
    || die "SONAME($soname) 应为 libtdjson.so（与文件名一致，NAPI 桥按名链接/加载）—— 检查 patches/0003 与 linker flags"

  # 先清洗（strip 不影响 .rodata 字符串，顺序无碍，趁 unstripped 一起清）
  sanitize_host_paths "$so_file"

  # unstripped 原件保留在构建目录（不入库，git 不追踪 ~/DevEco），供崩溃符号化
  cp -f "$so_file" "$CROSS_BUILD/libtdjson.so.unstripped"

  mkdir -p "$OUT_DIR"
  cp -f "$so_file" "$OUT_DIR/libtdjson.so"
  # 入库产物一律 strip（AGENTS.md 构建注意：unstripped ≈53MB -> strip 后 ≈34MB）
  "$NDK_ROOT/llvm/bin/llvm-strip" --strip-unneeded "$OUT_DIR/libtdjson.so"

  # 路径泄漏门禁（AGENTS.md 二进制扫描规则）：非 0 即失败，产物禁止入库
  leak_count="$("$NDK_ROOT/llvm/bin/llvm-strings" "$OUT_DIR/libtdjson.so" | grep -cE '/home/|/storage/|/Users/' || true)"
  [[ "$leak_count" == "0" ]] \
    || die "产物仍含本机路径 ${leak_count} 处（strings | grep -E '/home/|/storage/|/Users/'）—— 禁止入库"

  # SHA256 清单：只写哈希行，不写 # 注释头。GNU coreutils 的 sha256sum -c 把 # 开头行当注释，
  # 但 toybox（本机 0.8.12）等实现会把它当文件名报错、exit 1——"注释兼容"并非跨实现保证，
  # 纯哈希行才是 sha256sum -c 的最大公约数。版本/commit/SONAME 元信息见 patches/README.md
  # 的锁定版本表，不写入本文件。本文件由脚本生成，勿手改。
  (cd "$OUT_DIR" && sha256sum libtdjson.so) > "$OUT_DIR/SHA256SUMS"

  log "产物就绪：$OUT_DIR/libtdjson.so ($(du -h "$OUT_DIR/libtdjson.so" | cut -f1), SONAME=$soname, 已 strip)"
  cat "$OUT_DIR/SHA256SUMS"
}

# ----------------------------- 主流程 -----------------------------
main() {
  local ccache_state="off"
  [[ "$USE_CCACHE" == "1" ]] && ccache_state="on"
  log "TDLib $TD_VERSION @ $TD_COMMIT | NDK: $NDK_ROOT | toolchain: $TOOLCHAIN_FILE"
  log "cmake: $CMAKE | ninja: $NINJA | jobs: $JOBS | ccache: $ccache_state"
  log "openssl: $OPENSSL_ROOT"
  log "zlib:    $ZLIB_ROOT"
  log "产物目录: $OUT_DIR"
  fetch_td_source
  apply_patches
  build_host
  build_cross
  collect_artifacts
  log "完成。产物目录: $OUT_DIR"
}

main "$@"
