#!/usr/bin/env bash
# =============================================================================
# EasySB — 10-detect.sh
# 环境探测：发行版 / 架构 / 包管理器 / 服务管理器 / 依赖 / IP / DNS / 端口
# 依赖：00-core.sh
# =============================================================================
# shellcheck shell=bash

ESB_OS=""; ESB_OS_ID=""; ESB_OS_LIKE=""; ESB_OS_VER=""; ESB_OS_PRETTY=""
ESB_ARCH=""; ESB_ASSET=""; ESB_PKG=""; ESB_INIT=""; ESB_VIRT="unknown"

detect_os() {
  ESB_OS_ID=""; ESB_OS_LIKE=""; ESB_OS_VER=""; ESB_OS_PRETTY=""
  if [ -r "${ESB_ROOT:-}/etc/os-release" ]; then
    # shellcheck disable=SC1091
    . "${ESB_ROOT:-}/etc/os-release" 2>/dev/null || true
    ESB_OS_ID="${ID:-}"
    ESB_OS_LIKE="${ID_LIKE:-}"
    ESB_OS_VER="${VERSION_ID:-}"
    ESB_OS_PRETTY="${PRETTY_NAME:-${NAME:-}}"
  fi
  [ -n "$ESB_OS_PRETTY" ] || ESB_OS_PRETTY="$(uname -s) $(uname -r)"
  case "$ESB_OS_ID" in
    debian|ubuntu|raspbian|linuxmint|pop|kali|armbian) ESB_OS="debian" ;;
    centos|rhel|rocky|almalinux|fedora|ol|amzn|cloudlinux) ESB_OS="rhel" ;;
    alpine) ESB_OS="alpine" ;;
    arch|manjaro) ESB_OS="arch" ;;
    opensuse*|sles|suse) ESB_OS="suse" ;;
    *)
      case " $ESB_OS_LIKE " in
        *" debian "*) ESB_OS="debian" ;;
        *" rhel "*|*" fedora "*) ESB_OS="rhel" ;;
        *" alpine "*) ESB_OS="alpine" ;;
        *" arch "*) ESB_OS="arch" ;;
        *" suse "*) ESB_OS="suse" ;;
        *) ESB_OS="unknown" ;;
      esac
      ;;
  esac
  return 0
}

detect_pkg() {
  case "$ESB_OS" in
    debian) ESB_PKG="apt" ;;
    rhel)   if cmd_exists dnf; then ESB_PKG="dnf"; else ESB_PKG="yum"; fi ;;
    alpine) ESB_PKG="apk" ;;
    arch)   ESB_PKG="pacman" ;;
    suse)   ESB_PKG="zypper" ;;
    *)      ESB_PKG="unknown" ;;
  esac
  # 兜底：没有包管理器时按可用命令判断
  if [ "$ESB_PKG" = "unknown" ]; then
    if cmd_exists apt-get; then ESB_PKG="apt"
    elif cmd_exists dnf; then ESB_PKG="dnf"
    elif cmd_exists yum; then ESB_PKG="yum"
    elif cmd_exists apk; then ESB_PKG="apk"
    fi
  fi
  return 0
}

detect_arch() {
  local _detect_arch_m
  _detect_arch_m="$(uname -m)"
  case "$_detect_arch_m" in
    x86_64|amd64|x64) ESB_ARCH="amd64" ;;
    aarch64|arm64)    ESB_ARCH="arm64" ;;
    armv7l|armv7)     ESB_ARCH="armv7l" ;;
    armv6l|armv6)     ESB_ARCH="armv6" ;;
    armv5l|armv5*)    ESB_ARCH="armv5l" ;;
    i386|i486|i586|i686|x86) ESB_ARCH="386" ;;
    mips64el|mips64le) ESB_ARCH="mips64le" ;;
    mipsel|mipsle)    ESB_ARCH="mipsel" ;;
    mips64)           ESB_ARCH="mips64" ;;
    mips)             ESB_ARCH="mips" ;;
    riscv64)          ESB_ARCH="riscv64" ;;
    loongarch64|loong64) ESB_ARCH="loong64" ;;
    ppc64le)          ESB_ARCH="ppc64le" ;;
    s390x)            ESB_ARCH="s390x" ;;
    *)                ESB_ARCH="$_detect_arch_m" ;;
  esac
  ESB_ASSET="$(os_arch_to_asset "$ESB_ARCH")"
  return 0
}

