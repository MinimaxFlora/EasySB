# ------------------------------------------------------------------------------
# 二、基础工具与界面 / Utilities and UI
# ------------------------------------------------------------------------------
# 颜色、界面框、日志、交互输入、随机值、下载、状态读写、root 校验。
# ------------------------------------------------------------------------------

# 颜色 / Colors
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[1;34m'
C_MAGENTA='\033[1;35m'
C_CYAN='\033[1;36m'
C_WHITE='\033[1;37m'

# ------------------------------------------------------------------------------
# 界面：左侧竖线开框 / Open frame with a left vertical bar only
# ------------------------------------------------------------------------------
_UI_RULE='────────────────────────────────────────────'

ui_frame_top()  { printf '  %b╭%s%b\n' "$C_CYAN" "$_UI_RULE" "$C_RESET"; }
ui_frame_bottom() { printf '  %b╰%s%b\n' "$C_CYAN" "$_UI_RULE" "$C_RESET"; }

# 行文本（支持颜色）/ frame line
ui_frame_line() { printf '  %b│%b %b\n' "$C_CYAN" "$C_RESET" "$*"; }

# 键值行 / frame field
ui_frame_field() {
  printf '  %b│%b %b%-10s%b : %b\n' "$C_CYAN" "$C_RESET" "$C_BLUE" "$1" "$C_RESET" "$2"
}

# 子菜单标题框 / Sub-menu title panel
ui_panel() {
  printf '\n'
  ui_frame_top
  ui_frame_line "$(printf '%s%s%s' "$C_BOLD$C_MAGENTA" "$1" "$C_RESET")"
  ui_frame_bottom
}

# 菜单项与提示 / Menu item and hint
ui_item() { printf '   %b[%s]%b %s\n' "$C_GREEN" "$1" "$C_RESET" "$2"; }
ui_note() { printf '   %b%s%b\n' "$C_DIM" "$1" "$C_RESET"; }

# 日志 / Logging
log_plain() { printf '%s\n' "$*"; }
log_info()  { printf "${C_BLUE}[%s]${C_RESET} %s\n" "$(text info)" "$*" >&2; }
log_ok()    { printf "${C_GREEN}[%s]${C_RESET} %s\n" "$(text ok)" "$*" >&2; }
log_warn()  { printf "${C_YELLOW}[%s]${C_RESET} %s\n" "$(text warn)" "$*" >&2; }
log_error() { printf "${C_RED}[%s]${C_RESET} %s\n" "$(text fail)" "$*" >&2; }
log_step()  { printf "\n${C_CYAN}==> %s${C_RESET}\n" "$*" >&2; }

pause_enter() {
  printf '\n%s' "$(text press_enter)"
  read -r _
}

# 读取一行输入；可带默认值。/ Read a line with optional default.
read_default() {
  local prompt="$1" default="${2:-}" answer
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  read -r answer
  answer="${answer:-$default}"
  printf '%s' "$answer"
}

# 确认提示 / yes/no confirm. default: Y or N
confirm() {
  local prompt="$1" default="${2:-Y}" answer hint
  if [ "${default^^}" = 'N' ]; then hint='[y/N]'; else hint='[Y/n]'; fi
  printf '%s %s: ' "$prompt" "$hint" >&2
  read -r answer
  answer="${answer:-$default}"
  case "${answer,,}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log_error "$(text need_root)"
    exit 1
  fi
}

# 随机端口 / Random free port
rand_port() {
  local p
  while true; do
    p=$(( (RANDOM % 40000) + 20000 ))
    if ! port_in_use "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
}

# 随机 UUID / Random UUID
rand_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif have_cmd uuidgen; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    local hex
    hex=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    printf '%s-%s-%s-%s-%s\n' \
      "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
  fi
}

# 随机密码 / Random password (base64, 16 bytes -> 24 chars)
rand_password() {
  if have_cmd openssl; then
    openssl rand -base64 16
  else
    head -c 16 /dev/urandom | base64
  fi
}

