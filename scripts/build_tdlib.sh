#!/usr/bin/env bash
#
# TDLib (tdjson) 交叉编译脚本 —— 目标 aarch64-linux-ohos (arm64-v8a)
#
# 两阶段构建：
#   阶段1 host  ：prepare_cross_compiling 生成 TL 源码（需要 gperf + host clang）
#   阶段2 cross ：OHOS NDK toolchain 编译 tdjson（openssl/zlib 静态链入）
#
# 依赖（默认按 harmonybrew 前缀自动发现，也可用参数覆盖；详见 -h）：
#   - OHOS NDK（llvm/bin/clang、build/cmake/ohos.toolchain.cmake、build-tools/cmake/bin/{cmake,ninja}）
#   - host 侧 clang/clang++/gperf、python3（产物路径清洗兜底）
#   - openssl（静态库 libcrypto.a/libssl.a，arm64-ohos 目标）
#   - zlib（静态库 libz.a，arm64-ohos 目标）

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
  cat <<'USAGE'
用法：scripts/build_tdlib.sh [选项]

TDLib (tdjson) 交叉编译脚本 —— 目标 aarch64-linux-ohos (arm64-v8a)

两阶段构建：
  阶段1 host  ：prepare_cross_compiling 生成 TL 源码（需要 gperf + host clang）
  阶段2 cross ：OHOS NDK toolchain 编译 tdjson（openssl/zlib 静态链入）

选项：
  --jobs N, -j N       并行度（默认 1；可用内存 < 2G 时自动降为 1）
  --ndk PATH           OHOS NDK 根目录（默认按 harmonybrew Cellar 自动发现）
  --td-version X.Y.Z   TDLib 版本号，须与源码 CMakeLists 的 project VERSION 一致
  --td-commit SHA      TDLib 上游 commit（默认 f06b0bac65278b03d26414c096080e7bfecfef52）
  --brew-prefix PATH   harmonybrew 前缀（默认 ~/.harmonybrew）
  --workdir PATH       构建工作目录（默认 ~/DevEco，下含 td-src/ 与 build/）
  --openssl-root PATH  openssl 根目录（含 lib/libcrypto.a、lib/libssl.a，aarch64-ohos）
  --zlib-root PATH     zlib 根目录（含 lib/libz.a，aarch64-ohos）
  -h, --help           显示本帮助

产物：libs/arm64-v8a/libtdjson.so（已 strip）+ libs/arm64-v8a/SHA256SUMS（脚本生成）
      unstripped 原件保留在 <workdir>/build/td-ohos-arm64/（不入库），供崩溃符号化
USAGE
  exit 1
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
# auto/ 生成物陷阱：td/generate/auto/ 被 td 仓库 .gitignore 忽略，checkout -f 不会清理它；
# 版本切换后残留的旧 TL 生成物会被交叉阶段照常编译（编出旧协议）。
# 对策：auto/ 内记录 stamp（内容=TD_COMMIT），执行时比对——不一致则整目录删除并强制重生成。
AUTO_DIR="$TD_SRC/td/generate/auto"
AUTO_STAMP="$AUTO_DIR/.td-commit-stamp"

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
    CC="$BREW_PREFIX/bin/clang" CXX="$HOST_CXX" "$CMAKE" -S "$TD_SRC" -B "$HOST_BUILD" -G Ninja \
      -DCMAKE_MAKE_PROGRAM="$NINJA" \
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
      -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/ohos.toolchain.cmake" \
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

  # SHA256 清单（sha256sum -c 兼容：# 开头行为注释；本文件由脚本生成，勿手改）
  {
    echo "# libtdjson —— TDLib $TD_VERSION (commit $TD_COMMIT), aarch64-linux-ohos"
    echo "# SONAME: $soname"
    (cd "$OUT_DIR" && sha256sum libtdjson.so)
  } > "$OUT_DIR/SHA256SUMS"

  log "产物就绪：$OUT_DIR/libtdjson.so ($(du -h "$OUT_DIR/libtdjson.so" | cut -f1), SONAME=$soname, 已 strip)"
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