# 输出本仓库 releases 资产名中的平台后缀，例如 linux-amd64
os_arch_to_asset() {
  local _os_arch_a="${1:-$ESB_ARCH}" _os_arch_sse=""
  case "$_os_arch_a" in
    amd64)  printf 'linux-amd64\n' ;;
    arm64)  printf 'linux-arm64\n' ;;
    armv7l) printf 'linux-armv7l\n' ;;
    armv6)  printf 'linux-armv6\n' ;;
    armv5l) printf 'linux-armv5l\n' ;;
    loong64) printf 'linux-loong64\n' ;;
    riscv64) printf 'linux-riscv64\n' ;;
    ppc64le) printf 'linux-ppc64le\n' ;;
    s390x)  printf 'linux-s390x\n' ;;
    mips)   printf 'linux-mips\n' ;;
    mips64) printf 'linux-mips64\n' ;;
    mipsel)
      if grep -qm1 -i 'hardfloat' "${ESB_ROOT:-}/proc/cpuinfo" 2>/dev/null; then
        printf 'linux-mipsel-hardfloat\n'
      else
        printf 'linux-mipsel-hardfloat\n'
      fi
      ;;
    mips64le)
      printf 'linux-mips64le-hardfloat\n'
      ;;
    386)
      _os_arch_sse="$(grep -m1 -o 'sse2' "${ESB_ROOT:-}/proc/cpuinfo" 2>/dev/null || true)"
      if [ -n "$_os_arch_sse" ]; then printf 'linux-386-sse2\n'; else printf 'linux-386-softfloat\n'; fi
      ;;
    *) printf 'linux-%s\n' "$_os_arch_a" ;;
  esac
  return 0
}

detect_init() {
  if [ -d "${ESB_ROOT:-}/run/systemd/system" ] || [ "$(cat "${ESB_ROOT:-}/proc/1/comm" 2>/dev/null | tr -d '\r')" = "systemd" ]; then
    ESB_INIT="systemd"
  elif cmd_exists rc-service; then
    ESB_INIT="openrc"
  elif [ -d "${ESB_ROOT:-}/etc/init.d" ]; then
    ESB_INIT="sysvinit"
  else
    ESB_INIT="none"
  fi
  return 0
}

detect_virt() {
  ESB_VIRT="unknown"
  local _dv=""
  if [ -r "${ESB_ROOT:-}/proc/1/environ" ] && tr '\0' '\n' <"${ESB_ROOT:-}/proc/1/environ" 2>/dev/null | grep -qi container; then
    ESB_VIRT="container"
    return 0
  fi
  if cmd_exists systemd-detect-virt; then
    _dv="$(systemd-detect-virt 2>/dev/null | tr -d '\r\n')"
    [ -n "$_dv" ] && [ "$_dv" != "none" ] && ESB_VIRT="$_dv"
  fi
  return 0
}

detect_all() {
  detect_os
  detect_pkg
  detect_arch
  detect_init
  detect_virt
  log_debug "系统=$ESB_OS($ESB_OS_ID $ESB_OS_VER) 架构=$ESB_ARCH 资产=$ESB_ASSET 包管理器=$ESB_PKG 服务=$ESB_INIT 虚拟化=$ESB_VIRT"
  return 0
}

# ---------------------------------------------------------------------------
# 包安装（走 gate）
# ---------------------------------------------------------------------------
os_pkg_install() {
  [ "$#" -gt 0 ] || return 0
  log_info "安装依赖包：$*"
  case "$ESB_PKG" in
    apt)
      run_gate "apt update" env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
      run_gate "apt install" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1
      return $?
      ;;
    dnf|yum)
      run_gate "$ESB_PKG install" "$ESB_PKG" install -y -q "$@" >/dev/null 2>&1
      return $?
      ;;
    apk)
      run_gate "apk add" apk add --no-cache "$@" >/dev/null 2>&1
      return $?
      ;;
    pacman)
      run_gate "pacman -S" pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1
      return $?
      ;;
    zypper)
      run_gate "zypper install" zypper -n install "$@" >/dev/null 2>&1
      return $?
      ;;
    *)
      error "未识别的包管理器（$ESB_OS），请手动安装：$*"
      return 1
      ;;
  esac
}

# 包名映射：不同发行版名字不同
pkg_name_for() {
  case "$1" in
    nginx)
      case "$ESB_OS" in
        debian) printf 'nginx\n' ;;
        rhel) printf 'nginx\n' ;;
        alpine) printf 'nginx\n' ;;
        suse) printf 'nginx\n' ;;
        *) printf 'nginx\n' ;;
      esac
      ;;
    qrencode)
      case "$ESB_OS" in
        debian) printf 'qrencode\n' ;;
        rhel) printf 'qrencode\n' ;;
        alpine) printf 'libqrencode-tools\n' ;;
        *) printf 'qrencode\n' ;;
      esac
      ;;
    socat) printf 'socat\n' ;;
    cron)
      case "$ESB_OS" in
        debian) printf 'cron\n' ;;
        alpine) printf 'busybox-initscripts\n' ;;
        *) printf 'cronie\n' ;;
      esac
      ;;
    *) printf '%s\n' "$1" ;;
  esac
  return 0
}