# 随机 short id / Random Reality short id (8 hex chars)
rand_short_id() {
  if have_cmd openssl; then
    openssl rand -hex 4
  else
    od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

# 读取端口输入：回车用建议值，输入 r 随机，输入数字手动
# Prompt a port: Enter = suggested, r = random, digits = manual.
# used[] 传入已占用端口，重复时要求重新输入。
ask_port() {
  local prompt_key="$1" default="$2" out_var="$3"
  shift 3
  local used=("$@") input p owners
  while true; do
    printf "$(text "$prompt_key")" "$default" >&2
    read -r input
    if [ -z "$input" ]; then
      p="$default"
    elif [ "${input,,}" = 'r' ]; then
      p="$(rand_port)"
      log_info "$(text port_random): $p"
    else
      p="$input"
    fi
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt "$MIN_PORT" ] || [ "$p" -gt "$MAX_PORT" ]; then
      log_warn "$(text port_invalid)"; continue
    fi
    local u conflict=''
    for u in "${used[@]}"; do
      [ -n "$u" ] && [ "$u" = "$p" ] && conflict='1'
    done
    if [ -n "$conflict" ]; then
      log_warn "$(text port_conflict): $p"; continue
    fi
    if port_in_use "$p"; then
      owners="$(port_owners "$p")"
      case "$owners" in
        *sing-box*) : ;;                                  # 本服务已占用，允许
        '')         : ;;                                  # 无法识别占用者，放行
        *)          log_warn "$(text port_occupied): $p (${owners})"; continue ;;
      esac
    fi
    eval "$out_var='$p'"
    return 0
  done
}

# 读取 UUID / 密码：空回车自动生成 / Prompt UUID or password, Enter to auto-generate
ask_secret() {
  local prompt_key="$1" kind="$2" out_var="$3"
  local input
  printf "$(text "$prompt_key"): " >&2
  read -r input
  if [ -z "$input" ]; then
    if [ "$kind" = 'uuid' ]; then
      input="$(rand_uuid)"; log_info "$(text param_uuid_gen)"
    else
      input="$(rand_password)"; log_info "$(text param_pw_gen)"
    fi
  fi
  eval "$out_var='$input'"
}

# 下载：自动尝试 GitHub 加速前缀 / Download with proxy fallback
download() {
  local url="$1" out="$2" prefix
  for prefix in "${GITHUB_PROXY[@]}"; do
    local real_url="${prefix}${url}"
    if have_cmd curl; then
      if curl -fsSL -A 'EasySB' --connect-timeout 10 --retry 2 -o "$out" "$real_url" 2>/dev/null; then
        [ -s "$out" ] && return 0
      fi
    elif have_cmd wget; then
      if wget -q --timeout=10 --tries=2 -O "$out" "$real_url" 2>/dev/null; then
        [ -s "$out" ] && return 0
      fi
    else
      log_error 'curl/wget not found'; return 1
    fi
  done
  return 1
}

# 读取远端文本 / Fetch text to stdout
fetch_text() {
  local url="$1" prefix
  for prefix in "${GITHUB_PROXY[@]}"; do
    local real_url="${prefix}${url}"
    if have_cmd curl; then
      curl -fsSL -A 'EasySB' --connect-timeout 10 "$real_url" 2>/dev/null && return 0
    elif have_cmd wget; then
      wget -qO- --timeout=10 "$real_url" 2>/dev/null && return 0
    fi
  done
  return 1
}

# JSON 字符串转义 / Escape a JSON string value
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# 端口占用检测 / Check whether a TCP/UDP port is in use
port_in_use() {
  local port="$1"
  if have_cmd ss; then
    ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${port}$" && return 0
  elif have_cmd netstat; then
    netstat -lntu 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && return 0
  fi
  return 1
}

# 找出占用指定端口的进程名 / Find process names listening on a port
port_owners() {
  local port="$1" owners=''
  if have_cmd ss; then
    owners=$(ss -lntup 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | sed -E 's/.*users:\(\("([^"]+)".*/\1/' | sort -u | tr '\n' ',' )
  fi
  printf '%s' "${owners%,}"
}

# ------------------------------------------------------------------------------
# 状态读写 / State persistence
# ------------------------------------------------------------------------------

