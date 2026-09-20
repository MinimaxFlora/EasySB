#!/usr/bin/env bash
# ==============================================================================
#  EasySB v2 - 五合一 sing-box 一键部署脚本 / EasySB v2 - 5-in-1 sing-box deployer
# ------------------------------------------------------------------------------
#  项目名称 Project   : EasySB
#  项目地址 Homepage  : https://github.com/MinimaxFlora/EasySB
#  作者 Author        : MinimaxFlora
#  开源协议 License   : GPL-3.0
# ------------------------------------------------------------------------------
#  支持协议 / Supported protocols
#    - AnyTLS
#    - Hysteria2 (含端口跳跃 / with port hopping)
#    - TUIC v5
#    - VMess + WebSocket + TLS
#    - VLESS + Vision + Reality
#
#  内核来源 / Core source : https://github.com/SagerNet/sing-box
#    正式版 stable : 官方 latest release
#    内测版 alpha  : 官方 prerelease
# ==============================================================================

# ------------------------------------------------------------------------------
# 一、远端资源 / Remote endpoints
# ------------------------------------------------------------------------------
PROJECT_REPO='MinimaxFlora/EasySB'
PROJECT_BRANCH='master'
PROJECT_HOME="https://github.com/${PROJECT_REPO}"
PROJECT_RAW="https://raw.githubusercontent.com/${PROJECT_REPO}/${PROJECT_BRANCH}"
PROJECT_RELEASE="https://github.com/${PROJECT_REPO}/releases"
# 脚本自身发布地址，安装与 [sb] 快捷指令都从这里拉取最新脚本
SCRIPT_RELEASE_TAG='easysb'
SCRIPT_URL="${PROJECT_RELEASE}/download/${SCRIPT_RELEASE_TAG}/easysb.sh"
# 客户端订阅模板（sing-box tun + fakeip），从本仓库 Templates/ 拉取
SUBSCRIBE_TEMPLATE_URL="${PROJECT_RAW}/Templates/tun-fakeip.json"

# 内核官方地址 / Official core endpoints
SING_BOX_REPO='SagerNet/sing-box'
SING_BOX_API="https://api.github.com/repos/${SING_BOX_REPO}/releases"
SING_BOX_WEB="https://github.com/${SING_BOX_REPO}"

# GitHub 加速前缀，仅用于加速下载（不改变资源本身）
GITHUB_PROXY=('' 'https://ghfast.top/' 'https://gh-proxy.com/')

# ------------------------------------------------------------------------------
# 二、脚本元信息与全局默认值 / Meta and defaults
# ------------------------------------------------------------------------------
# 版本号在构建时由 build.sh 从 VERSION 文件注入；直接从源码运行 lib/ 时
# 回退读取同级 VERSION 文件。/ Version is injected at build time from VERSION.
SCRIPT_VERSION='@EASYSB_VERSION@'
if [ "${SCRIPT_VERSION:0:1}" = '@' ]; then
  _easysb_ver_file="${BASH_SOURCE[0]%/*}/../VERSION"
  if [ -s "$_easysb_ver_file" ]; then
    SCRIPT_VERSION="$(tr -d '[:space:]' < "$_easysb_ver_file")"
  else
    SCRIPT_VERSION='dev'
  fi
  unset _easysb_ver_file
fi

WORK_DIR='/etc/sing-box'
CONFIG_JSON="${WORK_DIR}/config.json"
STATE_FILE="${WORK_DIR}/easysb.conf"
SUBSCRIBE_DIR="${WORK_DIR}/subscribe"
BACKUP_DIR='/root'
TEMP_DIR='/tmp/easysb'
ACME_DIR="${HOME:-/root}/.acme.sh"
ACME_SH="${ACME_DIR}/acme.sh"
LOG_FILE="${WORK_DIR}/easysb.log"

SERVICE_NAME='sing-box'
SHORTCUT='/usr/bin/sb'
NGINX_SERVICE='nginx'

# 内核二进制路径 / Core binary path
CORE_BIN="${WORK_DIR}/sing-box"

# 五协议固定清单与默认端口 / Fixed protocol list and default ports
PROTOCOL_KEYS=('anytls' 'hysteria2' 'tuic' 'vless-reality' 'vmess-ws-tls')
declare -A PROTOCOL_LABEL=(
  [anytls]='AnyTLS'
  [hysteria2]='Hysteria2'
  [tuic]='TUIC v5'
  [vless-reality]='VLESS-Vision-Reality'
  [vmess-ws-tls]='VMess-WebSocket-TLS'
)
declare -A PROTOCOL_DEFAULT_PORT=(
  [anytls]=8000
  [hysteria2]=8001
  [tuic]=8002
  [vless-reality]=8003
  [vmess-ws-tls]=8004
)

# Hysteria2 端口跳跃默认范围 / Default port-hopping range
HY2_HOP_RANGE_DEFAULT='2080:3000'
# Reality 默认偷用域名 / Default Reality handshake SNI
REALITY_SNI_DEFAULT='apple.com'
# Reality 偷用域名预设 / Preset handshake domains
REALITY_SNI_PRESETS=('academy.nvidia.com' 'apple.com' 'bing.com' 'microsoft.com' 'cloudflare.com')
# 订阅默认参数 / Default subscription settings
SUB_PORT_DEFAULT='8443'
SUB_PATH_DEFAULT='/subscribe'
# 语言默认值 / Default language (C=简体中文, E=English)
LANGUAGE_DEFAULT='C'
# 内核默认通道 / Default core channel (stable|alpha)
CORE_CHANNEL_DEFAULT='stable'

MIN_PORT=1
MAX_PORT=65535
MIN_HOPPING_PORT=10000
MAX_HOPPING_PORT=65535
MIN_HOPPING_LOWER=1
MAX_HOPPING_LOWER=65534

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

# ------------------------------------------------------------------------------
# 三、运行期临时目录 / Runtime temp dir
# ------------------------------------------------------------------------------
cleanup_temp() { [ -n "${TEMP_DIR}" ] && rm -rf "$TEMP_DIR" 2>/dev/null; }
trap cleanup_temp EXIT
trap 'cleanup_temp; printf "\n"; exit 1' INT QUIT TERM
mkdir -p "$TEMP_DIR"

# ------------------------------------------------------------------------------
# 四、版本头部横幅 / Banner
# ------------------------------------------------------------------------------
# 采用左侧竖线的"开框"样式：右侧不闭合，避免不同终端下右边框错位。
# Open box with a left vertical line only (right side stays open on purpose).
print_banner() {
  printf '\n'
  ui_frame_top
  ui_frame_line "$(printf '%s%sEasySB%s  %sv%s%s' "$C_BOLD" "$C_MAGENTA" "$C_RESET" "$C_CYAN" "$SCRIPT_VERSION" "$C_RESET")"
  ui_frame_line "$(printf '%s%s%s' "$C_WHITE" "$(text banner_tagline)" "$C_RESET")"
  ui_frame_line ''
  ui_frame_field "$(text banner_author)"  'MinimaxFlora'
  ui_frame_field "$(text banner_project)" "$PROJECT_HOME"
  ui_frame_field "$(text banner_core)"    "$SING_BOX_WEB"
  ui_frame_field "$(text banner_quote)"   "$(hitokoto)"
  ui_frame_bottom
  printf '\n'
}
