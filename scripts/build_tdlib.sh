#!/usr/bin/env bash
#
# TDLib (tdjson) 交叉编译脚本 —— 目标 aarch64-linux-ohos (arm64-v8a)
#
# 两阶段构建：
#   阶段1 host  ：prepare_cross_compiling 生成 TL 源码（需要 gperf + host clang）
#   阶段2 cross ：OHOS NDK toolchain 编译 tdjson（openssl/zlib 静态链入）
#
# 用法：
#   scripts/build_tdlib.sh                       # 全流程（幂等，可重复执行）
#   scripts/build_tdlib.sh --jobs 2              # 指定并行度
#   scripts/build_tdlib.sh --ndk <path>          # 指定 OHOS NDK 根目录
#   scripts/build_tdlib.sh --td-version 1.8.63 --td-commit <sha>
#
# 依赖（默认按 harmonybrew 前缀自动发现，也可用参数覆盖）：
#   - OHOS NDK（llvm/bin/clang、build/cmake/ohos.toolchain.cmake、build-tools/cmake/bin/{cmake,ninja}）
#   - host 侧 clang/clang++/gperf
#   - openssl（静态库 libcrypto.a/libssl.a，arm64-ohos 目标）
#   - zlib（静态库 libz.a，arm64-ohos 目标）
#
# 产物：libs/arm64-v8a/libtdjson.so + libs/arm64-v8a/SHA256SUMS

set -euo pipefail

# ----------------------------- 可调参数（默认值） -----------------------------
TD_VERSION_DEFAULT="1.8.63"
TD_COMMIT_DEFAULT="f06b0bac65278b03d26414c096080e7bfecfef52"  # "Update version to 1.8.63"
BREW_PREFIX_DEFAULT="$HOME/.harmonybrew"
WORKDIR_DEFAULT="$HOME/DevEco"              # 下含 td-src/（源码）与 build/（两个构建目录），均在仓库外
JOBS_DEFAULT=1                              # 内存紧张时保守起步

# ----------------------------- 仓库定位（脚本可从任意 cwd 调用） -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_ROOT/libs/arm64-v8a"

# ----------------------------- 参数解析 -----------------------------
NDK_ROOT=""
TD_VERSION="$TD_VERSION_DEFAULT"
TD_COMMIT="$TD_COMMIT_DEFAULT"
BREW_PREFIX="$BREW_PREFIX_DEFAULT"
WORKDIR="$WORKDIR_DEFAULT"
JOBS="$JOBS_DEFAULT"
OPENSSL_ROOT=""
ZLIB_ROOT=""

usage() {
  sed -n '3,20p' "${BASH_SOURCE[0]}"; exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ndk)          NDK_ROOT="$2"; shift 2 ;;
    --td-version)   TD_VERSION="$2"; shift 2 ;;
    --td-commit)    TD_COMMIT="$2"; shift 2 ;;
    --brew-prefix)  BREW_PREFIX="$2"; shift 2 ;;
    --workdir)      WORKDIR="$2"; shift 2 ;;
    --jobs|-j)      JOBS="$2"; shift 2 ;;
    --openssl-root) OPENSSL_ROOT="$2"; shift 2 ;;
    --zlib-root)    ZLIB_ROOT="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done

log()  { printf '\033[1;32m[build_tdlib]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[build_tdlib][FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------- 依赖自动发现 -----------------------------
# 发现唯一匹配的 Cellar 目录；多个版本时取最新
cellar_latest() {  # $1=Formula 名
  local d
  d="$(ls -d "$BREW_PREFIX/Cellar/$1"/*/ 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n "$d" ]] || return 1
  echo "${d%/}"
}

[[ -d "$BREW_PREFIX" ]] || die "harmonybrew 前缀不存在: $BREW_PREFIX（用 --brew-prefix 覆盖）"

if [[ -z "$NDK_ROOT" ]]; then
  NDK_ROOT="$(cellar_latest ohos-sdk-native)" || die "未找到 ohos-sdk-native，用 --ndk 指定 NDK 根目录"
fi
[[ -x "$NDK_ROOT/llvm/bin/clang" ]]                       || die "NDK 缺少 llvm/bin/clang: $NDK_ROOT"
[[ -f "$NDK_ROOT/build/cmake/ohos.toolchain.cmake" ]]     || die "NDK 缺少 ohos.toolchain.cmake: $NDK_ROOT"
[[ -f "$NDK_ROOT/sysroot/usr/include/pthread.h" ]]        || die "NDK 缺少 sysroot: $NDK_ROOT"
CMAKE="$NDK_ROOT/build-tools/cmake/bin/cmake"
NINJA="$NDK_ROOT/build-tools/cmake/bin/ninja"
[[ -x "$CMAKE" ]] || die "NDK 缺少 cmake: $CMAKE（用 --ndk 指定含 build-tools/cmake 的 NDK）"
[[ -x "$NINJA" ]] || die "NDK 缺少 ninja: $NINJA"

HOST_CXX="$BREW_PREFIX/bin/clang++"
GPERF="$BREW_PREFIX/bin/gperf"
[[ -x "$HOST_CXX" ]] || die "缺少 host 编译器: $HOST_CXX"
[[ -x "$GPERF" ]]    || die "缺少 gperf: $GPERF（阶段1 生成 TL 源码必需）"

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

TD_SRC="$WORKDIR/td-src"
HOST_BUILD="$WORKDIR/build/td-host"
CROSS_BUILD="$WORKDIR/build/td-ohos-arm64"
mkdir -p "$WORKDIR"

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
  local ver_in_cmake
  ver_in_cmake="$(grep -m1 -oP 'project\(TDLib VERSION \K[0-9.]+' "$TD_SRC/CMakeLists.txt" || true)"
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
  [[ -f "$TD_SRC/td/generate/auto/td/telegram/td_api.cpp" ]] || regenerate=1
  if [[ ! -f "$HOST_BUILD/build.ninja" ]]; then
    CC="$BREW_PREFIX/bin/clang" CXX="$HOST_CXX" "$CMAKE" -S "$TD_SRC" -B "$HOST_BUILD" -G Ninja \
      -DCMAKE_MAKE_PROGRAM="$NINJA" \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DTD_ENABLE_JNI=OFF \
      -DGPERF_EXECUTABLE="$GPERF"
  fi
  if [[ "$regenerate" == "1" ]]; then
    "$CMAKE" --build "$HOST_BUILD" --target prepare_cross_compiling -- -j"$JOBS"
  else
    log "TL 源码已存在，增量跳过（强制重新生成请删除 $TD_SRC/td/generate/auto）"
  fi
  [[ -f "$TD_SRC/td/generate/auto/td/telegram/td_api.cpp" ]] || die "TL 源码生成失败"
}

