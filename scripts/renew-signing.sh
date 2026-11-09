#!/usr/bin/env bash
# 重签流水线（PLAN §8）：调试证书到期检查 + 重新构建签名 HAP 引导。
# 用法：
#   renew-signing.sh check   # 检查证书有效期（cron 友好：临期输出警告）
#   renew-signing.sh build   # 构建 unsigned HAP（签名材料就绪时输出手动签名指引）
# 约定：签名材料放 local/（.gitignore 覆盖），永不入库（AGENTS.md 红线）。
# 环境注记：鸿蒙 toybox 无 GNU date -d，到期检查用 openssl x509 -checkend 原生分级。
set -euo pipefail

LOCAL_DIR="${LOCAL_DIR:-local}"
HAP_PATH="entry/build/default/outputs/default/entry-default-unsigned.hap"
CERT_FILE="${CERT_FILE:-$LOCAL_DIR/debug.cer}"   # 调试证书（DevEco 签名材料之一）

warn_days=30

check_expiry() {
  if [[ ! -f "$CERT_FILE" ]]; then
    echo "MISSING: $CERT_FILE 不存在——请先在 DevEco（File > Project Structure > Signing Configs 勾选"
    echo "Automatically generate signature）或 AGC 申请调试证书，材料放 local/ 后重跑。"
    exit 2
  fi
  # openssl x509 -checkend <秒>：exit 0 = 该时限内未过期（toybox date 不支持 GNU -d 解析，用此法分级）
  if ! openssl x509 -in "$CERT_FILE" -noout -checkend 0 >/dev/null 2>&1; then
    echo "EXPIRED: 证书已过期！调试证书过期需重新申请（AGC 或 DevEco 自动签名）后重签 HAP。"
    exit 3
  fi
  echo "OK: 证书未过期。"
  if ! openssl x509 -in "$CERT_FILE" -noout -checkend 2592000 >/dev/null 2>&1; then
    echo "WARNING: 证书 30 天内到期，建议尽快重签。"
    exit 0
  fi
  if ! openssl x509 -in "$CERT_FILE" -noout -checkend 7776000 >/dev/null 2>&1; then
    echo "NOTE: 证书 90 天内到期，可安排重签。"
  fi
}

build_hap() {
  export PATH="/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/hvigor/bin:/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/tool/node/bin:$PATH"
  export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/sdk}"
  echo "构建 unsigned HAP（签名配置就绪后由 hvigor SignHap 任务自动签名；未配置则产物为 unsigned）…"
  hvigorw assembleHap --mode module -p product=default
  if [[ -f "$HAP_PATH" ]]; then
    echo "产物: $HAP_PATH"
    echo "签名指引："
    echo "  1) DevEco GUI: File > Project Structure > Signing Configs > Automatically generate signature（登录华为账号，一键调试签名）"
    echo "     签名后产物同目录 *-signed.hap，直接 hdc app install 安装"
    echo "  2) CLI 签名（材料齐时）: hvigorw assembleHap 前在 build-profile.json5 填入 local/ 证书路径"
    echo "  3) 安装: hdc app install <signed.hap>"
  else
    echo "ERROR: 未找到构建产物 $HAP_PATH"
    exit 4
  fi
}

case "${1:-check}" in
  check) check_expiry ;;
  build) build_hap ;;
  *)
    echo "用法: $0 {check|build}"
    exit 1
    ;;
esac
