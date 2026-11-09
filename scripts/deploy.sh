#!/usr/bin/env bash
# 部署脚本：检测设备 → 安装 HAP → 启动 → 抓 TDLib 日志。
# 用法：
#   deploy.sh              # 全流程（需已连接设备且 HAP 已签名或设备接受未签名包）
#   deploy.sh --no-start   # 只安装不启动
# 设备连接：真机 USB 调试 / 无线调试（hdc tconn IP:端口）；PC 自连需本机 hdcd 运行。
# 环境注记：鸿蒙 toybox；hdc 固定用 /data/app/bin/hdc。
HDC="${HDC:-/data/app/bin/hdc}"
HAP_DIR="entry/build/default/outputs/default"

find_hap() {
  local signed unsigned
  signed=$(ls "$HAP_DIR"/*-signed*.hap 2>/dev/null | head -1 || true)
  unsigned=$(ls "$HAP_DIR"/entry-default-unsigned.hap 2>/dev/null | head -1 || true)
  if [[ -n "$signed" ]]; then
    echo "$signed"
  elif [[ -n "$unsigned" ]]; then
    echo "$unsigned"
  else
    echo ""
  fi
}

main() {
  cd "$(dirname "$0")/.." || exit 1
  # 1. 设备检测
  local targets
  targets=$("$HDC" list targets 2>/dev/null | grep -v '^\[Empty\]$' | head -1 || true)
  if [[ -z "$targets" ]]; then
    echo "未检测到设备。请："
    echo "  - 真机：开启 USB 调试并连接，或无线调试后执行: $HDC tconn <IP>:<端口>"
    echo "  - 本机自连：需系统 hdcd 运行（开发者模式）"
    exit 2
  fi
  echo "设备: $targets"

  # 2. 构建（幂等，已构建则秒过）
  export PATH="/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/hvigor/bin:/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/tool/node/bin:$PATH"
  export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/sdk}"
  hvigorw assembleHap --mode module -p product=default || exit 3

  # 3. 选包（优先已签名）
  local hap
  hap=$(find_hap)
  if [[ -z "$hap" ]]; then
    echo "ERROR: 未找到 HAP 产物，先跑 hvigorw assembleHap"
    exit 4
  fi
  echo "安装包: $hap"
  case "$hap" in
    *unsigned*) echo "注意: 未签名包——模拟器/部分设备可能拒绝安装；签名指引见 scripts/renew-signing.sh build" ;;
  esac

  # 4. 安装
  "$HDC" app install "$hap" || exit 5

  # 5. 启动（可选）
  if [[ "${1:-}" != "--no-start" ]]; then
    "$HDC" shell aa start -a EntryAbility -b com.ety001.telegramohos && echo "已启动 EntryAbility"
  fi

  # 6. 日志观察入口提示
  echo "看 TDLib 日志: $HDC shell hilog | grep -E 'TdClient|AuthService'"
  echo "验收标记: 聊天区出现 'TDLib x.x.x · connected' 即 M1 连通通过"
}

main "$@"