load_state() {
  if [ -s "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
  fi
  IS_ANYTLS="${IS_ANYTLS:-true}"
  IS_HYSTERIA2="${IS_HYSTERIA2:-true}"
  IS_TUIC="${IS_TUIC:-true}"
  IS_VLESS_REALITY="${IS_VLESS_REALITY:-true}"
  IS_VMESS_WS_TLS="${IS_VMESS_WS_TLS:-true}"
  PORT_ANYTLS="${PORT_ANYTLS:-${PROTOCOL_DEFAULT_PORT[anytls]}}"
  PORT_HYSTERIA2="${PORT_HYSTERIA2:-${PROTOCOL_DEFAULT_PORT[hysteria2]}}"
  PORT_TUIC="${PORT_TUIC:-${PROTOCOL_DEFAULT_PORT[tuic]}}"
  PORT_VLESS_REALITY="${PORT_VLESS_REALITY:-${PROTOCOL_DEFAULT_PORT[vless-reality]}}"
  PORT_VMESS_WS_TLS="${PORT_VMESS_WS_TLS:-${PROTOCOL_DEFAULT_PORT[vmess-ws-tls]}}"
  HY2_HOP_RANGE="${HY2_HOP_RANGE:-$HY2_HOP_RANGE_DEFAULT}"
  REALITY_SNI="${REALITY_SNI:-$REALITY_SNI_DEFAULT}"
  CORE_CHANNEL="${CORE_CHANNEL:-$CORE_CHANNEL_DEFAULT}"
  SUB_PORT="${SUB_PORT:-$SUB_PORT_DEFAULT}"
  SUB_PATH="${SUB_PATH:-$SUB_PATH_DEFAULT}"
  DOMAIN="${DOMAIN:-}"
  CERT_DOMAIN="${CERT_DOMAIN:-}"
  NODE_DEPLOYED="${NODE_DEPLOYED:-no}"
}

save_state() {
  mkdir -p "$WORK_DIR"
  {
    printf '# EasySB state / generated on %s\n' "$(date '+%F %T')"
    printf 'IS_ANYTLS=%q\n' "$IS_ANYTLS"
    printf 'IS_HYSTERIA2=%q\n' "$IS_HYSTERIA2"
    printf 'IS_TUIC=%q\n' "$IS_TUIC"
    printf 'IS_VLESS_REALITY=%q\n' "$IS_VLESS_REALITY"
    printf 'IS_VMESS_WS_TLS=%q\n' "$IS_VMESS_WS_TLS"
    printf 'PORT_ANYTLS=%q\n' "$PORT_ANYTLS"
    printf 'PORT_HYSTERIA2=%q\n' "$PORT_HYSTERIA2"
    printf 'PORT_TUIC=%q\n' "$PORT_TUIC"
    printf 'PORT_VLESS_REALITY=%q\n' "$PORT_VLESS_REALITY"
    printf 'PORT_VMESS_WS_TLS=%q\n' "$PORT_VMESS_WS_TLS"
    printf 'HY2_HOP_RANGE=%q\n' "$HY2_HOP_RANGE"
    printf 'REALITY_SNI=%q\n' "$REALITY_SNI"
    printf 'REALITY_PRIVATE=%q\n' "$REALITY_PRIVATE"
    printf 'REALITY_PUBLIC=%q\n' "$REALITY_PUBLIC"
    printf 'REALITY_SHORT_ID=%q\n' "$REALITY_SHORT_ID"
    printf 'UUID=%q\n' "$UUID"
    printf 'PASSWORD=%q\n' "$PASSWORD"
    printf 'DOMAIN=%q\n' "$DOMAIN"
    printf 'CERT_DOMAIN=%q\n' "$CERT_DOMAIN"
    printf 'CORE_CHANNEL=%q\n' "$CORE_CHANNEL"
    printf 'NODE_DEPLOYED=%q\n' "$NODE_DEPLOYED"
    printf 'SUB_PORT=%q\n' "$SUB_PORT"
    printf 'SUB_PATH=%q\n' "$SUB_PATH"
    printf 'SERVER_IP=%q\n' "$SERVER_IP"
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE" 2>/dev/null || true
}