deps_required_list() { printf 'jq curl tar openssl\n'; }
deps_optional_list() { printf 'qrencode socat nginx unzip\n'; }

# 检查必需依赖；缺失时列出并按需安装
deps_check() {
  local _deps_missing="" _deps_c _deps_pkg_list=""
  for _deps_c in $(deps_required_list); do
    if ! cmd_exists "$_deps_c"; then
      _deps_missing="$_deps_missing $_deps_c"
      _deps_pkg_list="$_deps_pkg_list $(pkg_name_for "$_deps_c")"
    fi
  done
  if [ -z "$_deps_missing" ]; then
    log_debug "必需依赖齐备"
    return 0
  fi
  log_warn "缺少必需依赖：$_deps_missing"
  if [ "${ESB_GATE:-0}" = "1" ] || [ "${ESB_NO_INSTALL:-0}" = "1" ]; then
    return 1
  fi
  if ask_yesno "是否现在自动安装（$(trim "$_deps_pkg_list")）？" y; then
    # shellcheck disable=SC2086
    os_pkg_install $_deps_pkg_list || { error "依赖安装失败，请手动安装后重试"; return 1; }
    for _deps_c in $(deps_required_list); do
      cmd_exists "$_deps_c" || { error "依赖仍缺失：$_deps_c"; return 1; }
    done
    log_ok "依赖安装完成"
    return 0
  fi
  error "请先安装缺失依赖：$_deps_missing"
  return 1
}

deps_install() {
  local _deps_install_pkgs=""
  local _deps_install_c
  for _deps_install_c in "$@"; do
    _deps_install_pkgs="$_deps_install_pkgs $(pkg_name_for "$_deps_install_c")"
  done
  # shellcheck disable=SC2086
  os_pkg_install $_deps_install_pkgs
}

# ---------------------------------------------------------------------------
# IP / DNS
# ---------------------------------------------------------------------------
detect_public_ip() {
  local _dpi_url _dpi_ip="" _dpi_tmp
  if [ -n "${ESB_PUBLIC_IP_CACHE:-}" ]; then printf '%s\n' "$ESB_PUBLIC_IP_CACHE"; return 0; fi
  if [ "${ESB_OFFLINE:-0}" = "1" ]; then printf '\n'; return 0; fi
  for _dpi_url in \
      "https://api.ipify.org" \
      "https://ipv4.icanhazip.com" \
      "https://ifconfig.me/ip" \
      "https://ipinfo.io/ip"; do
    _dpi_ip="$(curl -4 -fsS --connect-timeout 6 --max-time 10 "$_dpi_url" 2>/dev/null | tr -d '[:space:]')"
    case "$_dpi_ip" in
      *[!0-9.]*|'') _dpi_ip="" ;;
      *) printf '%s\n' "$_dpi_ip"; return 0 ;;
    esac
  done
  # 兜底：本机第一个非回环 IPv4
  _dpi_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)"
  printf '%s\n' "$_dpi_ip"
  return 0
}

detect_local_ips() {
  local _dli_ips=""
  if cmd_exists ip; then
    _dli_ips="$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' | tr '\n' ' ')"
  elif cmd_exists ifconfig; then
    _dli_ips="$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | tr '\n' ' ')"
  elif cmd_exists hostname; then
    _dli_ips="$(hostname -I 2>/dev/null | tr '\n' ' ')"
  fi
  printf '%s\n' "$(trim "$_dli_ips")"
  return 0
}