# ----------------------------- 阶段2：交叉编译 tdjson -----------------------------
build_cross() {
  log "阶段2/2：交叉编译 tdjson（arm64-v8a, OHOS NDK toolchain）"
  clamp_jobs
  if [[ ! -f "$CROSS_BUILD/build.ninja" ]]; then
    "$CMAKE" -S "$TD_SRC" -B "$CROSS_BUILD" -G Ninja \
      -DCMAKE_MAKE_PROGRAM="$NINJA" \
      -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/ohos.toolchain.cmake" \
      -DOHOS_ARCH=arm64-v8a \
      -DOHOS_STL=c++_static \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_TESTING=OFF \
      -DTD_ENABLE_JNI=OFF \
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
collect_artifacts() {
  local so_versioned so_name machine soname
  # 构建目录中应恰好存在一个带版本号的产物（多个说明残留旧版本，要求清理重跑）
  so_versioned="$(cd "$CROSS_BUILD" && ls libtdjson.so.* 2>/dev/null | grep -E '^libtdjson\.so\.[0-9.]+$' || true)"
  [[ "$(echo "$so_versioned" | grep -c .)" == "1" ]] \
    || die "期望恰好一个 libtdjson.so.<version>，实际: ${so_versioned:-无} —— 删除 $CROSS_BUILD 后重跑"

  machine="$("$NDK_ROOT/llvm/bin/llvm-readelf" -h "$CROSS_BUILD/$so_versioned" | awk '/Machine:/{print $2" "$3" "$4}')"
  [[ "$machine" == *"AArch64"* ]] || die "产物不是 AArch64 ELF: $machine"

  soname="$("$NDK_ROOT/llvm/bin/llvm-readelf" -d "$CROSS_BUILD/$so_versioned" | sed -n 's/.*Library soname: \[\(.*\)\]/\1/p')"
  [[ "$soname" == "libtdjson.so.$TD_VERSION" ]] \
    || die "SONAME($soname) 与 TD_VERSION($TD_VERSION) 不一致 —— 源码与参数不匹配"

  mkdir -p "$OUT_DIR"
  cp -f "$CROSS_BUILD/$so_versioned" "$OUT_DIR/libtdjson.so"

  # SHA256 清单（sha256sum -c 兼容：# 开头行为注释）
  {
    echo "# libtdjson —— TDLib $TD_VERSION (commit $TD_COMMIT), aarch64-linux-ohos"
    echo "# SONAME: $soname"
    (cd "$OUT_DIR" && sha256sum libtdjson.so)
  } > "$OUT_DIR/SHA256SUMS"

  log "产物就绪：$OUT_DIR/libtdjson.so ($(du -h "$OUT_DIR/libtdjson.so" | cut -f1), SONAME=$soname)"
  cat "$OUT_DIR/SHA256SUMS"
}

# ----------------------------- 主流程 -----------------------------
main() {
  log "TDLib $TD_VERSION @ $TD_COMMIT | NDK: $NDK_ROOT | jobs: $JOBS"
  log "openssl: $OPENSSL_ROOT"
  log "zlib:    $ZLIB_ROOT"
  fetch_td_source
  apply_patches
  build_host
  build_cross
  collect_artifacts
  log "完成。产物目录: $OUT_DIR"
}

main "$@"
