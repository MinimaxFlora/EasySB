# ------------------------------------------------------------------------------
# 三、环境探测与依赖 / Environment detection and dependencies
# ------------------------------------------------------------------------------

PKG_MGR=''
SERVICE_MGR=''
ARCH=''
OS_NAME=''
OS_ID=''

check_system_info() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_NAME="${PRETTY_NAME:-${NAME:-Linux}}"
    OS_ID="${ID:-}"
    # os-release 同时定义了 VERSION / VERSION_ID，避免污染脚本变量
    # os-release also defines VERSION/VERSION_ID; keep them out of our namespace
    unset VERSION VERSION_ID 2>/dev/null || true
  else
    OS_NAME="$(uname -s)"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    SERVICE_MGR='systemd'
  elif command -v rc-service >/dev/null 2>&1 || [ -d /run/openrc ]; then
    SERVICE_MGR='openrc'
  else
    log_error "$(text unsupported_os)"
    exit 1
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR='apt'
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR='dnf'
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR='yum'
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR='apk'
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR='pacman'
  else
    PKG_MGR='unknown'
  fi
}

check_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64)   ARCH='amd64' ;;
    aarch64|arm64)  ARCH='arm64' ;;
    armv7l|armv7)   ARCH='armv7' ;;
    armv6l|armv6)   ARCH='armv6' ;;
    i386|i486|i586|i686) ARCH='386' ;;
    s390x)          ARCH='s390x' ;;
    riscv64)        ARCH='riscv64' ;;
    mips)           ARCH='mips' ;;
    mips64)         ARCH='mips64' ;;
    mips64el)       ARCH='mips64le' ;;
    mipsel)         ARCH='mipsle' ;;
    ppc64le)        ARCH='ppc64le' ;;
    *) log_error "$(text unsupported_arch): $m"; exit 1 ;;
  esac
}

pkg_install() {
  [ "$#" -eq 0 ] && return 0
  log_info "install: $*"
  case "$PKG_MGR" in
    apt)    apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
    dnf)    dnf install -y -q "$@" ;;
    yum)    yum install -y -q "$@" ;;
    apk)    apk add --no-cache "$@" ;;
    pacman) pacman -Sy --noconfirm --needed "$@" ;;
    *)      return 1 ;;
  esac
}

ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  if ! have_cmd "$cmd"; then
    pkg_install "$pkg" >/dev/null 2>&1 || true
  fi
}

check_dependencies() {
  ensure_cmd curl curl
  if ! have_cmd curl; then
    ensure_cmd wget wget
  fi
  ensure_cmd openssl openssl
  ensure_cmd jq jq
  # qrencode 用于终端二维码，装有则用，装不上降级
  if ! have_cmd qrencode; then
    case "$PKG_MGR" in
      apt) pkg_install qrencode >/dev/null 2>&1 || true ;;
      apk) pkg_install libqrencode-tools >/dev/null 2>&1 || pkg_install qrencode >/dev/null 2>&1 || true ;;
      *)   pkg_install qrencode >/dev/null 2>&1 || true ;;
    esac
  fi
}

# 探测公网 IP / Detect public IP
detect_server_ip() {
  local ip='' url
  for url in 'https://api.ip.sb/ip' 'https://ifconfig.me/ip' 'https://ipinfo.io/ip'; do
    ip="$(fetch_text "$url" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] && [ -n "$ip" ]; then
      printf '%s' "$ip"; return 0
    fi
  done
  return 1
}

# 域名是否解析到本机 / Does domain resolve to this host
domain_points_here() {
  local domain="$1" ip="$2" resolved=''
  if have_cmd getent; then
    resolved="$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u)"
  fi
  if [ -z "$resolved" ] && have_cmd nslookup; then
    resolved="$(nslookup "$domain" 2>/dev/null | awk '/^Address: /{print $2}')"
  fi
  if [ -z "$resolved" ]; then
    return 0  # 无法解析时放行，交给 acme 判定
  fi
  printf '%s\n' "$resolved" | grep -qxF "$ip" && return 0
  printf '%s\n' "$resolved" | grep -q '127.0.0.1' && return 1
  # 解析出多个地址时，任一匹配即可
  printf '%s\n' "$resolved" | grep -qxF "$ip"
}

# 生成本机自签占位证书（无域名时使用）/ Self-signed placeholder
gen_self_signed() {
  local crt="$1" key="$2" cn="${3:-easysb.local}"
  have_cmd openssl || return 1
  mkdir -p "$(dirname "$crt")"
  openssl ecparam -genkey -name prime256v1 -out "$key" >/dev/null 2>&1 || return 1
  openssl req -new -x509 -days 3650 -key "$key" -out "$crt" -subj "/CN=${cn}" >/dev/null 2>&1 || return 1
  return 0
}