# 0=解析到本机 1=解析但指向别处 2=解析失败 3=无解析工具
domain_resolves_to() {
  local _drt_domain="$1" _drt_ips="" _drt_tool=""
  [ -n "$_drt_domain" ] || return 2
  if cmd_exists dig; then
    _drt_tool="dig"
    _drt_ips="$(dig +short A "$_drt_domain" 2>/dev/null | grep -E '^[0-9.]+$' | tr '\n' ' ')"
  elif cmd_exists host; then
    _drt_tool="host"
    _drt_ips="$(host -t A "$_drt_domain" 2>/dev/null | grep -oE 'address [0-9.]+' | awk '{print $2}' | tr '\n' ' ')"
  elif cmd_exists getent; then
    _drt_tool="getent"
    _drt_ips="$(getent ahostsv4 "$_drt_domain" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
  elif cmd_exists nslookup; then
    _drt_tool="nslookup"
    _drt_ips="$(nslookup "$_drt_domain" 2>/dev/null | awk '/^Address: /{print $2}' | tr '\n' ' ')"
  else
    log_debug "无 DNS 查询工具，跳过域名校验"
    return 3
  fi
  [ -n "$_drt_ips" ] || return 2
  local _drt_ip _drt_local
  _drt_local=" $(detect_local_ips) ${ESB_PUBLIC_IP:-} "
  for _drt_ip in $_drt_ips; do
    case "$_drt_local" in *" $_drt_ip "*) return 0 ;; esac
  done
  log_debug "域名 $_drt_domain 解析为：$_drt_ips（本地：$_drt_local）"
  return 1
}

port_in_use() {
  local _piu_port="$1" _piu_proto="${2:-tcp}" _piu_out=""
  if cmd_exists ss; then
    if [ "$_piu_proto" = "udp" ]; then
      _piu_out="$(ss -H -lnu 2>/dev/null | awk '{print $4}' | grep -E "[:.]${_piu_port}\$")"
    else
      _piu_out="$(ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -E "[:.]${_piu_port}\$")"
    fi
  elif cmd_exists netstat; then
    if [ "$_piu_proto" = "udp" ]; then
      _piu_out="$(netstat -lnu 2>/dev/null | awk '{print $4}' | grep -E "[:.]${_piu_port}\$")"
    else
      _piu_out="$(netstat -lnt 2>/dev/null | awk '{print $4}' | grep -E "[:.]${_piu_port}\$")"
    fi
  elif cmd_exists lsof; then
    _piu_out="$(lsof -i "${_piu_proto}:${_piu_port}" -sTCP:LISTEN 2>/dev/null | tail -n +2)"
  else
    return 1
  fi
  [ -n "$_piu_out" ]
}

# ---------------------------------------------------------------------------
# 服务管理器兼容层
# ---------------------------------------------------------------------------
service_mgr() {
  local _sm_name="$1" _sm_action="$2"
  # 兜底：调用方可能没有先跑 detect_all（例如库被单独 source），
  # 此时 ESB_INIT 为空，会被误判成"本机没有服务管理器"
  [ -n "${ESB_INIT:-}" ] || detect_init
  case "$ESB_INIT" in
    systemd)
      case "$_sm_action" in
        status)  run_gate "systemctl status $_sm_name" systemctl is-active "$_sm_name" >/dev/null 2>&1 ;;
        start)   run_gate "systemctl start $_sm_name" systemctl start "$_sm_name" ;;
        stop)    run_gate "systemctl stop $_sm_name" systemctl stop "$_sm_name" ;;
        restart) run_gate "systemctl restart $_sm_name" systemctl restart "$_sm_name" ;;
        reload)  run_gate "systemctl reload $_sm_name" systemctl reload "$_sm_name" ;;
        enable)  run_gate "systemctl enable $_sm_name" systemctl enable "$_sm_name" >/dev/null 2>&1 ;;
        disable) run_gate "systemctl disable $_sm_name" systemctl disable "$_sm_name" >/dev/null 2>&1 ;;
        *) error "未知的服务动作：$_sm_action"; return 1 ;;
      esac
      return $?
      ;;
    openrc)
      case "$_sm_action" in
        status)  run_gate "rc-service status" rc-service "$_sm_name" status >/dev/null 2>&1 ;;
        start)   run_gate "rc-service start" rc-service "$_sm_name" start ;;
        stop)    run_gate "rc-service stop" rc-service "$_sm_name" stop ;;
        restart) run_gate "rc-service restart" rc-service "$_sm_name" restart ;;
        reload)  run_gate "rc-service reload" rc-service "$_sm_name" reload ;;
        enable)  run_gate "rc-update add" rc-update add "$_sm_name" default ;;
        disable) run_gate "rc-update del" rc-update del "$_sm_name" default ;;
        *) error "未知的服务动作：$_sm_action"; return 1 ;;
      esac
      return $?
      ;;
    *)
      if [ -x "${ESB_ROOT:-}/etc/init.d/$_sm_name" ]; then
        run_gate "/etc/init.d/$_sm_name $_sm_action" "${ESB_ROOT}/etc/init.d/$_sm_name" "$_sm_action"
        return $?
      fi
      error "本机没有可用的服务管理器（systemd/openrc 均不存在）"
      return 1
      ;;
  esac
}
