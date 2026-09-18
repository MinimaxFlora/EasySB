#!/usr/bin/env bash
# =============================================================================
# EasySB — 单文件一键部署脚本（入口）
#   bash <(curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/EasySB/master/EasySB/dist/easysb.sh)
#   或：wget -O easysb.sh <同上 URL> && bash easysb.sh
# 功能：一键部署 sing-box（AnyTLS / Hysteria2 / VLESS-Vision-REALITY /
#       VMess-WebSocket-TLS / TUIC），强制域名部署 + ACME 证书管理 +
#       伪装站点 + 内核与脚本更新。
# =============================================================================
set -u

ESB_SCRIPT_VERSION="1.0.0"
ESB_SELF="${BASH_SOURCE[0]:-}"
ESB_SCRIPT_DIR=""
if [ -n "$ESB_SELF" ] && [ -f "$ESB_SELF" ]; then
  ESB_SCRIPT_DIR="$(cd "$(dirname "$ESB_SELF")" 2>/dev/null && pwd || true)"
fi

# ---------------------------------------------------------------------------
# 路径模型：全部挂在 ESB_ROOT 之下（为空即真实绝对路径，沙箱测试时可前缀）
# ---------------------------------------------------------------------------
ESB_ROOT="${ESB_ROOT:-}"
ESB_DIR="${ESB_ROOT}/etc/easysb"
ESB_STATE="${ESB_DIR}/state.json"
ESB_LOG="${ESB_DIR}/easysb.log"
ESB_SECRET_DIR="${ESB_DIR}/secrets"
ESB_CLIENT_DIR="${ESB_DIR}/client"
ESB_CONF_DIR="${ESB_ROOT}/etc/sing-box"
ESB_CONFIG="${ESB_CONF_DIR}/config.json"
ESB_CERT_DIR="${ESB_CONF_DIR}/certs"
ESB_BIN="${ESB_ROOT}/usr/bin/sing-box"
ESB_UNIT_DIR="${ESB_ROOT}/usr/lib/systemd/system"
ESB_STATE_DIR="${ESB_ROOT}/var/lib/sing-box"
ESB_BACKUP_DIR="${ESB_ROOT}/var/backups/easysb"
ESB_WEB_ROOT="${ESB_ROOT}/var/www/easysb"
ESB_NGINX_CONF="${ESB_ROOT}/etc/nginx/conf.d/easysb.conf"
ESB_LOCK_DIR=""

usage() {
  cat <<'EOF'
EasySB —— sing-box 一键部署管理脚本

用法：
  easysb.sh                 进入交互式管理面板（推荐）
  easysb.sh install         直接进入部署向导
  easysb.sh status          查看运行状态
  easysb.sh uninstall       卸载
  easysb.sh --version       显示脚本版本
  easysb.sh --help          显示帮助

环境变量：
  ESB_ROOT=<dir>            沙箱根目录（测试用，正常使用不要设置）
  ESB_GATE=1                预演模式：所有系统变更只记录不执行（--dry-run）
  ESB_OFFLINE=1             离线：不发起任何下载
  ESB_NO_COLOR=1            禁用颜色
  ESB_ASSUME_YES=1          非交互模式下所有确认按默认值通过

支持协议：VLESS-Vision-REALITY / VMess-WebSocket-TLS /
          Hysteria2 / TUIC v5 / AnyTLS（可多选，默认全部）
内核与脚本更新来源：https://github.com/MinimaxFlora/EasySB
EOF
}

# ---------------------------------------------------------------------------
# 模块加载（单文件版由 build.sh 内联，不再走这里）
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 以下模块由 build.sh 自动内联（源码位于 EasySB/lib/）
# ---------------------------------------------------------------------------

# ===== 内联模块：lib/00-core.sh =====
#!/usr/bin/env bash
# =============================================================================
# EasySB — 00-core.sh
# 基础层：颜色 / 日志 / 交互 / 校验 / 锁 / 变更门禁 / 密钥生成 / HTTP
# 本文件不得依赖其它模块（除 20-state.sh 之外的文件也不得依赖本文件以外的东西）
# =============================================================================
# shellcheck shell=bash

ESB_TTY=0
C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""
C_BLUE=""; C_CYAN=""; C_MAGENTA=""; C_WHITE=""

# ---------------------------------------------------------------------------
# 颜色与 TTY
# ---------------------------------------------------------------------------
esb_color_init() {
  ESB_TTY=0
  if [ -t 1 ] && [ -t 0 ]; then ESB_TTY=1; fi
  if [ "${TERM:-dumb}" = "dumb" ] || [ -n "${NO_COLOR:-}" ] || [ "${ESB_NO_COLOR:-0}" = "1" ]; then
    ESB_TTY=0
  fi
  if [ "$ESB_TTY" = "1" ]; then
    C_RESET=$'\033[0m';  C_BOLD=$'\033[1m';    C_DIM=$'\033[2m'
    C_RED=$'\033[31m';   C_GREEN=$'\033[32m';  C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m';  C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
    C_WHITE=$'\033[37m'
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
esb_log_open() {
  [ -n "${ESB_LOG:-}" ] || return 0
  mkdir -p "$(dirname "$ESB_LOG")" 2>/dev/null || true
  touch "$ESB_LOG" 2>/dev/null || true
  chmod 600 "$ESB_LOG" 2>/dev/null || true
  return 0
}

esb_log_raw() {
  [ -n "${ESB_LOG:-}" ] || return 0
  # 用分组重定向包住：日志目录不存在时 bash 的"重定向失败"提示也会被吞掉，
  # 否则用户在首次运行时会看到一行莫名其妙的 "…/easysb.log: No such file or directory"
  { printf '%s %s\n' "$(esb_now)" "$*" >>"$ESB_LOG"; } 2>/dev/null || true
  return 0
}

log_info()  { printf '%s[信息]%s %s\n'   "$C_CYAN"   "$C_RESET" "$*"; esb_log_raw "[INFO] $*"; return 0; }
log_ok()    { printf '%s[完成]%s %s\n'   "$C_GREEN"  "$C_RESET" "$*"; esb_log_raw "[ OK ] $*"; return 0; }
log_warn()  { printf '%s[警告]%s %s\n'   "$C_YELLOW" "$C_RESET" "$*" >&2; esb_log_raw "[WARN] $*"; return 0; }
log_err()   { printf '%s[错误]%s %s\n'   "$C_RED"    "$C_RESET" "$*" >&2; esb_log_raw "[FAIL] $*"; return 0; }
log_debug() {
  [ "${ESB_DEBUG:-0}" = "1" ] || return 0
  printf '%s[调试]%s %s\n' "$C_DIM" "$C_RESET" "$*"
  esb_log_raw "[DBG ] $*"
  return 0
}

# 致命错误：仅用于不可恢复状态
die() { log_err "$*"; esb_log_raw "[EXIT] $*"; exit 1; }
# 普通错误：返回值语义，UI 可继续
error() { log_err "$*"; return 1; }

# ---------------------------------------------------------------------------
# UI 小工具
# ---------------------------------------------------------------------------
ui_hr()    { printf '%s\n' "────────────────────────────────────────────────"; return 0; }
ui_blank() { printf '\n'; return 0; }
ui_title() { ui_blank; ui_hr; printf ' %s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; ui_hr; return 0; }
ui_kv()    { printf '  %-18s %s\n' "$1" "$2"; return 0; }
ui_step()  { ui_blank; printf '%s➜ %s%s\n' "$C_BLUE" "$*" "$C_RESET"; return 0; }

pause() {
  [ "${ESB_NO_PAUSE:-0}" = "1" ] && return 0
  [ "$ESB_TTY" = "1" ] || return 0
  printf '%s按回车返回…%s' "$C_DIM" "$C_RESET"
  IFS= read -r _pause_ignore || true
  return 0
}

# ---------------------------------------------------------------------------
# 原子写文件
# ---------------------------------------------------------------------------
json_write() {
  local _json_write_file="$1" _json_write_mode="${2:-600}" _json_write_tmp
  _json_write_tmp="${_json_write_file}.tmp.$$"
  mkdir -p "$(dirname "$_json_write_file")" 2>/dev/null || return 1
  cat >"$_json_write_tmp" || { rm -f "$_json_write_tmp"; return 1; }
  chmod "$_json_write_mode" "$_json_write_tmp" 2>/dev/null || true
  mv -f "$_json_write_tmp" "$_json_write_file" || { rm -f "$_json_write_tmp"; return 1; }
  return 0
}

# 普通文本文件原子写（不强制 600）
file_write() {
  local _file_write_file="$1" _file_write_mode="${2:-644}"
  json_write "$_file_write_file" "$_file_write_mode"
}

# ---------------------------------------------------------------------------
# 交互（全部可用管道驱动；内部变量一律带函数名前缀避免动态作用域冲突）
# ---------------------------------------------------------------------------
ask_input() {
  local _ask_input_out="$1" _ask_input_prompt="$2" _ask_input_def="${3-}" _ask_input_val=""
  if [ -n "$_ask_input_def" ]; then
    printf '%s %s[%s]%s: ' "$_ask_input_prompt" "$C_DIM" "$_ask_input_def" "$C_RESET"
  else
    printf '%s: ' "$_ask_input_prompt"
  fi
  # read 失败(EOF) 时置位 ESB_INPUT_EOF：调用方的重试循环必须据此退出，
  # 否则"stdin 被管道喂完了"会变成一个无限循环（用户看到的是刷屏报错）
  IFS= read -r _ask_input_val || { _ask_input_val=""; ESB_INPUT_EOF=1; }
  _ask_input_val="${_ask_input_val%$'\r'}"
  if [ -z "$_ask_input_val" ]; then _ask_input_val="$_ask_input_def"; fi
  eval "$_ask_input_out=\$_ask_input_val"
  return 0
}

# 非交互且输入已耗尽（重试循环里用）
esb_input_exhausted() {
  [ "${ESB_INPUT_EOF:-0}" = "1" ]
}

ask_secret() {
  local _ask_secret_out="$1" _ask_secret_prompt="$2" _ask_secret_val=""
  printf '%s: ' "$_ask_secret_prompt"
  if [ "$ESB_TTY" = "1" ]; then
    IFS= read -rs _ask_secret_val || _ask_secret_val=""
    printf '\n'
  else
    IFS= read -r _ask_secret_val || _ask_secret_val=""
  fi
  _ask_secret_val="${_ask_secret_val%$'\r'}"
  eval "$_ask_secret_out=\$_ask_secret_val"
  return 0
}

# ask_yesno <prompt> [y|n]  → 0=yes
ask_yesno() {
  local _ask_yesno_prompt="$1" _ask_yesno_def="${2:-n}" _ask_yesno_val="" _ask_yesno_hint="[y/N]"
  [ "$_ask_yesno_def" = "y" ] && _ask_yesno_hint="[Y/n]"
  if [ "${ESB_ASSUME_YES:-0}" = "1" ] && [ ! -t 0 ]; then
    log_debug "非交互且 ESB_ASSUME_YES=1，自动选择默认值 $_ask_yesno_def"
    [ "$_ask_yesno_def" = "y" ] && return 0
    return 1
  fi
  printf '%s %s: ' "$_ask_yesno_prompt" "$_ask_yesno_hint"
  IFS= read -r _ask_yesno_val || _ask_yesno_val=""
  _ask_yesno_val="${_ask_yesno_val%$'\r'}"
  [ -z "$_ask_yesno_val" ] && _ask_yesno_val="$_ask_yesno_def"
  case "$_ask_yesno_val" in
    y|Y|yes|YES|Yes|是) return 0 ;;
    *) return 1 ;;
  esac
}

# ask_single <outvar> <prompt> <"key|label" ...>  → outvar=key
ask_single() {
  local _ask_single_out="$1" _ask_single_prompt="$2"; shift 2
  local _ask_single_i=1 _ask_single_item _ask_single_key _ask_single_label _ask_single_val
  local _ask_single_keys="" _ask_single_pick
  printf '%s\n' "$_ask_single_prompt"
  for _ask_single_item in "$@"; do
    _ask_single_key="${_ask_single_item%%|*}"
    _ask_single_label="${_ask_single_item#*|}"
    printf '  %s%2d)%s %s\n' "$C_CYAN" "$_ask_single_i" "$C_RESET" "$_ask_single_label"
    _ask_single_keys="$_ask_single_keys $_ask_single_key"
    _ask_single_i=$((_ask_single_i + 1))
  done
  printf '%s请选择 [1]: %s' "$C_DIM" "$C_RESET"
  IFS= read -r _ask_single_pick || _ask_single_pick=""
  _ask_single_pick="${_ask_single_pick%$'\r'}"
  case "$_ask_single_pick" in
    ''|*[!0-9]*) _ask_single_pick=1 ;;
  esac
  _ask_single_val=$(printf '%s\n' $_ask_single_keys | sed -n "${_ask_single_pick}p")
  if [ -z "$_ask_single_val" ]; then
    _ask_single_val="${1%%|*}"
    log_warn "输入无效，使用第一个选项：$_ask_single_val"
  fi
  eval "$_ask_single_out=\$_ask_single_val"
  return 0
}

# ask_multi <outvar> <prompt> <"key|label|on|off" ...>  → outvar="k1 k2"
# 输入：all/a=全选，none/0=全不选，1,3,5 组合，回车=默认（标 on 的）
ask_multi() {
  local _ask_multi_out="$1" _ask_multi_prompt="$2"; shift 2
  local _ask_multi_i=1 _ask_multi_item _ask_multi_key _ask_multi_label _ask_multi_def
  local _ask_multi_res="" _ask_multi_all="" _ask_multi_pick _ask_multi_tok
  printf '%s\n' "$_ask_multi_prompt"
  for _ask_multi_item in "$@"; do
    _ask_multi_key="${_ask_multi_item%%|*}"
    _ask_multi_rest="${_ask_multi_item#*|}"
    _ask_multi_def="${_ask_multi_rest##*|}"
    if [ "$_ask_multi_def" = "$_ask_multi_rest" ]; then
      _ask_multi_def="off"
      _ask_multi_label="$_ask_multi_rest"
    else
      _ask_multi_label="${_ask_multi_rest%|*}"
    fi
    _ask_multi_all="$_ask_multi_all $_ask_multi_key"
    if [ "$_ask_multi_def" = "on" ]; then
      _ask_multi_res="$_ask_multi_res $_ask_multi_key"
      printf '  %s%2d)%s %s %s[默认选中]%s\n' "$C_CYAN" "$_ask_multi_i" "$C_RESET" "$_ask_multi_label" "$C_GREEN" "$C_RESET"
    else
      printf '  %s%2d)%s %s\n' "$C_CYAN" "$_ask_multi_i" "$C_RESET" "$_ask_multi_label"
    fi
    _ask_multi_i=$((_ask_multi_i + 1))
  done
  printf '%s可输入 all / none / 序号(如 1,3) ,回车=默认%s\n' "$C_DIM" "$C_RESET"
  printf '选择: '
  IFS= read -r _ask_multi_pick || _ask_multi_pick=""
  _ask_multi_pick="${_ask_multi_pick%$'\r'}"
  case "$_ask_multi_pick" in
    '') ;;
    all|ALL|a|A) _ask_multi_res="$_ask_multi_all" ;;
    none|NONE|n|0) _ask_multi_res="" ;;
    *)
      _ask_multi_res=""
      for _ask_multi_tok in $(printf '%s' "$_ask_multi_pick" | tr ',' ' '); do
        case "$_ask_multi_tok" in
          *[!0-9]*) continue ;;
        esac
        _ask_multi_key=$(printf '%s\n' $_ask_multi_all | sed -n "${_ask_multi_tok}p")
        [ -n "$_ask_multi_key" ] && _ask_multi_res="$_ask_multi_res $_ask_multi_key"
      done
      ;;
  esac
  _ask_multi_res="$(trim "$_ask_multi_res")"
  eval "$_ask_multi_out=\$_ask_multi_res"
  return 0
}

# 危险操作确认（要求输入 yes）
esb_confirm_or_die() {
  local _esb_confirm_prompt="$1"
  if [ "${ESB_ASSUME_YES:-0}" = "1" ] && [ ! -t 0 ]; then
    log_warn "$_esb_confirm_prompt —— 非交互模式自动确认"
    return 0
  fi
  if ask_yesno "$_esb_confirm_prompt" n; then return 0; fi
  log_info "已取消"
  return 1
}

# ---------------------------------------------------------------------------
# 校验（永远返回状态，不 exit）
# ---------------------------------------------------------------------------
validate_domain() {
  local _validate_domain_d="${1-}"
  if [ -z "$_validate_domain_d" ]; then error "域名不能为空"; return 1; fi
  if [ ${#_validate_domain_d} -gt 253 ]; then error "域名过长（>253）"; return 1; fi
  case "$_validate_domain_d" in
    *[!a-zA-Z0-9.-]*) error "域名含非法字符：$_validate_domain_d"; return 1 ;;
    .*|*.) error "域名不能以点开头或结尾"; return 1 ;;
    *..*) error "域名不能包含连续的点"; return 1 ;;
  esac
  if ! printf '%s' "$_validate_domain_d" | grep -Eq '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
    error "域名格式不正确：$_validate_domain_d"
    return 1
  fi
  return 0
}

validate_email() {
  local _validate_email_e="${1-}"
  [ -n "$_validate_email_e" ] || { error "邮箱不能为空"; return 1; }
  printf '%s' "$_validate_email_e" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' \
    || { error "邮箱格式不正确：$_validate_email_e"; return 1; }
  return 0
}

validate_port() {
  local _validate_port_p="${1-}"
  case "$_validate_port_p" in
    ''|*[!0-9]*) error "端口必须是数字：$_validate_port_p"; return 1 ;;
  esac
  if [ "$_validate_port_p" -lt 1 ] || [ "$_validate_port_p" -gt 65535 ]; then
    error "端口超出范围(1-65535)：$_validate_port_p"; return 1
  fi
  return 0
}

# 接受 2080-3000 或 2080:3000，规范化输出 "2080-3000"
validate_port_range() {
  local _vpr_r="${1-}" _vpr_a _vpr_b
  _vpr_r="$(printf '%s' "$_vpr_r" | tr ':' '-')"
  case "$_vpr_r" in
    *-*) ;;
    *) error "端口范围格式应为 起始-结束：$_vpr_r"; return 1 ;;
  esac
  _vpr_a="${_vpr_r%%-*}"
  _vpr_b="${_vpr_r##*-}"
  validate_port "$_vpr_a" || return 1
  validate_port "$_vpr_b" || return 1
  if [ "$_vpr_a" -ge "$_vpr_b" ]; then error "端口范围起始必须小于结束：$_vpr_r"; return 1; fi
  printf '%s-%s\n' "$_vpr_a" "$_vpr_b"
  return 0
}

# ---------------------------------------------------------------------------
# 并发锁
# ---------------------------------------------------------------------------
esb_lock() {
  local _esb_lock_file="${ESB_DIR:-/tmp}/.lock"
  mkdir -p "$(dirname "$_esb_lock_file")" 2>/dev/null || true
  if cmd_exists flock; then
    exec 9>"$_esb_lock_file" 2>/dev/null || return 0
    if ! flock -n 9; then error "另一个 EasySB 实例正在运行，请稍后再试"; return 1; fi
    return 0
  fi
  if mkdir "${_esb_lock_file}.d" 2>/dev/null; then
    ESB_LOCK_DIR="${_esb_lock_file}.d"
    return 0
  fi
  error "另一个 EasySB 实例正在运行（${_esb_lock_file}.d 已存在）"
  return 1
}

esb_unlock() {
  if [ -n "${ESB_LOCK_DIR:-}" ]; then
    rmdir "$ESB_LOCK_DIR" 2>/dev/null || true
    ESB_LOCK_DIR=""
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 变更门禁：所有系统变更类命令的唯一入口
#   ESB_GATE=1 时只记录不执行（沙箱/--dry-run）
# ---------------------------------------------------------------------------
run_gate() {
  local _run_gate_desc="$1"; shift
  if [ "${ESB_GATE:-0}" = "1" ]; then
    printf '%s\t%s\n' "$_run_gate_desc" "$*" >>"${ESB_GATE_LOG:-/dev/null}" 2>/dev/null || true
    log_debug "[gate] $_run_gate_desc: $*"
    return 0
  fi
  log_debug "[exec] $_run_gate_desc: $*"
  "$@"
}

# 读取类命令（不改变系统）用这个包装，沙箱里走 stub
run_ro() { "$@"; }

# ---------------------------------------------------------------------------
# 临时目录
# ---------------------------------------------------------------------------
esb_tmp_init() {
  ESB_TMP="${ESB_TMP:-${TMPDIR:-/tmp}/easysb.$$}"
  mkdir -p "$ESB_TMP" || return 1
  return 0
}

esb_tmp_clean() {
  [ -n "${ESB_TMP:-}" ] || return 0
  rm -rf "$ESB_TMP" 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
cmd_exists() {
  local _cmd_exists_c
  for _cmd_exists_c in "$@"; do
    command -v "$_cmd_exists_c" >/dev/null 2>&1 || return 1
  done
  return 0
}

jq_ok() { cmd_exists jq; }

trim() { printf '%s' "${1-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\r$//'; }

# 把状态里保存的"生产绝对路径"按沙箱前缀还原：ESB_ROOT 为空时原样返回。
# state.json 里存的是真实机器上的路径（/var/www/...），沙箱测试必须经此转换，
# 否则会把文件真的写到 /var/www 下（而且原生程序如 jq.exe/nginx 根本打不开 MSYS 风格路径）。
esb_rooted() {
  local _esb_rooted_p="${1-}"
  [ -n "$_esb_rooted_p" ] || return 0
  if [ -n "${ESB_ROOT:-}" ] && [ "${_esb_rooted_p#/}" != "$_esb_rooted_p" ]; then
    printf '%s\n' "${ESB_ROOT}${_esb_rooted_p}"
    return 0
  fi
  printf '%s\n' "$_esb_rooted_p"
  return 0
}

esb_now() { date '+%Y-%m-%d %H:%M:%S'; }
esb_ts()  { date '+%Y%m%d_%H%M%S'; }

mask_secret() {
  local _mask_secret_s="${1-}"
  if [ ${#_mask_secret_s} -le 8 ]; then
    printf '********\n'
  else
    printf '%s********%s\n' "${_mask_secret_s:0:4}" "${_mask_secret_s: -4}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 密钥生成
# ---------------------------------------------------------------------------
_b64url() { base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='; }

gen_uuid() {
  if cmd_exists uuidgen; then
    uuidgen | tr 'A-Z' 'a-z'
    return 0
  fi
  if [ -r /proc/sys/kernel/random/uuid ]; then
    tr 'A-Z' 'a-z' </proc/sys/kernel/random/uuid | tr -d '\r\n'
    printf '\n'
    return 0
  fi
  local _gen_uuid_h
  _gen_uuid_h="$(openssl rand -hex 16)"
  printf '%s-%s-4%s-a%s-%s\n' \
    "${_gen_uuid_h:0:8}" "${_gen_uuid_h:8:4}" "${_gen_uuid_h:13:3}" \
    "${_gen_uuid_h:17:3}" "${_gen_uuid_h:20:12}"
  return 0
}

gen_hex() {
  local _gen_hex_n="${1:-8}"
  openssl rand -hex "$_gen_hex_n" | tr -d '\r\n'
  printf '\n'
  return 0
}

# 生成一个适用于 hysteria2/anytls 的强密码（base64url，无填充）
gen_secret() {
  local _gen_secret_n="${1:-16}"
  openssl rand -base64 "$_gen_secret_n" 2>/dev/null | tr -d '\r\n=' | tr '+/' '-_'
  printf '\n'
  return 0
}

# 输出 "私钥 公钥"（base64url，无填充，符合 sing-box REALITY 规范）
reality_keypair() {
  if [ -n "${ESB_BIN:-}" ] && [ -x "${ESB_BIN}" ] && [ "${ESB_GATE:-0}" != "1" ]; then
    local _reality_keypair_out
    if _reality_keypair_out="$("$ESB_BIN" generate reality-keypair 2>/dev/null)"; then
      local _reality_keypair_priv _reality_keypair_pub
      _reality_keypair_priv="$(printf '%s\n' "$_reality_keypair_out" | awk -F': *' '/PrivateKey/{print $2}' | tr -d '\r')"
      _reality_keypair_pub="$(printf '%s\n' "$_reality_keypair_out" | awk -F': *' '/PublicKey/{print $2}' | tr -d '\r')"
      if [ -n "$_reality_keypair_priv" ] && [ -n "$_reality_keypair_pub" ]; then
        printf '%s %s\n' "$_reality_keypair_priv" "$_reality_keypair_pub"
        return 0
      fi
    fi
  fi
  # openssl x25519 兜底（sing-box 使用 RawURLEncoding）
  local _reality_keypair_pem _reality_keypair_priv="" _reality_keypair_pub=""
  _reality_keypair_pem="$(openssl genpkey -algorithm X25519 2>/dev/null)"
  [ -n "$_reality_keypair_pem" ] || { error "无法生成 X25519 密钥（缺 openssl）"; return 1; }
  _reality_keypair_priv="$(printf '%s\n' "$_reality_keypair_pem" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | _b64url)"
  _reality_keypair_pub="$(printf '%s\n' "$_reality_keypair_pem" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | _b64url)"
  if [ -z "$_reality_keypair_priv" ] || [ -z "$_reality_keypair_pub" ]; then
    error "X25519 密钥生成失败"
    return 1
  fi
  printf '%s %s\n' "$_reality_keypair_priv" "$_reality_keypair_pub"
  return 0
}

sha256_of() {
  [ -f "${1-}" ] || return 1
  local _sha256_of_out=""
  _sha256_of_out="$(sha256sum "$1" 2>/dev/null | grep -oE '[0-9a-fA-F]{64}' | head -1)"
  if [ -z "$_sha256_of_out" ]; then
    _sha256_of_out="$(shasum -a 256 "$1" 2>/dev/null | grep -oE '[0-9a-fA-F]{64}' | head -1)"
  fi
  if [ -z "$_sha256_of_out" ]; then
    _sha256_of_out="$(openssl dgst -sha256 "$1" 2>/dev/null | grep -oE '[0-9a-fA-F]{64}' | head -1)"
  fi
  [ -n "$_sha256_of_out" ] || return 1
  printf '%s\n' "$(printf '%s' "$_sha256_of_out" | tr 'A-F' 'a-f')"
  return 0
}

# ---------------------------------------------------------------------------
# HTTP（尊重 ESB_OFFLINE / 代理）
# ---------------------------------------------------------------------------
http_get() {
  local _http_get_url="$1" _http_get_out="$2"
  if [ "${ESB_OFFLINE:-0}" = "1" ]; then
    log_debug "[offline] 跳过下载：$_http_get_url"
    return 1
  fi
  if cmd_exists curl; then
    curl -fsSL --connect-timeout 15 --retry 2 -o "$_http_get_out" "$_http_get_url"
    return $?
  fi
  if cmd_exists wget; then
    wget -q -O "$_http_get_out" "$_http_get_url"
    return $?
  fi
  error "缺少 curl/wget，无法下载"
  return 1
}

http_json() {
  local _http_json_url="$1"
  if [ "${ESB_OFFLINE:-0}" = "1" ]; then return 1; fi
  if cmd_exists curl; then
    curl -fsSL --connect-timeout 15 --retry 2 "$_http_json_url" 2>/dev/null
    return $?
  fi
  if cmd_exists wget; then
    wget -q -O - "$_http_json_url" 2>/dev/null
    return $?
  fi
  return 1
}

http_head_ok() {
  local _http_head_url="$1"
  if [ "${ESB_OFFLINE:-0}" = "1" ]; then return 1; fi
  if cmd_exists curl; then
    curl -fsSIL --connect-timeout 10 -o /dev/null -w '%{http_code}' "$_http_head_url" 2>/dev/null | grep -q '^[23]'
    return $?
  fi
  return 1
}

# ---------------------------------------------------------------------------
# 路径模型（兜底）：模块被单独 source（没有经过入口脚本）时也能拿到完整路径。
# 入口 easysb.sh 已经定义过这些变量，本函数是幂等的兜底，全部使用 ${VAR:-默认}。
# ---------------------------------------------------------------------------
esb_paths_init() {
  ESB_ROOT="${ESB_ROOT:-}"
  ESB_SCRIPT_VERSION="${ESB_SCRIPT_VERSION:-1.0.0}"
  ESB_DIR="${ESB_DIR:-${ESB_ROOT}/etc/easysb}"
  ESB_STATE="${ESB_STATE:-${ESB_DIR}/state.json}"
  ESB_LOG="${ESB_LOG:-${ESB_DIR}/easysb.log}"
  ESB_SECRET_DIR="${ESB_SECRET_DIR:-${ESB_DIR}/secrets}"
  ESB_CLIENT_DIR="${ESB_CLIENT_DIR:-${ESB_DIR}/client}"
  ESB_CONF_DIR="${ESB_CONF_DIR:-${ESB_ROOT}/etc/sing-box}"
  ESB_CONFIG="${ESB_CONFIG:-${ESB_CONF_DIR}/config.json}"
  ESB_CERT_DIR="${ESB_CERT_DIR:-${ESB_CONF_DIR}/certs}"
  ESB_BIN="${ESB_BIN:-${ESB_ROOT}/usr/bin/sing-box}"
  ESB_UNIT_DIR="${ESB_UNIT_DIR:-${ESB_ROOT}/usr/lib/systemd/system}"
  ESB_STATE_DIR="${ESB_STATE_DIR:-${ESB_ROOT}/var/lib/sing-box}"
  ESB_BACKUP_DIR="${ESB_BACKUP_DIR:-${ESB_ROOT}/var/backups/easysb}"
  ESB_WEB_ROOT="${ESB_WEB_ROOT:-${ESB_ROOT}/var/www/easysb}"
  ESB_NGINX_CONF="${ESB_NGINX_CONF:-${ESB_ROOT}/etc/nginx/conf.d/easysb.conf}"
  # 临时目录也在这里兜底：模块被单独 source（没有走 esb_init）时，
  # 任何 ${ESB_TMP} 使用点都会因 set -u 报 "unbound variable"
  ESB_TMP="${ESB_TMP:-${TMPDIR:-/tmp}/easysb.$$}"
  mkdir -p "$ESB_TMP" 2>/dev/null || true
  return 0
}

esb_log_raw "==== EasySB 启动 ===="


# ===== 内联模块：lib/10-detect.sh =====
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


# ===== 内联模块：lib/20-state.sh =====
#!/usr/bin/env bash
# =============================================================================
# EasySB — 20-state.sh
# 唯一状态源：state.json 的读写、备份、变更路径 apply_change（备份→渲染→校验→重启→回滚）
# 依赖：00-core.sh
# =============================================================================
# shellcheck shell=bash

STATE_SCHEMA=1

esb_state_default() {
  cat <<'JSON'
{
  "schema": 1,
  "script_version": "",
  "installed_at": "",
  "domain": "",
  "email": "",
  "server_ip": "",
  "kernel": {"version": "", "arch_asset": "", "binary": "", "installed_at": "", "checksum": ""},
  "reality": {
    "private_key": "", "public_key": "", "short_id": "",
    "handshake_server": "www.microsoft.com", "handshake_port": 443,
    "server_name": "www.microsoft.com"
  },
  "secrets": {
    "vless_uuid": "", "vmess_uuid": "", "tuic_uuid": "",
    "tuic_password": "", "hysteria2_password": "", "anytls_password": ""
  },
  "protocols": {
    "vless-vision-reality": {"enabled": false, "port": 443,  "tag": "vless-vision-reality"},
    "vmess-ws-tls":         {"enabled": false, "port": 8443, "tag": "vmess-ws-tls", "path": "/vmess", "early_data": true},
    "anytls":               {"enabled": false, "port": 2096, "tag": "anytls", "padding": true},
    "hysteria2":            {"enabled": false, "port": 443,  "tag": "hysteria2",
                             "up_mbps": 100, "down_mbps": 100,
                             "hop": {"enabled": false, "range": "20000-30000", "interval": "30s"}},
    "tuic":                 {"enabled": false, "port": 8443, "tag": "tuic",
                             "congestion_control": "bbr", "zero_rtt": false}
  },
  "cert": {"domain": "", "crt": "", "key": "", "source": "", "applied_at": ""},
  "web": {
    "enabled": false, "template": "blog", "root": "/var/www/easysb",
    "http_port": 80, "tls": false, "tls_port": 443, "proxy_target": ""
  },
  "sub": {
    "enabled": false, "token": "", "serve_via_site": true, "port": 8080,
    "root": "/var/www/easysb-sub", "name": "EasySB"
  },
  "firewall": {"backend": "none", "rules": [], "hop": {"enabled": false, "range": "", "to_port": 0}}
}
JSON
}

esb_proto_keys() { printf 'vless-vision-reality vmess-ws-tls anytls hysteria2 tuic\n'; }

proto_label() {
  case "$1" in
    vless-vision-reality) printf 'VLESS + Vision + REALITY（TCP，免证书）\n' ;;
    vmess-ws-tls)         printf 'VMess + WebSocket + TLS（TCP，可过 CDN）\n' ;;
    anytls)               printf 'AnyTLS（TCP，填充抗指纹）\n' ;;
    hysteria2)            printf 'Hysteria2（QUIC/UDP，端口跳跃）\n' ;;
    tuic)                 printf 'TUIC v5（QUIC/UDP，低延迟）\n' ;;
    *)                    printf '%s\n' "$1" ;;
  esac
  return 0
}

proto_needs_cert() {
  case "$1" in
    vmess-ws-tls|anytls|hysteria2|tuic) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 读写
# ---------------------------------------------------------------------------
state_init() {
  mkdir -p "$ESB_DIR" "$ESB_CLIENT_DIR" "$ESB_SECRET_DIR" "$ESB_BACKUP_DIR" "${ESB_ROOT}/etc/systemd/system" 2>/dev/null || true
  if [ ! -f "$ESB_STATE" ]; then
    log_info "初始化状态文件：$ESB_STATE"
    esb_state_default | json_write "$ESB_STATE" 600 || { error "无法写入状态文件 $ESB_STATE"; return 1; }
  fi
  chmod 600 "$ESB_STATE" 2>/dev/null || true
  return 0
}

state_load() {
  [ -f "$ESB_STATE" ] || { error "状态文件不存在：$ESB_STATE"; return 1; }
  jq_ok || die "缺少 jq，无法读取状态文件"
  if ! jq -e . "$ESB_STATE" >/dev/null 2>&1; then
    die "状态文件损坏（不是合法 JSON）：$ESB_STATE"
  fi
  return 0
}

state_save() {
  jq_ok || die "缺少 jq，无法写入状态文件"
  jq -e . "$ESB_STATE" >/dev/null 2>&1 || die "拒绝保存损坏的状态文件"
  chmod 600 "$ESB_STATE" 2>/dev/null || true
  return 0
}

state_get_raw() {
  local _state_get_raw_filter="$1"
  [ -f "$ESB_STATE" ] || return 0
  jq -r "$_state_get_raw_filter" "$ESB_STATE" 2>/dev/null | tr -d '\r'
  return 0
}

state_get() {
  local _state_get_path="$1"
  # 不能用 `(path) // empty`：jq 的 // 会把 false 也当作"空"，协议开关全是布尔值，
  # 那样会让 false 变成空字符串（渲染时表现为 --argjson 收到非法 JSON）。
  state_get_raw "(${_state_get_path}) | if . == null then empty else . end"
  return 0
}

state_has() {
  local _state_has_path="$1" _state_has_val
  _state_has_val="$(state_get "$_state_has_path")"
  [ -n "$_state_has_val" ]
}

_state_mutate() {
  # $1 = jq 过滤器文件内容, 其余参数透传给 jq（--arg 等）
  local _state_mutate_filter="$1"; shift
  local _state_mutate_tmp="${ESB_STATE}.tmp.$$"
  if ! jq "$@" "$_state_mutate_filter" "$ESB_STATE" >"$_state_mutate_tmp" 2>/dev/null; then
    rm -f "$_state_mutate_tmp"
    error "更新状态失败（jq 过滤器：$_state_mutate_filter）"
    return 1
  fi
  chmod 600 "$_state_mutate_tmp" 2>/dev/null || true
  mv -f "$_state_mutate_tmp" "$ESB_STATE" || { rm -f "$_state_mutate_tmp"; error "状态文件替换失败"; return 1; }
  return 0
}

state_set() {
  local _state_set_path="$1" _state_set_json="$2"
  if ! printf '%s' "$_state_set_json" | jq . >/dev/null 2>&1; then
    error "state_set 的值不是合法 JSON：$_state_set_json"
    return 1
  fi
  _state_mutate "$_state_set_path = \$v" --argjson v "$_state_set_json"
}

state_set_str() {
  local _state_set_str_path="$1" _state_set_str_val="$2"
  _state_mutate "$_state_set_str_path = \$v" --arg v "$_state_set_str_val"
}

state_proto_set() {
  local _state_proto_set_proto="$1" _state_proto_set_json="$2"
  if ! printf '%s' "$_state_proto_set_json" | jq . >/dev/null 2>&1; then
    error "协议配置不是合法 JSON：$_state_proto_set_json"
    return 1
  fi
  _state_mutate ".protocols[\$k] = \$v" --arg k "$_state_proto_set_proto" --argjson v "$_state_proto_set_json"
}

state_proto_set_field() {
  local _spsf_proto="$1" _spsf_path="$2" _spsf_json="$3"
  if ! printf '%s' "$_spsf_json" | jq . >/dev/null 2>&1; then
    error "字段值不是合法 JSON：$_spsf_json"
    return 1
  fi
  _state_mutate ".protocols[\$k]${_spsf_path} = \$v" --arg k "$_spsf_proto" --argjson v "$_spsf_json"
}

secret_get()  { state_get ".secrets.${1}"; }
secret_set()  { state_set_str ".secrets.${1}" "$2"; }

proto_enabled() {
  [ "$(state_get ".protocols[\"$1\"].enabled")" = "true" ]
}

proto_enabled_list() {
  local _pel_keys="" _pel_k
  for _pel_k in $(esb_proto_keys); do
    if proto_enabled "$_pel_k"; then _pel_keys="$_pel_keys $_pel_k"; fi
  done
  printf '%s\n' "$(trim "$_pel_keys")"
  return 0
}

proto_port() { state_get ".protocols[\"$1\"].port"; }

# ---------------------------------------------------------------------------
# 备份 / 回滚
# ---------------------------------------------------------------------------
esb_backup() {
  local _esb_backup_name="${1:-manual}" _esb_backup_dir
  _esb_backup_dir="${ESB_BACKUP_DIR}/$(esb_ts)_$(printf '%s' "$_esb_backup_name" | tr -c 'a-zA-Z0-9_-' '_')"
  mkdir -p "$_esb_backup_dir" || { error "无法创建备份目录"; return 1; }
  local _esb_backup_f
  for _esb_backup_f in "$ESB_STATE" "$ESB_CONFIG"; do
    [ -f "$_esb_backup_f" ] && cp -p "$_esb_backup_f" "$_esb_backup_dir/" 2>/dev/null
  done
  printf '%s\n' "$_esb_backup_dir"
  log_debug "已备份到 $_esb_backup_dir"
  return 0
}

esb_backup_list() {
  [ -d "$ESB_BACKUP_DIR" ] || return 0
  ls -1 "$ESB_BACKUP_DIR" 2>/dev/null | sort -r
  return 0
}

esb_restore_latest() {
  local _esb_restore_dir
  _esb_restore_dir="$(esb_backup_list | head -1)"
  [ -n "$_esb_restore_dir" ] || { log_warn "没有可用备份"; return 1; }
  _esb_restore_dir="${ESB_BACKUP_DIR}/${_esb_restore_dir}"
  [ -f "${_esb_restore_dir}/state.json" ] && cp -pf "${_esb_restore_dir}/state.json" "$ESB_STATE" 2>/dev/null
  if [ -f "${_esb_restore_dir}/config.json" ]; then
    cp -pf "${_esb_restore_dir}/config.json" "$ESB_CONFIG" 2>/dev/null
  else
    rm -f "$ESB_CONFIG" 2>/dev/null
  fi
  log_warn "已回滚：$_esb_restore_dir"
  return 0
}

esb_restore_by_name() {
  local _esb_restore_name="$1"
  local _esb_restore_dir="${ESB_BACKUP_DIR}/${_esb_restore_name}"
  [ -d "$_esb_restore_dir" ] || { error "备份不存在：$_esb_restore_name"; return 1; }
  [ -f "${_esb_restore_dir}/state.json" ] && cp -pf "${_esb_restore_dir}/state.json" "$ESB_STATE" 2>/dev/null
  [ -f "${_esb_restore_dir}/config.json" ] && cp -pf "${_esb_restore_dir}/config.json" "$ESB_CONFIG" 2>/dev/null
  log_ok "已恢复：$_esb_restore_name"
  return 0
}

# ---------------------------------------------------------------------------
# 变更路径：备份 → 渲染 → 校验 → 重启 → 失败自动回滚
# ---------------------------------------------------------------------------
apply_change() {
  local _apply_change_desc="${1:-变更}"
  local _apply_change_backup=""
  _apply_change_backup="$(esb_backup "$_apply_change_desc")" || { error "备份失败，已中止变更"; return 1; }

  if ! render_config; then
    error "配置渲染失败，已回滚"
    esb_restore_latest
    return 1
  fi

  if ! sb_check_config "$ESB_CONFIG"; then
    error "sing-box 校验未通过，已回滚（详情见日志）"
    esb_restore_latest
    return 1
  fi

  if sb_installed; then
    if ! sb_service restart; then
      error "服务重启失败，已回滚配置"
      esb_restore_latest
      render_config >/dev/null 2>&1
      sb_service restart >/dev/null 2>&1
      return 1
    fi
  fi

  fw_apply_all >/dev/null 2>&1 || log_warn "防火墙同步失败（可稍后在菜单中重试）"
  if command -v sub_refresh >/dev/null 2>&1; then
    sub_refresh >/dev/null 2>&1 || log_warn "订阅内容刷新失败（可在【订阅链接】菜单里手动刷新）"
  fi
  state_set_str ".last_change" "$_apply_change_desc" >/dev/null 2>&1
  log_ok "变更已生效：$_apply_change_desc"
  return 0
}


# ===== 内联模块：lib/30-certs.sh =====
#!/usr/bin/env bash
# =============================================================================
# EasySB — 30-certs.sh
# 证书模块：acme.sh 工具安装、证书申请（standalone / webroot / dns:<provider>）、
#           证书注册表（$ESB_DIR/certs.json，权限 600）、应用到 sing-box、续期、删除、
#           续期后自动重载、自签证书兜底。
#
# 关键约定（对照 docs/INTERFACES.md 第 0/1/7 节）：
#   * acme.sh 安装目录：cert_acme_home 输出 $ACME_HOME（= ${ESB_ROOT}/root/.acme.sh），
#     入口为 $ACME_HOME/acme.sh；所有绝对路径都由 ESB_* 变量拼出，不硬编码 /etc 或 /root。
#   * 安装 acme.sh 禁止“下载即执行”：先下载到 $ESB_TMP → bash -n 校验 → 再执行本地副本。
#   * DNS API 凭据：$ESB_SECRET_DIR/dns.env（600，每行 KEY=value）。只在受控子 shell 里
#     `set -a; . 文件; set +a` 加载（供 acme.sh 子进程继承），凭据不进命令行、不打印、
#     不进入本进程环境；日志里只允许出现 mask_secret 的结果。
#   * 申请 / 续期 / 移除 acme 记录 / 续期重载 / 属主调整等系统变更命令一律走 run_gate。
#   * 沙箱兜底：run_gate 在 ESB_GATE=1 下不执行；只有当 ESB_ROOT 非空（沙箱）时才用
#     本地 cp/rm 让被测代码在沙箱里真正落地，真实系统上的 --dry-run 不会写任何文件。
#   * 公共函数一律不 exit：失败 error + return 1（只有 registry_load/save 缺 jq 时 die）。
# 依赖：00-core.sh, 10-detect.sh, 20-state.sh（可选：70-web.sh 的 web_acme_webroot）
# =============================================================================
# shellcheck shell=bash

# acme.sh 目录（cert_acme_home 会按当前 ESB_ROOT 重新计算）
ACME_HOME="${ESB_ROOT:-}/root/.acme.sh"
# 安装脚本地址（可用同名环境变量覆盖，便于内网/镜像）
ACME_INSTALL_URL="${ACME_INSTALL_URL:-https://get.acme.sh}"
# 注册表文件名（位于 $ESB_DIR）
_CERT_REG_NAME="certs.json"
# 自签证书有效期（天）
_CERT_SELF_SIGNED_DAYS=3650

# ---------------------------------------------------------------------------
# 路径与工具
# ---------------------------------------------------------------------------
cert_acme_home() {
  ACME_HOME="${ESB_ROOT:-}/root/.acme.sh"
  printf '%s\n' "$ACME_HOME"
  return 0
}

_cert_registry_file() {
  printf '%s\n' "${ESB_DIR:-${ESB_ROOT:-}/etc/easysb}/${_CERT_REG_NAME}"
}

_cert_dns_env_file() {
  printf '%s\n' "${ESB_SECRET_DIR:-${ESB_ROOT:-}/etc/easysb/secrets}/dns.env"
}

# 0=acme.sh 已就绪（$ACME_HOME/acme.sh 存在且可执行）
cert_tool_installed() {
  local _cert_tool_installed_home
  _cert_tool_installed_home="$(cert_acme_home)"
  [ -s "${_cert_tool_installed_home}/acme.sh" ] && [ -x "${_cert_tool_installed_home}/acme.sh" ]
}

# 安装 acme.sh（幂等；失败 return 1，不 exit）
cert_tool_install() {
  local _cert_tool_install_email="${1:-}"
  if cert_tool_installed; then
    log_ok "acme.sh 已安装：$(cert_acme_home)"
    return 0
  fi

  if [ -z "$_cert_tool_install_email" ]; then
    _cert_tool_install_email="$(state_get .email 2>/dev/null)"
  fi
  if [ -z "$_cert_tool_install_email" ]; then
    local _cert_tool_install_domain
    _cert_tool_install_domain="$(state_get .domain 2>/dev/null)"
    [ -n "$_cert_tool_install_domain" ] && _cert_tool_install_email="admin@${_cert_tool_install_domain}"
  fi
  if [ -z "$_cert_tool_install_email" ]; then
    ask_input _cert_tool_install_email "请输入 acme.sh 注册邮箱（用于证书到期提醒，可留空）" ""
  fi

  local _cert_tool_install_home _cert_tool_install_dir _cert_tool_install_script
  _cert_tool_install_home="$(cert_acme_home)"
  _cert_tool_install_dir="${ESB_TMP:-${TMPDIR:-/tmp}/easysb.$$}"
  mkdir -p "$_cert_tool_install_dir" "$_cert_tool_install_home" 2>/dev/null \
    || { error "无法创建目录：$_cert_tool_install_dir"; return 1; }
  _cert_tool_install_script="${_cert_tool_install_dir}/get.acme.sh"
  rm -f "$_cert_tool_install_script" 2>/dev/null || true

  log_info "下载 acme.sh 安装脚本：$ACME_INSTALL_URL"
  if ! http_get "$ACME_INSTALL_URL" "$_cert_tool_install_script"; then
    error "下载 acme.sh 失败（离线或网络不可达）。也可手动安装到 $_cert_tool_install_home 后重试"
    return 1
  fi
  if [ ! -s "$_cert_tool_install_script" ]; then
    error "下载到的安装脚本为空，已中止"
    rm -f "$_cert_tool_install_script"
    return 1
  fi
  # 禁止下载即执行：先做语法校验，再执行我们自己的本地副本
  if ! bash -n "$_cert_tool_install_script" >/dev/null 2>&1; then
    error "安装脚本语法校验未通过（下载可能被篡改），已中止安装"
    rm -f "$_cert_tool_install_script"
    return 1
  fi

  log_info "安装 acme.sh 到 $_cert_tool_install_home（安装脚本已本地校验，未使用 curl|sh）"
  local _cert_tool_install_rc=0
  # get.acme.sh 会在当前目录落地并解压临时包，因此固定到临时目录执行
  if [ -n "$_cert_tool_install_email" ]; then
    ( cd "$_cert_tool_install_dir" && \
      run_gate "安装 acme.sh" sh -s -- "email=$_cert_tool_install_email" --home "$_cert_tool_install_home" \
        <"$_cert_tool_install_script" ) || _cert_tool_install_rc=1
  else
    ( cd "$_cert_tool_install_dir" && \
      run_gate "安装 acme.sh" sh -s -- --home "$_cert_tool_install_home" \
        <"$_cert_tool_install_script" ) || _cert_tool_install_rc=1
  fi
  rm -f "$_cert_tool_install_script" 2>/dev/null || true

  if cert_tool_installed; then
    # 装上的是什么也要校验：安装产物语法不过就当作失败，避免信任半成品
    if ! bash -n "${_cert_tool_install_home}/acme.sh" >/dev/null 2>&1; then
      error "安装后的 acme.sh 语法校验未通过，请检查网络/镜像后重试"
      return 1
    fi
    if [ -n "$_cert_tool_install_email" ]; then
      state_set_str ".email" "$_cert_tool_install_email" >/dev/null 2>&1 || true
    fi
    log_ok "acme.sh 已安装：$_cert_tool_install_home"
    return 0
  fi
  if [ "${ESB_GATE:-0}" = "1" ]; then
    log_warn "沙箱/--dry-run 模式：未真正执行安装（命令见 ${ESB_GATE_LOG:-gate 日志}）"
    return 0
  fi
  if [ "$_cert_tool_install_rc" != "0" ]; then
    error "acme.sh 安装失败（返回码 $_cert_tool_install_rc），请检查网络与日志"
    return 1
  fi
  error "安装脚本已执行，但未找到 ${_cert_tool_install_home}/acme.sh"
  return 1
}

# ---------------------------------------------------------------------------
# DNS 服务商
# ---------------------------------------------------------------------------
# acme.sh 的 DNS 钩子名，UI 会不加引号地展开本函数输出（ask_single 的 "key|label" 形式），
# 因此标签中不能含空格，每行一个 key|label。
dns_provider_list() {
  printf '%s|%s\n' dns_cf "Cloudflare"
  printf '%s|%s\n' dns_dp "DNSPod"
  printf '%s|%s\n' dns_ali "阿里云DNS"
  printf '%s|%s\n' dns_gd "GoDaddy"
  printf '%s|%s\n' dns_huaweicloud "华为云DNS"
  return 0
}

_cert_dns_provider_ok() {
  local _cert_dns_provider_ok_p="${1-}"
  [ -n "$_cert_dns_provider_ok_p" ] || return 1
  dns_provider_list | grep -q "^${_cert_dns_provider_ok_p}|"
}

# 只提醒不阻断：凭据变量名不合预期时仍继续（acme.sh 会给出明确错误）
_cert_dns_check_creds() {
  local _cert_dns_check_creds_p="${1-}" _cert_dns_check_creds_keys="" _cert_dns_check_creds_k
  case "$_cert_dns_check_creds_p" in
    dns_cf)          _cert_dns_check_creds_keys="CF_Token CF_Key" ;;
    dns_dp)          _cert_dns_check_creds_keys="DP_Id DP_Key" ;;
    dns_ali)         _cert_dns_check_creds_keys="Ali_Key Ali_Secret" ;;
    dns_gd)          _cert_dns_check_creds_keys="GD_Key GD_Secret" ;;
    dns_huaweicloud) _cert_dns_check_creds_keys="HUAWEICLOUD_Username HUAWEICLOUD_Password" ;;
    *) return 0 ;;
  esac
  for _cert_dns_check_creds_k in $_cert_dns_check_creds_keys; do
    if [ -n "${!_cert_dns_check_creds_k:-}" ]; then return 0; fi
  done
  log_warn "凭据文件中未发现 ${_cert_dns_check_creds_p} 需要的变量（其一：$_cert_dns_check_creds_keys），仍会尝试申请"
  return 1
}

# 执行 acme.sh：需要 DNS 凭据时在受控子 shell 里加载 dns.env（凭据不进命令行、不打印）
# 用法：_cert_acme_exec <dns.env 路径|-> <服务商|-> <描述> <acme.sh 及其参数…>
_cert_acme_exec() {
  local _cert_acme_exec_env="$1" _cert_acme_exec_prov="$2" _cert_acme_exec_desc="$3"
  shift 3
  if [ -z "$_cert_acme_exec_env" ]; then
    run_gate "$_cert_acme_exec_desc" "$@"
    return $?
  fi
  local _cert_acme_exec_norm=""
  (
    set -a
    if [ -r "$_cert_acme_exec_env" ]; then
      # 容忍 Windows 编辑器留下的 CRLF：归一化到临时文件（600）后加载，用完即删
      _cert_acme_exec_norm="${ESB_TMP:-${TMPDIR:-/tmp}}/dns.env.$$"
      if tr -d '\r' <"$_cert_acme_exec_env" >"$_cert_acme_exec_norm" 2>/dev/null; then
        chmod 600 "$_cert_acme_exec_norm" 2>/dev/null || true
      else
        _cert_acme_exec_norm="$_cert_acme_exec_env"
      fi
      # shellcheck disable=SC1090
      . "$_cert_acme_exec_norm" || true
      rm -f "$_cert_acme_exec_norm" 2>/dev/null || true
    fi
    set +a
    if [ "$_cert_acme_exec_prov" != "-" ]; then
      _cert_dns_check_creds "$_cert_acme_exec_prov" || true
    fi
    run_gate "$_cert_acme_exec_desc" "$@"
  )
  return $?
}

# ---------------------------------------------------------------------------
# 证书注册表：$ESB_DIR/certs.json（数组，权限 600）
# 记录结构：{domain, crt, key, source, created_at, expires, auto_renew}
# ---------------------------------------------------------------------------
# stdout：规范化后的 JSON 数组；文件不存在=空数组；损坏则 error + return 1（不 exit）
registry_load() {
  local _registry_load_file
  _registry_load_file="$(_cert_registry_file)"
  jq_ok || die "缺少 jq，无法读取证书注册表"
  if [ ! -f "$_registry_load_file" ] || [ ! -s "$_registry_load_file" ]; then
    printf '[]\n'
    return 0
  fi
  if ! jq -e 'type == "array"' "$_registry_load_file" >/dev/null 2>&1; then
    error "证书注册表损坏（不是合法 JSON 数组）：$_registry_load_file"
    log_info "可执行 mv '$_registry_load_file' '${_registry_load_file}.bad' 后重建"
    return 1
  fi
  jq -c '.' "$_registry_load_file" 2>/dev/null || { error "读取证书注册表失败：$_registry_load_file"; return 1; }
  return 0
}

# stdin：JSON 数组 → 原子写入（600）
registry_save() {
  local _registry_save_file _registry_save_data
  _registry_save_file="$(_cert_registry_file)"
  jq_ok || die "缺少 jq，无法写入证书注册表"
  _registry_save_data="$(cat)"
  if ! printf '%s' "$_registry_save_data" | jq -e 'type == "array"' >/dev/null 2>&1; then
    error "拒绝写入非法的证书注册表内容（期望 JSON 数组）"
    return 1
  fi
  printf '%s' "$_registry_save_data" | jq '.' | json_write "$_registry_save_file" 600 || {
    error "写入证书注册表失败：$_registry_save_file"
    return 1
  }
  return 0
}

# registry_get <domain> [字段] → 无字段输出整条记录（一行 JSON），有字段输出原始值
registry_get() {
  local _registry_get_domain="${1-}" _registry_get_field="${2-}" _registry_get_reg
  [ -n "$_registry_get_domain" ] || { error "registry_get 需要域名"; return 1; }
  _registry_get_reg="$(registry_load)" || return 1
  if [ -n "$_registry_get_field" ]; then
    printf '%s' "$_registry_get_reg" | jq -r --arg d "$_registry_get_domain" --arg f "$_registry_get_field" \
      '.[] | select(.domain == $d) | (.[$f] // empty)' 2>/dev/null | tr -d '\r' | head -1
    return 0
  fi
  printf '%s' "$_registry_get_reg" | jq -c --arg d "$_registry_get_domain" \
    '.[] | select(.domain == $d)' 2>/dev/null | tr -d '\r' | head -1
  return 0
}

registry_has() {
  local _registry_has_domain="${1-}" _registry_has_line
  [ -n "$_registry_has_domain" ] || return 1
  _registry_has_line="$(registry_get "$_registry_has_domain" 2>/dev/null)" || return 1
  [ -n "$_registry_has_line" ]
}

# registry_add <domain> <crt> <key> <source> [expires] [auto_renew]
registry_add() {
  local _registry_add_domain="${1-}" _registry_add_crt="${2-}" _registry_add_key="${3-}"
  local _registry_add_source="${4:-manual}" _registry_add_expires="${5-}" _registry_add_auto="${6:-true}"
  [ -n "$_registry_add_domain" ] || { error "registry_add 需要域名"; return 1; }
  case "$_registry_add_auto" in
    1|true|yes|on) _registry_add_auto="true" ;;
    *)             _registry_add_auto="false" ;;
  esac
  local _registry_add_reg _registry_add_created _registry_add_prev
  _registry_add_reg="$(registry_load)" || return 1
  _registry_add_created="$(esb_now)"
  _registry_add_prev="$(printf '%s' "$_registry_add_reg" | jq -r --arg d "$_registry_add_domain" \
    '.[] | select(.domain == $d) | (.created_at // empty)' 2>/dev/null | tr -d '\r' | head -1)"
  [ -n "$_registry_add_prev" ] && _registry_add_created="$_registry_add_prev"
  if [ -z "$_registry_add_expires" ]; then
    _registry_add_expires="$(_cert_expiry_str "$_registry_add_crt" 2>/dev/null || true)"
  fi
  printf '%s' "$_registry_add_reg" | jq \
    --arg d "$_registry_add_domain" --arg c "$_registry_add_crt" --arg k "$_registry_add_key" \
    --arg s "$_registry_add_source" --arg ca "$_registry_add_created" --arg e "$_registry_add_expires" \
    --argjson ar "$_registry_add_auto" \
    'map(select(.domain != $d)) + [{domain:$d, crt:$c, key:$k, source:$s,
      created_at:$ca, expires:$e, auto_renew:$ar}]' | registry_save || {
    error "登记证书失败：$_registry_add_domain"
    return 1
  }
  log_debug "证书已登记：$_registry_add_domain（$_registry_add_source）"
  return 0
}

# registry_set <domain> <JSON 对象> → 覆盖整条记录
registry_set() {
  local _registry_set_domain="${1-}" _registry_set_obj="${2-}" _registry_set_reg
  [ -n "$_registry_set_domain" ] || { error "registry_set 需要域名"; return 1; }
  printf '%s' "$_registry_set_obj" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || { error "registry_set 的值必须是 JSON 对象"; return 1; }
  _registry_set_reg="$(registry_load)" || return 1
  printf '%s' "$_registry_set_reg" | jq --arg d "$_registry_set_domain" --argjson o "$_registry_set_obj" \
    'map(select(.domain != $d)) + [$o + {domain:$d}]' | registry_save \
    || { error "写入证书注册表失败：$_registry_set_domain"; return 1; }
  return 0
}

# registry_remove <domain> → 0=已移除，1=不存在或写入失败
registry_remove() {
  local _registry_remove_domain="${1-}" _registry_remove_reg _registry_remove_hit
  [ -n "$_registry_remove_domain" ] || { error "registry_remove 需要域名"; return 1; }
  _registry_remove_reg="$(registry_load)" || return 1
  _registry_remove_hit="$(printf '%s' "$_registry_remove_reg" | jq -r --arg d "$_registry_remove_domain" \
    '[.[] | select(.domain == $d)] | length' 2>/dev/null | tr -d '\r')"
  if [ "$_registry_remove_hit" = "0" ]; then
    log_warn "证书注册表中没有该域名：$_registry_remove_domain"
    return 1
  fi
  printf '%s' "$_registry_remove_reg" | jq -c --arg d "$_registry_remove_domain" \
    'map(select(.domain != $d))' | registry_save \
    || { error "写入证书注册表失败：$_registry_remove_domain"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# 证书文件与有效期
# ---------------------------------------------------------------------------
# stdout："crt<TAB>key"（优先注册表路径，缺失则退回 $ESB_CERT_DIR/<domain>.*）
_cert_files_for() {
  local _cert_files_for_domain="${1-}" _cert_files_for_crt="" _cert_files_for_key=""
  [ -n "$_cert_files_for_domain" ] || return 1
  _cert_files_for_crt="$(registry_get "$_cert_files_for_domain" crt 2>/dev/null || true)"
  _cert_files_for_key="$(registry_get "$_cert_files_for_domain" key 2>/dev/null || true)"
  if [ -z "$_cert_files_for_crt" ] || [ ! -f "$_cert_files_for_crt" ]; then
    _cert_files_for_crt="${ESB_CERT_DIR}/${_cert_files_for_domain}.crt"
  fi
  if [ -z "$_cert_files_for_key" ] || [ ! -f "$_cert_files_for_key" ]; then
    _cert_files_for_key="${ESB_CERT_DIR}/${_cert_files_for_domain}.key"
  fi
  printf '%s\t%s\n' "$_cert_files_for_crt" "$_cert_files_for_key"
  return 0
}

_cert_crt_of() { _cert_files_for "${1-}" 2>/dev/null | cut -f1; }

_cert_enddate_raw() {
  local _cert_enddate_raw_crt="${1-}"
  [ -r "$_cert_enddate_raw_crt" ] || return 1
  cmd_exists openssl || return 1
  openssl x509 -in "$_cert_enddate_raw_crt" -noout -enddate 2>/dev/null \
    | sed -n 's/^notAfter=//p' | tr -d '\r' | head -1
}

# stdout：到期时间的 epoch 秒；失败无输出、return 1
_cert_expiry_epoch() {
  local _cert_expiry_epoch_end="" _cert_expiry_epoch_out=""
  _cert_expiry_epoch_end="$(_cert_enddate_raw "${1-}")" || return 1
  [ -n "$_cert_expiry_epoch_end" ] || return 1
  _cert_expiry_epoch_out="$(date -d "$_cert_expiry_epoch_end" +%s 2>/dev/null || true)"
  if [ -z "$_cert_expiry_epoch_out" ]; then
    # busybox date（Alpine）
    _cert_expiry_epoch_out="$(date -D '%b %d %H:%M:%S %Y %Z' -d "$_cert_expiry_epoch_end" +%s 2>/dev/null || true)"
  fi
  case "$_cert_expiry_epoch_out" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$_cert_expiry_epoch_out"
  return 0
}

# stdout：到期时间字符串（"YYYY-MM-DD HH:MM:SS"，用于注册表 expires 字段）
_cert_expiry_str() {
  local _cert_expiry_str_epoch=""
  _cert_expiry_str_epoch="$(_cert_expiry_epoch "${1-}" 2>/dev/null)" || return 1
  [ -n "$_cert_expiry_str_epoch" ] || return 1
  date -d "@$_cert_expiry_str_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
    || date -r "$_cert_expiry_str_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
  return 0
}

# 剩余天数：整数；未知/不可读输出 -1（向上取整，便于提前续期提示；始终 return 0）
cert_expiring_days() {
  local _cert_expiring_days_domain="${1-}"
  local _cert_expiring_days_crt="" _cert_expiring_days_end="" _cert_expiring_days_now="" _cert_expiring_days_diff=0
  if [ -z "$_cert_expiring_days_domain" ]; then printf '%s\n' "-1"; return 0; fi
  _cert_expiring_days_crt="$(_cert_crt_of "$_cert_expiring_days_domain")"
  if [ -z "$_cert_expiring_days_crt" ] || [ ! -r "$_cert_expiring_days_crt" ]; then
    printf '%s\n' "-1"
    return 0
  fi
  _cert_expiring_days_end="$(_cert_expiry_epoch "$_cert_expiring_days_crt" 2>/dev/null || true)"
  case "$_cert_expiring_days_end" in
    ''|*[!0-9]*) printf '%s\n' "-1"; return 0 ;;
  esac
  _cert_expiring_days_now="$(date +%s)"
  _cert_expiring_days_diff=$(( _cert_expiring_days_end - _cert_expiring_days_now ))
  if [ "$_cert_expiring_days_diff" -gt 0 ]; then
    printf '%s\n' "$(( (_cert_expiring_days_diff + 86399) / 86400 ))"
  else
    printf '%s\n' "$(( - ( (0 - _cert_expiring_days_diff + 86399) / 86400 ) ))"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 文件落地 / 属主（走 gate；沙箱里本地兜底，真实 --dry-run 不写盘）
# ---------------------------------------------------------------------------
_cert_put_file() {
  local _cert_put_file_src="${1-}" _cert_put_file_dst="${2-}" _cert_put_file_mode="${3:-640}"
  [ -s "$_cert_put_file_src" ] || { error "源文件不存在或为空：$_cert_put_file_src"; return 1; }
  mkdir -p "$(dirname "$_cert_put_file_dst")" 2>/dev/null || true
  run_gate "安装证书文件 $_cert_put_file_dst" install -m "$_cert_put_file_mode" \
    "$_cert_put_file_src" "$_cert_put_file_dst" >/dev/null 2>&1 || true
  if [ ! -s "$_cert_put_file_dst" ]; then
    if [ -n "${ESB_ROOT:-}" ]; then
      # 沙箱：gate 不执行，直接写入沙箱副本
      cp -f "$_cert_put_file_src" "$_cert_put_file_dst" 2>/dev/null \
        || { error "写入文件失败：$_cert_put_file_dst"; return 1; }
      chmod "$_cert_put_file_mode" "$_cert_put_file_dst" 2>/dev/null || true
    else
      error "安装证书文件失败：$_cert_put_file_dst"
      return 1
    fi
  fi
  return 0
}

_cert_rm_file() {
  local _cert_rm_file_path="${1-}"
  [ -e "$_cert_rm_file_path" ] || return 0
  run_gate "删除文件 $_cert_rm_file_path" rm -f "$_cert_rm_file_path" >/dev/null 2>&1 || true
  if [ -e "$_cert_rm_file_path" ] && [ -n "${ESB_ROOT:-}" ]; then
    rm -f "$_cert_rm_file_path" 2>/dev/null || true
  fi
  return 0
}

# 属主调整失败可容忍（容器 / 无 sing-box 用户 / 沙箱）
_cert_chown_singbox() {
  local _cert_chown_singbox_path="${1-}"
  [ -e "$_cert_chown_singbox_path" ] || return 0
  run_gate "设置证书属主 $_cert_chown_singbox_path" chown sing-box:sing-box \
    "$_cert_chown_singbox_path" >/dev/null 2>&1 || log_debug "chown 失败（可忽略）：$_cert_chown_singbox_path"
  return 0
}

# 0 = acme.sh 里已经有该域名的证书（重复签发会因"未到续期时间"而 exit 2）
_cert_acme_has_cert() {
  local _cert_acme_has_cert_domain="${1-}" _cert_acme_has_cert_home="" _cert_acme_has_cert_dir=""
  [ -n "$_cert_acme_has_cert_domain" ] || return 1
  _cert_acme_has_cert_home="$(cert_acme_home)"
  for _cert_acme_has_cert_dir in \
      "${_cert_acme_has_cert_home}/${_cert_acme_has_cert_domain}_ecc" \
      "${_cert_acme_has_cert_home}/${_cert_acme_has_cert_domain}"; do
    if [ -f "${_cert_acme_has_cert_dir}/fullchain.cer" ]; then
      return 0
    fi
  done
  return 1
}

_cert_fetch_acme_files() {
  local _cert_fetch_acme_files_domain="${1-}" _cert_fetch_acme_files_crt="${2-}" _cert_fetch_acme_files_key="${3-}"
  local _cert_fetch_acme_files_home _cert_fetch_acme_files_dir
  local _cert_fetch_acme_files_src_crt="" _cert_fetch_acme_files_src_key=""
  [ -n "$_cert_fetch_acme_files_domain" ] || { error "缺少域名"; return 1; }
  _cert_fetch_acme_files_home="$(cert_acme_home)"
  for _cert_fetch_acme_files_dir in "${_cert_fetch_acme_files_home}/${_cert_fetch_acme_files_domain}_ecc" \
                                  "${_cert_fetch_acme_files_home}/${_cert_fetch_acme_files_domain}"; do
    if [ -s "${_cert_fetch_acme_files_dir}/fullchain.cer" ] \
       && [ -s "${_cert_fetch_acme_files_dir}/${_cert_fetch_acme_files_domain}.key" ]; then
      _cert_fetch_acme_files_src_crt="${_cert_fetch_acme_files_dir}/fullchain.cer"
      _cert_fetch_acme_files_src_key="${_cert_fetch_acme_files_dir}/${_cert_fetch_acme_files_domain}.key"
      break
    fi
    if [ -s "${_cert_fetch_acme_files_dir}/${_cert_fetch_acme_files_domain}.cer" ] \
       && [ -s "${_cert_fetch_acme_files_dir}/${_cert_fetch_acme_files_domain}.key" ]; then
      _cert_fetch_acme_files_src_crt="${_cert_fetch_acme_files_dir}/${_cert_fetch_acme_files_domain}.cer"
      _cert_fetch_acme_files_src_key="${_cert_fetch_acme_files_dir}/${_cert_fetch_acme_files_domain}.key"
      break
    fi
  done
  if [ -z "$_cert_fetch_acme_files_src_crt" ]; then
    error "未找到 acme.sh 生成的证书文件：${_cert_fetch_acme_files_home}/${_cert_fetch_acme_files_domain}_ecc/ 或 ${_cert_fetch_acme_files_home}/${_cert_fetch_acme_files_domain}/"
    return 1
  fi
  _cert_put_file "$_cert_fetch_acme_files_src_crt" "$_cert_fetch_acme_files_crt" 640 || return 1
  _cert_put_file "$_cert_fetch_acme_files_src_key" "$_cert_fetch_acme_files_key" 640 || return 1
  _cert_chown_singbox "$_cert_fetch_acme_files_crt"
  _cert_chown_singbox "$_cert_fetch_acme_files_key"
  return 0
}

# webroot 路径：优先 70-web.sh 的 web_acme_webroot，缺失时用默认目录
_cert_webroot_path() {
  local _cert_webroot_path_out=""
  if declare -F web_acme_webroot >/dev/null 2>&1; then
    _cert_webroot_path_out="$(web_acme_webroot 2>/dev/null | tr -d '\r' | grep -m1 '^/' || true)"
  fi
  [ -n "$_cert_webroot_path_out" ] || _cert_webroot_path_out="${ESB_WEB_ROOT:-${ESB_ROOT:-}/var/www/easysb}/.well-known/acme-challenge"
  printf '%s\n' "$_cert_webroot_path_out"
  return 0
}

# 把证书写进 state：仅当 state 里还没有证书或域名一致时（不触发 apply_change）
_cert_state_set_if_free() {
  local _cert_state_set_if_free_domain="${1-}" _cert_state_set_if_free_crt="${2-}"
  local _cert_state_set_if_free_key="${3-}" _cert_state_set_if_free_source="${4-}"
  local _cert_state_set_if_free_cur=""
  _cert_state_set_if_free_cur="$(state_get .cert.domain 2>/dev/null || true)"
  if [ -n "$_cert_state_set_if_free_cur" ] && [ "$_cert_state_set_if_free_cur" != "$_cert_state_set_if_free_domain" ]; then
    log_info "当前已应用证书为 $_cert_state_set_if_free_cur，本次证书已登记注册表但未改动已应用配置"
    log_info "如需切换，请在【证书管理】中执行「应用证书 $_cert_state_set_if_free_domain」"
    return 1
  fi
  state_set_str ".cert.domain" "$_cert_state_set_if_free_domain" >/dev/null 2>&1 || return 1
  state_set_str ".cert.crt" "$_cert_state_set_if_free_crt" >/dev/null 2>&1 || return 1
  state_set_str ".cert.key" "$_cert_state_set_if_free_key" >/dev/null 2>&1 || return 1
  state_set_str ".cert.source" "$_cert_state_set_if_free_source" >/dev/null 2>&1 || true
  state_set_str ".cert.applied_at" "$(esb_now)" >/dev/null 2>&1 || true
  return 0
}

# ---------------------------------------------------------------------------
# 申请证书：cert_apply <domain> <standalone|webroot|dns:<provider>>
# 成功后：安装证书文件 + 登记注册表（不调用 apply_change）
# ---------------------------------------------------------------------------
cert_apply() {
  local _cert_apply_domain="${1-}" _cert_apply_mode="${2-}"
  validate_domain "$_cert_apply_domain" || return 1
  if [ -z "$_cert_apply_mode" ]; then
    error "缺少申请方式（standalone / webroot / dns:<provider>）"
    return 1
  fi
  local _cert_apply_kind="" _cert_apply_prov=""
  case "$_cert_apply_mode" in
    standalone) _cert_apply_kind="standalone" ;;
    webroot)    _cert_apply_kind="webroot" ;;
    dns:*)
      _cert_apply_kind="dns"
      _cert_apply_prov="${_cert_apply_mode#dns:}"
      if ! _cert_dns_provider_ok "$_cert_apply_prov"; then
        error "不支持的 DNS 服务商：${_cert_apply_prov:-空}"
        log_info "支持的服务商：$(dns_provider_list | tr '\n' ' ')"
        return 1
      fi
      ;;
    *)
      error "未知的申请方式：$_cert_apply_mode（可用：standalone / webroot / dns:<provider>）"
      return 1
      ;;
  esac

  if ! cert_tool_installed; then
    log_warn "尚未安装 acme.sh，先执行安装"
    cert_tool_install || return 1
  fi
  local _cert_apply_home _cert_apply_acme
  _cert_apply_home="$(cert_acme_home)"
  _cert_apply_acme="${_cert_apply_home}/acme.sh"
  mkdir -p "$ESB_CERT_DIR" 2>/dev/null || { error "无法创建证书目录：$ESB_CERT_DIR"; return 1; }

  local -a _cert_apply_args=()
  _cert_apply_args=(--home "$_cert_apply_home" --issue -d "$_cert_apply_domain" --keylength ec-256)
  if [ "${ESB_CERT_FORCE:-0}" = "1" ]; then
    # 强制重签：会消耗 CA 的申请频率额度，仅在明确要求时使用
    _cert_apply_args+=(--force)
    log_info "ESB_CERT_FORCE=1：强制重新签发证书"
  fi
  local _cert_apply_dnsenv=""
  local _cert_apply_webroot=""
  case "$_cert_apply_kind" in
    standalone)
      log_info "standalone 模式：80 端口会被临时占用"
      if port_in_use 80 tcp; then
        log_warn "检测到 80 端口已被占用，standalone 可能失败（可改用 webroot 或 dns 模式）"
      fi
      _cert_apply_args+=(--standalone)
      ;;
    webroot)
      _cert_apply_webroot="$(_cert_webroot_path)"
      mkdir -p "$_cert_apply_webroot" 2>/dev/null \
        || { error "无法创建 webroot 目录：$_cert_apply_webroot"; return 1; }
      log_info "webroot 模式：$_cert_apply_webroot"
      _cert_apply_args+=(-w "$_cert_apply_webroot")
      ;;
    dns)
      _cert_apply_dnsenv="$(_cert_dns_env_file)"
      if [ ! -f "$_cert_apply_dnsenv" ]; then
        error "DNS 凭据文件不存在：$_cert_apply_dnsenv（权限 600，每行 KEY=value）"
        return 1
      fi
      log_info "dns 模式：服务商 $_cert_apply_prov（凭据文件 $_cert_apply_dnsenv）"
      _cert_apply_args+=(--dns "$_cert_apply_prov")
      ;;
  esac

  log_info "申请证书：$_cert_apply_domain（$_cert_apply_mode）"
  if ! _cert_acme_exec "$_cert_apply_dnsenv" "${_cert_apply_prov:--}" \
        "申请证书 $_cert_apply_domain" "$_cert_apply_acme" "${_cert_apply_args[@]}"; then
    # acme.sh 在"域名未变且未到续期时间"时会 exit 2（Domains not changed. Skipping.）——
    # 这不是失败：机器上本来就有一张可用的证书，直接复用它，不要中断部署。
    if _cert_acme_has_cert "$_cert_apply_domain"; then
      log_warn "acme.sh 已有 $_cert_apply_domain 的有效证书（未到续期时间），本次直接复用"
      log_info "如需强制重新签发：用 ESB_CERT_FORCE=1 重跑，或在【证书管理】里执行续期"
    else
      error "申请证书失败：$_cert_apply_domain（方式：$_cert_apply_mode）"
      log_info "常见原因：域名未解析到本机 / 80 端口被占用 / DNS 凭据错误或未生效 / 申请频率超限"
      return 1
    fi
  fi

  local _cert_apply_crt="${ESB_CERT_DIR}/${_cert_apply_domain}.crt"
  local _cert_apply_key="${ESB_CERT_DIR}/${_cert_apply_domain}.key"
  local _cert_apply_source="acme:${_cert_apply_mode}"
  if ! _cert_fetch_acme_files "$_cert_apply_domain" "$_cert_apply_crt" "$_cert_apply_key"; then
    error "证书已申请，但安装证书文件失败"
    return 1
  fi
  if ! registry_add "$_cert_apply_domain" "$_cert_apply_crt" "$_cert_apply_key" "$_cert_apply_source"; then
    error "登记证书注册表失败：$_cert_apply_domain"
    return 1
  fi
  if _cert_state_set_if_free "$_cert_apply_domain" "$_cert_apply_crt" "$_cert_apply_key" "$_cert_apply_source"; then
    log_ok "证书已申请并设为已应用证书：$_cert_apply_domain"
  else
    log_ok "证书已申请并登记：$_cert_apply_domain（剩余 $(cert_expiring_days "$_cert_apply_domain") 天）"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 列表：stdout TSV（域名<TAB>crt<TAB>key<TAB>剩余天数<TAB>来源<TAB>是否已应用）
# ---------------------------------------------------------------------------
cert_list() {
  local _cert_list_reg="" _cert_list_applied=""
  local _cert_list_d="" _cert_list_c="" _cert_list_k="" _cert_list_s="" _cert_list_days="" _cert_list_a=0
  _cert_list_reg="$(registry_load)" || return 1
  _cert_list_applied="$(state_get .cert.domain 2>/dev/null || true)"
  while IFS="$(printf '\t')" read -r _cert_list_d _cert_list_c _cert_list_k _cert_list_s; do
    [ -n "$_cert_list_d" ] || continue
    _cert_list_days="$(cert_expiring_days "$_cert_list_d")"
    if [ -n "$_cert_list_applied" ] && [ "$_cert_list_d" = "$_cert_list_applied" ]; then
      _cert_list_a=1
    else
      _cert_list_a=0
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$_cert_list_d" "$_cert_list_c" "$_cert_list_k" "$_cert_list_days" "$_cert_list_s" "$_cert_list_a"
  done < <(printf '%s\n' "$_cert_list_reg" \
            | jq -r '.[] | [(.domain // ""), (.crt // ""), (.key // ""), (.source // "")] | join("\t")' 2>/dev/null \
            | tr -d '\r')
  return 0
}

# ---------------------------------------------------------------------------
# 应用证书：安装文件 → 写 state.cert.* → apply_change（返回其状态）
# ---------------------------------------------------------------------------
cert_use() {
  local _cert_use_domain="${1-}"
  [ -n "$_cert_use_domain" ] || { error "用法：cert_use <域名>"; return 1; }
  validate_domain "$_cert_use_domain" || return 1
  if ! registry_has "$_cert_use_domain"; then
    error "证书未登记：$_cert_use_domain（请先申请证书或使用 cert_self_signed）"
    return 1
  fi
  local _cert_use_src_crt="" _cert_use_src_key="" _cert_use_source=""
  _cert_use_src_crt="$(registry_get "$_cert_use_domain" crt 2>/dev/null || true)"
  _cert_use_src_key="$(registry_get "$_cert_use_domain" key 2>/dev/null || true)"
  _cert_use_source="$(registry_get "$_cert_use_domain" source 2>/dev/null || true)"
  local _cert_use_dst_crt="${ESB_CERT_DIR}/${_cert_use_domain}.crt"
  local _cert_use_dst_key="${ESB_CERT_DIR}/${_cert_use_domain}.key"
  mkdir -p "$ESB_CERT_DIR" 2>/dev/null || { error "无法创建证书目录：$ESB_CERT_DIR"; return 1; }

  if [ "$_cert_use_src_crt" != "$_cert_use_dst_crt" ] || [ ! -s "$_cert_use_dst_crt" ]; then
    [ -n "$_cert_use_src_crt" ] || _cert_use_src_crt="$_cert_use_dst_crt"
    _cert_put_file "$_cert_use_src_crt" "$_cert_use_dst_crt" 640 || {
      error "安装证书文件失败：$_cert_use_dst_crt"
      return 1
    }
  fi
  if [ "$_cert_use_src_key" != "$_cert_use_dst_key" ] || [ ! -s "$_cert_use_dst_key" ]; then
    [ -n "$_cert_use_src_key" ] || _cert_use_src_key="$_cert_use_dst_key"
    _cert_put_file "$_cert_use_src_key" "$_cert_use_dst_key" 640 || {
      error "安装私钥文件失败：$_cert_use_dst_key"
      return 1
    }
  fi
  _cert_chown_singbox "$_cert_use_dst_crt"
  _cert_chown_singbox "$_cert_use_dst_key"

  registry_add "$_cert_use_domain" "$_cert_use_dst_crt" "$_cert_use_dst_key" "${_cert_use_source:-manual}" \
    || { error "更新证书注册表失败：$_cert_use_domain"; return 1; }

  state_set_str ".cert.domain" "$_cert_use_domain" >/dev/null 2>&1 || { error "写入状态文件失败"; return 1; }
  state_set_str ".cert.crt" "$_cert_use_dst_crt" >/dev/null 2>&1 || { error "写入状态文件失败"; return 1; }
  state_set_str ".cert.key" "$_cert_use_dst_key" >/dev/null 2>&1 || { error "写入状态文件失败"; return 1; }
  state_set_str ".cert.source" "${_cert_use_source:-manual}" >/dev/null 2>&1 || true
  state_set_str ".cert.applied_at" "$(esb_now)" >/dev/null 2>&1 || true

  log_info "已选择证书 $_cert_use_domain，正在应用到 sing-box…"
  apply_change "应用证书 $_cert_use_domain"
}

# ---------------------------------------------------------------------------
# 删除证书：cert_delete <domain> [--force]
# ---------------------------------------------------------------------------
cert_delete() {
  local _cert_delete_domain="${1-}" _cert_delete_flag="${2-}"
  [ -n "$_cert_delete_domain" ] || { error "用法：cert_delete <域名> [--force]"; return 1; }
  validate_domain "$_cert_delete_domain" || return 1
  if ! registry_has "$_cert_delete_domain"; then
    error "证书未登记：$_cert_delete_domain"
    return 1
  fi
  local _cert_delete_applied="" _cert_delete_forced=0
  _cert_delete_applied="$(state_get .cert.domain 2>/dev/null || true)"
  [ "$_cert_delete_flag" = "--force" ] && _cert_delete_forced=1
  if [ "$_cert_delete_applied" = "$_cert_delete_domain" ] && [ "$_cert_delete_forced" = "0" ]; then
    error "证书 $_cert_delete_domain 正在被 sing-box 使用；确认删除请加 --force"
    return 1
  fi

  local _cert_delete_src_crt="" _cert_delete_src_key=""
  _cert_delete_src_crt="$(registry_get "$_cert_delete_domain" crt 2>/dev/null || true)"
  _cert_delete_src_key="$(registry_get "$_cert_delete_domain" key 2>/dev/null || true)"
  [ -n "$_cert_delete_src_crt" ] || _cert_delete_src_crt="${ESB_CERT_DIR}/${_cert_delete_domain}.crt"
  [ -n "$_cert_delete_src_key" ] || _cert_delete_src_key="${ESB_CERT_DIR}/${_cert_delete_domain}.key"

  # 先留副本（注册表 + 证书文件）
  local _cert_delete_bdir="${ESB_BACKUP_DIR}/$(esb_ts)_cert-$(printf '%s' "$_cert_delete_domain" | tr -c 'a-zA-Z0-9._-' '_')"
  if mkdir -p "$_cert_delete_bdir" 2>/dev/null; then
    [ -f "$_cert_delete_src_crt" ] && cp -p "$_cert_delete_src_crt" "${_cert_delete_bdir}/${_cert_delete_domain}.crt" 2>/dev/null
    [ -f "$_cert_delete_src_key" ] && cp -p "$_cert_delete_src_key" "${_cert_delete_bdir}/${_cert_delete_domain}.key" 2>/dev/null
    printf '%s\n' "$(registry_get "$_cert_delete_domain" 2>/dev/null || true)" >"${_cert_delete_bdir}/registry-entry.json" 2>/dev/null || true
    log_info "证书已备份到：$_cert_delete_bdir"
  else
    log_warn "无法创建备份目录，继续删除：$_cert_delete_bdir"
  fi

  if ! registry_remove "$_cert_delete_domain"; then
    error "从注册表移除失败：$_cert_delete_domain"
    return 1
  fi
  _cert_rm_file "$_cert_delete_src_crt"
  _cert_rm_file "$_cert_delete_src_key"
  _cert_rm_file "${ESB_CERT_DIR}/${_cert_delete_domain}.crt"
  _cert_rm_file "${ESB_CERT_DIR}/${_cert_delete_domain}.key"

  if cert_tool_installed; then
    local _cert_delete_home
    _cert_delete_home="$(cert_acme_home)"
    run_gate "移除 acme 记录 $_cert_delete_domain" "${_cert_delete_home}/acme.sh" \
      --home "$_cert_delete_home" --remove -d "$_cert_delete_domain" >/dev/null 2>&1 \
      || log_warn "acme.sh --remove 未成功（可忽略；证书目录里的记录可能已不存在）"
  fi

  if [ "$_cert_delete_forced" = "1" ] && [ "$_cert_delete_applied" = "$_cert_delete_domain" ]; then
    state_set_str ".cert.domain" "" >/dev/null 2>&1 || true
    state_set_str ".cert.crt" "" >/dev/null 2>&1 || true
    state_set_str ".cert.key" "" >/dev/null 2>&1 || true
    state_set_str ".cert.source" "" >/dev/null 2>&1 || true
    log_warn "已清除 state 中对该证书的引用；请重新申请并应用证书后执行「应用变更」，否则服务重启会失败"
  fi
  log_ok "证书已删除：$_cert_delete_domain"
  return 0
}

# ---------------------------------------------------------------------------
# 续期
# ---------------------------------------------------------------------------
cert_renew() {
  local _cert_renew_domain="${1-}"
  [ -n "$_cert_renew_domain" ] || { error "用法：cert_renew <域名>"; return 1; }
  validate_domain "$_cert_renew_domain" || return 1
  local _cert_renew_source="" _cert_renew_registered=0
  if registry_has "$_cert_renew_domain" 2>/dev/null; then
    _cert_renew_registered=1
    _cert_renew_source="$(registry_get "$_cert_renew_domain" source 2>/dev/null || true)"
  fi
  if [ "$_cert_renew_source" = "self-signed" ]; then
    error "自签证书无法用 acme.sh 续期：$_cert_renew_domain（如需更换请重新申请或再次自签）"
    return 1
  fi
  if ! cert_tool_installed; then
    error "尚未安装 acme.sh，无法续期：$_cert_renew_domain"
    return 1
  fi
  local _cert_renew_home _cert_renew_acme
  _cert_renew_home="$(cert_acme_home)"
  _cert_renew_acme="${_cert_renew_home}/acme.sh"
  log_info "续期证书：$_cert_renew_domain"
  local -a _cert_renew_args=()
  _cert_renew_args=(--home "$_cert_renew_home" --renew -d "$_cert_renew_domain")
  # 默认不强制：acme.sh 只在确实到期/临近到期时才真正续期。
  # （无条件 --force 会白白消耗 Let's Encrypt 的签发频率额度，真机上实测过会被拒。）
  if [ "${ESB_CERT_FORCE:-0}" = "1" ]; then
    _cert_renew_args+=(--force)
    log_info "ESB_CERT_FORCE=1：强制续期"
  fi
  if ! _cert_acme_exec "-" "-" "续期证书 $_cert_renew_domain" "$_cert_renew_acme" "${_cert_renew_args[@]}"; then
    # 未到续期时间时 acme.sh 也会返回非 0（Skipping），这不是错误
    if _cert_acme_has_cert "$_cert_renew_domain"; then
      log_warn "未到续期时间（剩余 $(cert_expiring_days "$_cert_renew_domain") 天），本次无需续期"
      return 0
    fi
    error "续期失败：$_cert_renew_domain（可尝试重新申请：cert_apply $_cert_renew_domain <mode>）"
    return 1
  fi

  if [ "$_cert_renew_registered" = "1" ]; then
    local _cert_renew_crt="${ESB_CERT_DIR}/${_cert_renew_domain}.crt"
    local _cert_renew_key="${ESB_CERT_DIR}/${_cert_renew_domain}.key"
    if ! _cert_fetch_acme_files "$_cert_renew_domain" "$_cert_renew_crt" "$_cert_renew_key"; then
      log_warn "续期成功，但重新安装证书文件失败（注册表路径保持 $(_cert_crt_of "$_cert_renew_domain")）"
      return 1
    fi
    registry_add "$_cert_renew_domain" "$_cert_renew_crt" "$_cert_renew_key" \
      "${_cert_renew_source:-acme}" || log_warn "续期成功，但刷新注册表过期时间失败"
    log_ok "续期完成：$_cert_renew_domain（剩余 $(cert_expiring_days "$_cert_renew_domain") 天）"
    return 0
  fi
  log_ok "续期完成：$_cert_renew_domain"
  return 0
}

cert_renew_all() {
  local _cert_renew_all_reg="" _cert_renew_all_domain="" _cert_renew_all_source=""
  local _cert_renew_all_ok=0 _cert_renew_all_fail=0 _cert_renew_all_skip=0 _cert_renew_all_count=0
  _cert_renew_all_reg="$(registry_load)" || return 1
  _cert_renew_all_count="$(printf '%s' "$_cert_renew_all_reg" | jq 'length' 2>/dev/null | tr -d '\r')"
  case "$_cert_renew_all_count" in
    ''|*[!0-9]*) _cert_renew_all_count=0 ;;
  esac
  if [ "$_cert_renew_all_count" = "0" ]; then
    log_info "证书注册表中暂无证书，无需续期"
    return 0
  fi
  log_info "开始续期全部证书（共 $_cert_renew_all_count 个）"
  while IFS= read -r _cert_renew_all_domain; do
    [ -n "$_cert_renew_all_domain" ] || continue
    _cert_renew_all_source="$(registry_get "$_cert_renew_all_domain" source 2>/dev/null || true)"
    if [ "$_cert_renew_all_source" = "self-signed" ]; then
      log_info "跳过自签证书：$_cert_renew_all_domain"
      _cert_renew_all_skip=$((_cert_renew_all_skip + 1))
      continue
    fi
    if cert_renew "$_cert_renew_all_domain"; then
      _cert_renew_all_ok=$((_cert_renew_all_ok + 1))
    else
      _cert_renew_all_fail=$((_cert_renew_all_fail + 1))
    fi
  done < <(printf '%s\n' "$_cert_renew_all_reg" | jq -r '.[].domain // empty' 2>/dev/null | tr -d '\r')
  if [ "$_cert_renew_all_fail" -gt 0 ]; then
    log_warn "续期结束：成功 $_cert_renew_all_ok 个，失败 $_cert_renew_all_fail 个，跳过 $_cert_renew_all_skip 个"
    return 1
  fi
  log_ok "续期结束：成功 $_cert_renew_all_ok 个，跳过 $_cert_renew_all_skip 个"
  return 0
}

# ---------------------------------------------------------------------------
# 详情 / 自签 / 续期后自动重载
# ---------------------------------------------------------------------------
cert_detail() {
  local _cert_detail_domain="${1-}" _cert_detail_crt="" _cert_detail_out=""
  [ -n "$_cert_detail_domain" ] || { error "用法：cert_detail <域名>"; return 1; }
  cmd_exists openssl || { error "缺少 openssl，无法读取证书详情"; return 1; }
  _cert_detail_crt="$(_cert_crt_of "$_cert_detail_domain")"
  if [ -z "$_cert_detail_crt" ] || [ ! -r "$_cert_detail_crt" ]; then
    error "证书文件不存在或不可读：${_cert_detail_crt:-（未登记）}"
    return 1
  fi
  if ! _cert_detail_out="$(openssl x509 -in "$_cert_detail_crt" -noout -subject -issuer -dates \
        -ext subjectAltName 2>&1)"; then
    # 老版本 openssl 不支持 -ext，退化为全量解析后抓取 SAN
    if ! _cert_detail_out="$(openssl x509 -in "$_cert_detail_crt" -noout -subject -issuer -dates 2>&1)"; then
      error "无法解析证书：$_cert_detail_crt"
      return 1
    fi
    local _cert_detail_san=""
    _cert_detail_san="$(openssl x509 -in "$_cert_detail_crt" -noout -text 2>/dev/null \
      | grep -A1 -i 'Subject Alternative Name' | tail -1 | tr -d '\r')"
    _cert_detail_san="$(trim "$_cert_detail_san")"
    [ -n "$_cert_detail_san" ] && _cert_detail_out="${_cert_detail_out}
X509v3 Subject Alternative Name: ${_cert_detail_san}"
  fi
  printf '%s\n' "$_cert_detail_out" | tr -d '\r'
  printf '剩余天数：%s 天\n' "$(cert_expiring_days "$_cert_detail_domain")"
  return 0
}

# 自签证书（测试/兜底）：EC P-256，10 年，注册表 source=self-signed
cert_self_signed() {
  local _cert_self_signed_domain="${1-}"
  validate_domain "$_cert_self_signed_domain" || return 1
  cmd_exists openssl || { error "缺少 openssl，无法生成自签证书"; return 1; }
  mkdir -p "$ESB_CERT_DIR" 2>/dev/null || { error "无法创建证书目录：$ESB_CERT_DIR"; return 1; }
  local _cert_self_signed_crt="${ESB_CERT_DIR}/${_cert_self_signed_domain}.crt"
  local _cert_self_signed_key="${ESB_CERT_DIR}/${_cert_self_signed_domain}.key"
  local _cert_self_signed_dir="${ESB_TMP:-${TMPDIR:-/tmp}/easysb.$$}"
  mkdir -p "$_cert_self_signed_dir" 2>/dev/null || { error "无法创建临时目录：$_cert_self_signed_dir"; return 1; }
  local _cert_self_signed_tmp_crt="${_cert_self_signed_dir}/self-${_cert_self_signed_domain}.crt"
  local _cert_self_signed_tmp_key="${_cert_self_signed_dir}/self-${_cert_self_signed_domain}.key"
  rm -f "$_cert_self_signed_tmp_crt" "$_cert_self_signed_tmp_key" 2>/dev/null || true

  log_info "生成自签证书（EC P-256，$_CERT_SELF_SIGNED_DAYS 天）：$_cert_self_signed_domain"
  if ! openssl ecparam -genkey -name prime256v1 -out "$_cert_self_signed_tmp_key" >/dev/null 2>&1; then
    error "生成私钥失败（openssl ecparam）"
    return 1
  fi
  chmod 600 "$_cert_self_signed_tmp_key" 2>/dev/null || true
  if ! openssl req -new -x509 -key "$_cert_self_signed_tmp_key" -out "$_cert_self_signed_tmp_crt" \
        -days "$_CERT_SELF_SIGNED_DAYS" -subj "/CN=${_cert_self_signed_domain}" \
        -addext "subjectAltName=DNS:${_cert_self_signed_domain}" >/dev/null 2>&1; then
    # openssl < 1.1.1 不支持 -addext，用临时配置兜底
    local _cert_self_signed_cnf="${_cert_self_signed_dir}/self-${_cert_self_signed_domain}.cnf"
    {
      printf '[req]\n'
      printf 'distinguished_name = dn\n'
      printf 'x509_extensions = v3_req\n'
      printf 'prompt = no\n'
      printf '[dn]\n'
      printf 'CN = %s\n' "$_cert_self_signed_domain"
      printf '[v3_req]\n'
      printf 'basicConstraints = CA:FALSE\n'
      printf 'keyUsage = digitalSignature, keyEncipherment\n'
      printf 'extendedKeyUsage = serverAuth\n'
      printf 'subjectAltName = DNS:%s\n' "$_cert_self_signed_domain"
    } >"$_cert_self_signed_cnf" 2>/dev/null || true
    if ! openssl req -new -x509 -key "$_cert_self_signed_tmp_key" -out "$_cert_self_signed_tmp_crt" \
          -days "$_CERT_SELF_SIGNED_DAYS" -config "$_cert_self_signed_cnf" -extensions v3_req >/dev/null 2>&1; then
      error "生成自签证书失败（openssl req）"
      rm -f "$_cert_self_signed_tmp_key" "$_cert_self_signed_tmp_crt" "$_cert_self_signed_cnf" 2>/dev/null || true
      return 1
    fi
    rm -f "$_cert_self_signed_cnf" 2>/dev/null || true
  fi
  chmod 640 "$_cert_self_signed_tmp_crt" 2>/dev/null || true

  if ! _cert_put_file "$_cert_self_signed_tmp_crt" "$_cert_self_signed_crt" 640; then
    rm -f "$_cert_self_signed_tmp_key" "$_cert_self_signed_tmp_crt" 2>/dev/null || true
    return 1
  fi
  if ! _cert_put_file "$_cert_self_signed_tmp_key" "$_cert_self_signed_key" 640; then
    rm -f "$_cert_self_signed_tmp_key" "$_cert_self_signed_tmp_crt" 2>/dev/null || true
    return 1
  fi
  rm -f "$_cert_self_signed_tmp_key" "$_cert_self_signed_tmp_crt" 2>/dev/null || true
  _cert_chown_singbox "$_cert_self_signed_crt"
  _cert_chown_singbox "$_cert_self_signed_key"

  if ! registry_add "$_cert_self_signed_domain" "$_cert_self_signed_crt" "$_cert_self_signed_key" "self-signed"; then
    error "登记自签证书失败：$_cert_self_signed_domain"
    return 1
  fi
  log_ok "自签证书已生成：$_cert_self_signed_crt"
  return 0
}

# 让 acme.sh 续期成功后自动重载 sing-box（仅 acme 证书、auto_renew=true）
cert_reloadcmd_setup() {
  local _cert_reloadcmd_reg="" _cert_reloadcmd_domain=""
  local _cert_reloadcmd_ok=0 _cert_reloadcmd_fail=0
  _cert_reloadcmd_reg="$(registry_load)" || return 1
  local -a _cert_reloadcmd_domains=()
  while IFS= read -r _cert_reloadcmd_domain; do
    [ -n "$_cert_reloadcmd_domain" ] && _cert_reloadcmd_domains+=("$_cert_reloadcmd_domain")
  done < <(printf '%s\n' "$_cert_reloadcmd_reg" \
            | jq -r '.[] | select((.source // "") != "self-signed")
                     | select((.auto_renew // true) != false) | .domain // empty' 2>/dev/null | tr -d '\r')
  if [ "${#_cert_reloadcmd_domains[@]}" = "0" ]; then
    log_info "没有需要配置自动重载的 acme 证书"
    return 0
  fi
  cert_tool_installed || { error "尚未安装 acme.sh，无法配置续期自动重载"; return 1; }

  local _cert_reloadcmd_home="" _cert_reloadcmd_acme="" _cert_reloadcmd_cmd=""
  _cert_reloadcmd_home="$(cert_acme_home)"
  _cert_reloadcmd_acme="${_cert_reloadcmd_home}/acme.sh"
  case "${ESB_INIT:-systemd}" in
    systemd)   _cert_reloadcmd_cmd="systemctl restart sing-box" ;;
    openrc)    _cert_reloadcmd_cmd="rc-service sing-box restart" ;;
    sysvinit)  _cert_reloadcmd_cmd="${ESB_ROOT:-}/etc/init.d/sing-box restart" ;;
    *)         _cert_reloadcmd_cmd="" ;;
  esac
  if [ -z "$_cert_reloadcmd_cmd" ]; then
    log_warn "当前 init（${ESB_INIT:-none}）没有可用的服务重启命令：只更新证书文件，不设置 --reloadcmd"
  fi

  local _cert_reloadcmd_crt="" _cert_reloadcmd_key=""
  for _cert_reloadcmd_domain in "${_cert_reloadcmd_domains[@]}"; do
    _cert_reloadcmd_crt="$(registry_get "$_cert_reloadcmd_domain" crt 2>/dev/null || true)"
    _cert_reloadcmd_key="$(registry_get "$_cert_reloadcmd_domain" key 2>/dev/null || true)"
    [ -n "$_cert_reloadcmd_crt" ] || _cert_reloadcmd_crt="${ESB_CERT_DIR}/${_cert_reloadcmd_domain}.crt"
    [ -n "$_cert_reloadcmd_key" ] || _cert_reloadcmd_key="${ESB_CERT_DIR}/${_cert_reloadcmd_domain}.key"
    if [ -n "$_cert_reloadcmd_cmd" ]; then
      if run_gate "配置证书续期重载 $_cert_reloadcmd_domain" "$_cert_reloadcmd_acme" \
            --home "$_cert_reloadcmd_home" --install-cert -d "$_cert_reloadcmd_domain" \
            --key-file "$_cert_reloadcmd_key" --fullchain-file "$_cert_reloadcmd_crt" \
            --reloadcmd "$_cert_reloadcmd_cmd"; then
        _cert_reloadcmd_ok=$((_cert_reloadcmd_ok + 1))
      else
        log_warn "配置续期重载失败：$_cert_reloadcmd_domain"
        _cert_reloadcmd_fail=$((_cert_reloadcmd_fail + 1))
      fi
    else
      if run_gate "配置证书续期重载 $_cert_reloadcmd_domain" "$_cert_reloadcmd_acme" \
            --home "$_cert_reloadcmd_home" --install-cert -d "$_cert_reloadcmd_domain" \
            --key-file "$_cert_reloadcmd_key" --fullchain-file "$_cert_reloadcmd_crt"; then
        _cert_reloadcmd_ok=$((_cert_reloadcmd_ok + 1))
      else
        log_warn "配置续期重载失败：$_cert_reloadcmd_domain"
        _cert_reloadcmd_fail=$((_cert_reloadcmd_fail + 1))
      fi
    fi
  done
  if [ "$_cert_reloadcmd_fail" -gt 0 ]; then
    log_warn "续期自动重载配置完成：成功 $_cert_reloadcmd_ok 个，失败 $_cert_reloadcmd_fail 个"
    return 1
  fi
  log_ok "已设置续期后自动重载（成功 $_cert_reloadcmd_ok 个）"
  return 0
}


# ===== 内联模块：lib/40-render.sh =====
#!/usr/bin/env bash
# =============================================================================
# EasySB — 40-render.sh
# 配置渲染：服务端 inbound / 客户端配置 / 分享链接，全部由 jq 从 state 生成
# 依赖：00-core.sh, 20-state.sh
# =============================================================================
# shellcheck shell=bash

# AnyTLS 默认填充方案（与仓库 AnyTLS/config_server.json 一致）
ESB_ANYTLS_PADDING='["stop=8","0=30-30","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"]'

# ---------------------------------------------------------------------------
# 服务端 inbound
# ---------------------------------------------------------------------------
_render_inbound_vless() {
  jq -n --argjson port "$(proto_port vless-vision-reality)" \
        --arg uuid "$(secret_get vless_uuid)" \
        --arg sni "$(state_get .reality.server_name)" \
        --arg hs "$(state_get .reality.handshake_server)" \
        --argjson hsport "$(state_get .reality.handshake_port)" \
        --arg pk "$(state_get .reality.private_key)" \
        --arg sid "$(state_get .reality.short_id)" '
    {type:"vless", tag:"vless-vision-reality", listen:"::", listen_port:$port,
     users:[{uuid:$uuid, flow:"xtls-rprx-vision"}],
     tls:{enabled:true, server_name:$sni,
          reality:{enabled:true,
                   handshake:{server:$hs, server_port:$hsport},
                   private_key:$pk, short_id:[$sid]}}}'
}

_render_inbound_vmess() {
  jq -n --argjson port "$(proto_port vmess-ws-tls)" \
        --arg uuid "$(secret_get vmess_uuid)" \
        --arg path "$(state_get '.protocols["vmess-ws-tls"].path')" \
        --argjson early "$(state_get '.protocols["vmess-ws-tls"].early_data')" \
        --arg crt "$(state_get .cert.crt)" --arg key "$(state_get .cert.key)" '
    ({type:"vmess", tag:"vmess-ws-tls", listen:"::", listen_port:$port,
      users:[{uuid:$uuid, alterId:0}],
      multiplex:{enabled:true, padding:false},
      transport:({type:"ws", path:$path} + (if $early then
                   {max_early_data:2048, early_data_header_name:"Sec-WebSocket-Protocol"} else {} end))}
     + {tls:{enabled:true, certificate_path:$crt, key_path:$key}})'
}

_render_inbound_anytls() {
  jq -n --argjson port "$(proto_port anytls)" \
        --arg pw "$(secret_get anytls_password)" \
        --argjson pad "$(state_get '.protocols.anytls.padding')" \
        --argjson padding "$ESB_ANYTLS_PADDING" \
        --arg crt "$(state_get .cert.crt)" --arg key "$(state_get .cert.key)" '
    ({type:"anytls", tag:"anytls", listen:"::", listen_port:$port,
      users:[{name:"easysb", password:$pw}],
      tls:{enabled:true, certificate_path:$crt, key_path:$key,
           alpn:["h3","h2","http/1.1"]}}
     + (if $pad then {padding_scheme:$padding} else {} end))'
}

_render_inbound_hysteria2() {
  jq -n --argjson port "$(proto_port hysteria2)" \
        --arg pw "$(secret_get hysteria2_password)" \
        --argjson up "$(state_get '.protocols.hysteria2.up_mbps')" \
        --argjson down "$(state_get '.protocols.hysteria2.down_mbps')" \
        --arg crt "$(state_get .cert.crt)" --arg key "$(state_get .cert.key)" '
    {type:"hysteria2", tag:"hysteria2", listen:"::", listen_port:$port,
     up_mbps:$up, down_mbps:$down,
     users:[{name:"easysb", password:$pw}],
     tls:{enabled:true, alpn:["h3"], certificate_path:$crt, key_path:$key}}'
}

_render_inbound_tuic() {
  jq -n --argjson port "$(proto_port tuic)" \
        --arg uuid "$(secret_get tuic_uuid)" \
        --arg pw "$(secret_get tuic_password)" \
        --arg cc "$(state_get '.protocols.tuic.congestion_control')" \
        --argjson zrtt "$(state_get '.protocols.tuic.zero_rtt')" \
        --arg crt "$(state_get .cert.crt)" --arg key "$(state_get .cert.key)" '
    {type:"tuic", tag:"tuic", listen:"::", listen_port:$port,
     users:[{uuid:$uuid, password:$pw}],
     congestion_control:$cc, auth_timeout:"3s", zero_rtt_handshake:$zrtt, heartbeat:"10s",
     tls:{enabled:true, alpn:["h3"], certificate_path:$crt, key_path:$key}}'
}

render_inbound() {
  case "$1" in
    vless-vision-reality) _render_inbound_vless ;;
    vmess-ws-tls)         _render_inbound_vmess ;;
    anytls)               _render_inbound_anytls ;;
    hysteria2)            _render_inbound_hysteria2 ;;
    tuic)                 _render_inbound_tuic ;;
    *) error "未知协议：$1"; return 1 ;;
  esac
}

# 需要证书但还没应用证书时返回 1
render_cert_ready() {
  local _rcr_p _rcr_need=0
  for _rcr_p in $(proto_enabled_list); do
    if proto_needs_cert "$_rcr_p"; then _rcr_need=1; break; fi
  done
  [ "$_rcr_need" = "0" ] && return 0
  local _rcr_crt _rcr_key
  _rcr_crt="$(state_get .cert.crt)"
  _rcr_key="$(state_get .cert.key)"
  [ -f "$_rcr_crt" ] && [ -f "$_rcr_key" ]
}

# ---------------------------------------------------------------------------
# 服务端配置
# ---------------------------------------------------------------------------
render_config() {
  jq_ok || { error "缺少 jq"; return 1; }
  local _rc_list _rc_p _rc_level
  _rc_list="$(proto_enabled_list)"
  if [ -z "$_rc_list" ]; then error "尚未启用任何协议，无法生成配置"; return 1; fi
  if ! render_cert_ready; then
    error "已启用需要证书的协议，但尚未应用证书（请先在【证书管理】中申请并应用证书）"
    return 1
  fi

  mkdir -p "$ESB_CONF_DIR" || { error "无法创建配置目录 $ESB_CONF_DIR"; return 1; }

  local _rc_jsonl="${ESB_TMP}/inbounds.jsonl"
  : >"$_rc_jsonl" || return 1
  for _rc_p in $_rc_list; do
    if ! render_inbound "$_rc_p" >>"$_rc_jsonl"; then
      error "渲染协议 $_rc_p 的 inbound 失败"
      return 1
    fi
    printf '\n' >>"$_rc_jsonl"
  done

  _rc_level="$(state_get .log_level)"; [ -n "$_rc_level" ] || _rc_level="warn"
  local _rc_out="${ESB_CONFIG}.tmp.$$"
  if ! jq -s --arg level "$_rc_level" '
        {log:{level:$level, timestamp:true},
         inbounds:.,
         outbounds:[{type:"direct", tag:"direct"}]}' <"$_rc_jsonl" >"$_rc_out"; then
    rm -f "$_rc_out"
    error "生成服务端配置失败（jq）"
    return 1
  fi
  chmod 600 "$_rc_out" 2>/dev/null || true
  mv -f "$_rc_out" "$ESB_CONFIG" || { rm -f "$_rc_out"; error "写入 $ESB_CONFIG 失败"; return 1; }
  # 服务以 sing-box 用户运行，而配置是 root 写的：这里立刻修正属主/权限
  if command -v sb_fix_perms >/dev/null 2>&1; then sb_fix_perms >/dev/null 2>&1 || true; fi
  log_debug "服务端配置已生成：$ESB_CONFIG（协议：$_rc_list）"
  return 0
}

# ---------------------------------------------------------------------------
# 客户端 outbound
# ---------------------------------------------------------------------------
_client_server()   { local _cs_d; _cs_d="$(state_get .domain)"; printf '%s\n' "$_cs_d"; }

_render_outbound_vless() {
  jq -n --arg server "$(_client_server)" --argjson port "$(proto_port vless-vision-reality)" \
        --arg uuid "$(secret_get vless_uuid)" \
        --arg sni "$(state_get .reality.server_name)" \
        --arg pbk "$(state_get .reality.public_key)" \
        --arg sid "$(state_get .reality.short_id)" '
    {type:"vless", tag:"vless-vision-reality", server:$server, server_port:$port,
     uuid:$uuid, flow:"xtls-rprx-vision", packet_encoding:"xudp",
     tls:{enabled:true, server_name:$sni,
          utls:{enabled:true, fingerprint:"chrome"},
          reality:{enabled:true, public_key:$pbk, short_id:$sid}}}'
}

_render_outbound_vmess() {
  jq -n --arg server "$(_client_server)" --argjson port "$(proto_port vmess-ws-tls)" \
        --arg uuid "$(secret_get vmess_uuid)" \
        --arg path "$(state_get '.protocols["vmess-ws-tls"].path')" '
    {type:"vmess", tag:"vmess-ws-tls", server:$server, server_port:$port, uuid:$uuid,
     security:"auto", alter_id:0, global_padding:false, authenticated_length:true,
     packet_encoding:"packetaddr",
     tls:{enabled:true, server_name:$server,
          utls:{enabled:true, fingerprint:"chrome"}},
     multiplex:{enabled:true, protocol:"smux", max_connections:4, min_streams:4,
                max_streams:0, padding:false},
     transport:{type:"ws", path:$path, max_early_data:2048,
                early_data_header_name:"Sec-WebSocket-Protocol"}}'
}

_render_outbound_anytls() {
  jq -n --arg server "$(_client_server)" --argjson port "$(proto_port anytls)" \
        --arg pw "$(secret_get anytls_password)" '
    {type:"anytls", tag:"anytls", server:$server, server_port:$port, password:$pw,
     idle_session_check_interval:"30s", idle_session_timeout:"30s", min_idle_session:5,
     tls:{enabled:true, server_name:$server, alpn:["h3","h2","http/1.1"],
          utls:{enabled:true, fingerprint:"chrome"}}}'
}

_render_outbound_hysteria2() {
  local _roh_hop_enabled _roh_range _roh_interval _roh_range_colon
  _roh_hop_enabled="$(state_get '.protocols.hysteria2.hop.enabled')"
  if [ "$_roh_hop_enabled" = "true" ]; then
    _roh_range="$(state_get '.protocols.hysteria2.hop.range')"
    _roh_interval="$(state_get '.protocols.hysteria2.hop.interval')"
  else
    _roh_range=""; _roh_interval=""
  fi
  # 关键：sing-box 的 server_ports 要冒号分隔（"2080:3000"），带"-"会被
  # `sing-box check` 判为 "bad port range"（nft 用 "-"，iptables 用 ":"，
  # 这里是第三种写法，state 里统一保存 "a-b" 形式再按需转换）。
  _roh_range_colon="$(printf '%s' "$_roh_range" | tr '-' ':')"
  jq -n --arg server "$(_client_server)" --argjson port "$(proto_port hysteria2)" \
        --arg pw "$(secret_get hysteria2_password)" \
        --arg hop "$_roh_range_colon" --arg hopint "$_roh_interval" '
    ({type:"hysteria2", tag:"hysteria2", server:$server, server_port:$port,
      up_mbps:20, down_mbps:100, password:$pw,
      tls:{enabled:true, server_name:$server, alpn:["h3"]}}
     + (if $hop != "" then {server_ports:[$hop], hop_interval:$hopint} else {} end))'
}

_render_outbound_tuic() {
  jq -n --arg server "$(_client_server)" --argjson port "$(proto_port tuic)" \
        --arg uuid "$(secret_get tuic_uuid)" --arg pw "$(secret_get tuic_password)" \
        --arg cc "$(state_get '.protocols.tuic.congestion_control')" '
    {type:"tuic", tag:"tuic", server:$server, server_port:$port, uuid:$uuid, password:$pw,
     congestion_control:$cc, udp_relay_mode:"native", udp_over_stream:false,
     zero_rtt_handshake:false, heartbeat:"10s", network:"tcp",
     tls:{enabled:true, server_name:$server, alpn:["h3"]}}'
}

render_outbound() {
  case "$1" in
    vless-vision-reality) _render_outbound_vless ;;
    vmess-ws-tls)         _render_outbound_vmess ;;
    anytls)               _render_outbound_anytls ;;
    hysteria2)            _render_outbound_hysteria2 ;;
    tuic)                 _render_outbound_tuic ;;
    *) error "未知协议：$1"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 客户端配置
# ---------------------------------------------------------------------------
render_client_proto() {
  local _rcp_proto="$1" _rcp_out="${ESB_CLIENT_DIR}/$1.json" _rcp_tmp
  mkdir -p "$ESB_CLIENT_DIR" || return 1
  _rcp_tmp="${_rcp_out}.tmp.$$"
  # 与仓库模板一一对应：mixed 入站 10000 + 该协议的单条 outbound
  if ! render_outbound "$_rcp_proto" | jq '{log:{level:"warn", timestamp:true},
        inbounds:[{type:"mixed", listen:"::", listen_port:10000}],
        outbounds:[.]}' >"$_rcp_tmp"; then
    rm -f "$_rcp_tmp"
    error "渲染客户端配置失败：$_rcp_proto"
    return 1
  fi
  chmod 600 "$_rcp_tmp" 2>/dev/null || true
  mv -f "$_rcp_tmp" "$_rcp_out" || { rm -f "$_rcp_tmp"; return 1; }
  return 0
}

render_client_all() {
  local _rca_out="${ESB_CLIENT_DIR}/all.json" _rca_tmp="${ESB_CLIENT_DIR}/all.json.tmp.$$"
  local _rca_jsonl="${ESB_TMP}/outbounds.jsonl" _rca_p
  mkdir -p "$ESB_CLIENT_DIR" || return 1
  : >"$_rca_jsonl" || return 1
  for _rca_p in $(proto_enabled_list); do
    render_outbound "$_rca_p" >>"$_rca_jsonl" || { error "渲染客户端 outbound 失败：$_rca_p"; return 1; }
    printf '\n' >>"$_rca_jsonl"
  done
  if ! jq -s '{log:{level:"warn", timestamp:true},
               inbounds:[{type:"mixed", listen:"::", listen_port:10000}],
               outbounds:(. + [{type:"direct", tag:"direct"}])}' <"$_rca_jsonl" >"$_rca_tmp"; then
    rm -f "$_rca_tmp"; error "生成 all.json 失败"; return 1
  fi
  chmod 600 "$_rca_tmp" 2>/dev/null || true
  mv -f "$_rca_tmp" "$_rca_out" || { rm -f "$_rca_tmp"; return 1; }
  return 0
}

render_clients() {
  local _rcl_p _rcl_fail=0
  for _rcl_p in $(proto_enabled_list); do
    render_client_proto "$_rcl_p" || _rcl_fail=1
  done
  render_client_all || _rcl_fail=1
  [ "$_rcl_fail" = "0" ] || { error "部分客户端配置生成失败"; return 1; }
  log_ok "客户端配置已生成于：$ESB_CLIENT_DIR"
  return 0
}

# ---------------------------------------------------------------------------
# 分享链接
# ---------------------------------------------------------------------------
url_encode() { printf '%s' "${1-}" | jq -sRr @uri; }

link_vless() {
  local _lv_server _lv_port _lv_uuid _lv_sni _lv_pbk _lv_sid _lv_name
  _lv_server="$(_client_server)"; _lv_port="$(proto_port vless-vision-reality)"
  _lv_uuid="$(secret_get vless_uuid)"; _lv_sni="$(state_get .reality.server_name)"
  _lv_pbk="$(state_get .reality.public_key)"; _lv_sid="$(state_get .reality.short_id)"
  _lv_name="$(url_encode "EasySB-VLESS-Reality-${_lv_server}")"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s\n' \
    "$_lv_uuid" "$_lv_server" "$_lv_port" "$(url_encode "$_lv_sni")" "$(url_encode "$_lv_pbk")" "$_lv_sid" "$_lv_name"
  return 0
}

link_vmess() {
  local _lm_server _lm_port _lm_uuid _lm_path _lm_ps _lm_json
  _lm_server="$(_client_server)"; _lm_port="$(proto_port vmess-ws-tls)"
  _lm_uuid="$(secret_get vmess_uuid)"; _lm_path="$(state_get '.protocols["vmess-ws-tls"].path')"
  _lm_ps="EasySB-VMess-WS-TLS-${_lm_server}"
  _lm_json="$(jq -nc --arg v "2" --arg ps "$_lm_ps" --arg add "$_lm_server" \
      --argjson port "$_lm_port" --arg id "$_lm_uuid" --arg host "$_lm_server" \
      --arg path "$_lm_path" '
      {v:$v, ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:"auto",
       net:"ws", type:"none", host:$host, path:$path, tls:"tls",
       sni:$add, alpn:"h2,http/1.1", fp:"chrome"}')"
  printf 'vmess://%s\n' "$(printf '%s' "$_lm_json" | base64 | tr -d '\n')"
  return 0
}

link_hysteria2() {
  local _lh_server _lh_port _lh_pw _lh_hop _lh_hopint _lh_name _lh_q
  _lh_server="$(_client_server)"; _lh_port="$(proto_port hysteria2)"
  _lh_pw="$(secret_get hysteria2_password)"
  _lh_hop=""; _lh_hopint=""
  if [ "$(state_get '.protocols.hysteria2.hop.enabled')" = "true" ]; then
    _lh_hop="$(state_get '.protocols.hysteria2.hop.range')"
    _lh_hopint="$(state_get '.protocols.hysteria2.hop.interval')"
  fi
  _lh_name="$(url_encode "EasySB-Hysteria2-${_lh_server}")"
  _lh_q="sni=${_lh_server}&insecure=0&alpn=h3"
  [ -n "$_lh_hop" ] && _lh_q="${_lh_q}&mport=$(url_encode "$_lh_hop")&hop_interval=${_lh_hopint}"
  printf 'hysteria2://%s@%s:%s?%s#%s\n' "$(url_encode "$_lh_pw")" "$_lh_server" "$_lh_port" "$_lh_q" "$_lh_name"
  return 0
}

link_tuic() {
  local _lt_server _lt_port _lt_uuid _lt_pw _lt_name
  _lt_server="$(_client_server)"; _lt_port="$(proto_port tuic)"
  _lt_uuid="$(secret_get tuic_uuid)"; _lt_pw="$(secret_get tuic_password)"
  _lt_name="$(url_encode "EasySB-TUIC-${_lt_server}")"
  printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=%s&allow_insecure=0#%s\n' \
    "$_lt_uuid" "$(url_encode "$_lt_pw")" "$_lt_server" "$_lt_port" "$_lt_server" "$_lt_name"
  return 0
}

link_anytls() {
  local _la_server _la_port _la_pw _la_name
  _la_server="$(_client_server)"; _la_port="$(proto_port anytls)"
  _la_pw="$(secret_get anytls_password)"
  _la_name="$(url_encode "EasySB-AnyTLS-${_la_server}")"
  printf 'anytls://%s@%s:%s?sni=%s&insecure=0&fp=chrome#%s\n' \
    "$(url_encode "$_la_pw")" "$_la_server" "$_la_port" "$_la_server" "$_la_name"
  return 0
}

render_links() {
  local _rl_p
  for _rl_p in $(proto_enabled_list); do
    case "$_rl_p" in
      vless-vision-reality) link_vless ;;
      vmess-ws-tls)         link_vmess ;;
      anytls)               link_anytls ;;
      hysteria2)            link_hysteria2 ;;
      tuic)                 link_tuic ;;
    esac
  done
  return 0
}

client_link_for() {
  case "$1" in
    vless-vision-reality) link_vless ;;
    vmess-ws-tls)         link_vmess ;;
    anytls)               link_anytls ;;
    hysteria2)            link_hysteria2 ;;
    tuic)                 link_tuic ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 摘要
# ---------------------------------------------------------------------------
render_summary() {
  local _rs_p _rs_port _rs_trans
  ui_kv "部署域名" "$(state_get .domain)"
  ui_kv "公网 IP" "$(state_get .server_ip)"
  ui_kv "内核版本" "$(state_get .kernel.version)"
  local _rs_cert_domain; _rs_cert_domain="$(state_get .cert.domain)"
  if [ -n "$_rs_cert_domain" ]; then
    ui_kv "已应用证书" "${_rs_cert_domain}（剩余 $(cert_expiring_days "$_rs_cert_domain" 2>/dev/null || echo '?') 天）"
  else
    ui_kv "已应用证书" "无"
  fi
  printf '  %-18s\n' "协议列表"
  for _rs_p in $(proto_enabled_list); do
    _rs_port="$(proto_port "$_rs_p")"
    case "$_rs_p" in
      hysteria2|tuic) _rs_trans="UDP" ;;
      *) _rs_trans="TCP" ;;
    esac
    printf '      %s%-22s%s %s/%-6s %s\n' "$C_GREEN" "$_rs_p" "$C_RESET" "$_rs_trans" "$_rs_port" "$(proto_label "$_rs_p" | tr -d '\n')"
  done
  local _rs_web; _rs_web="$(state_get .web.enabled)"
  if [ "$_rs_web" = "true" ]; then
    ui_kv "伪装站点" "已开启（模板：$(state_get .web.template)，端口 $(state_get .web.http_port)）"
  else
    ui_kv "伪装站点" "未开启"
  fi
  return 0
}


# ===== 内联模块：lib/50-singbox.sh =====
#!/usr/bin/env bash
# =============================================================================
# EasySB — 50-singbox.sh
# 内核管理：从本仓库 releases 下载/校验/安装/更新，systemd 服务，配置校验，脚本自更新
# 依赖：00-core.sh, 10-detect.sh, 20-state.sh
# =============================================================================
# shellcheck shell=bash

ESB_REPO="${ESB_REPO:-MinimaxFlora/EasySB}"
ESB_REPO_BRANCH="${ESB_REPO_BRANCH:-master}"

# ---------------------------------------------------------------------------
# 版本信息
# ---------------------------------------------------------------------------
version_norm() { printf '%s' "${1-}" | sed -e 's/^v//' -e 's/[[:space:]]*$//' | tr -d '\r'; }

# 0 = a > b, 1 = a < b, 2 = 相等
version_cmp() {
  local _version_cmp_a _version_cmp_b _version_cmp_top
  _version_cmp_a="$(version_norm "$1")"
  _version_cmp_b="$(version_norm "$2")"
  [ "$_version_cmp_a" = "$_version_cmp_b" ] && return 2
  _version_cmp_top="$(printf '%s\n%s\n' "$_version_cmp_a" "$_version_cmp_b" | sort -V | tail -1)"
  if [ "$_version_cmp_top" = "$_version_cmp_a" ]; then return 0; fi
  return 1
}

sb_installed() { [ -x "${ESB_BIN:-}" ]; }

sb_version() {
  sb_installed || return 0
  local _sb_version_out=""
  if [ "${ESB_GATE:-0}" = "1" ] && [ "${ESB_STUB_BIN:-0}" = "1" ]; then
    _sb_version_out="$("$ESB_BIN" version 2>/dev/null | head -1)"
  else
    _sb_version_out="$("$ESB_BIN" version 2>/dev/null | head -1)"
  fi
  printf '%s\n' "$_sb_version_out" | sed -n 's/.*version[[:space:]]\+\([0-9][0-9.]*\).*/\1/p' | tr -d '\r'
  return 0
}

_release_api_latest() { http_json "https://api.github.com/repos/${ESB_REPO}/releases/latest"; }
_release_api_tag()    { http_json "https://api.github.com/repos/${ESB_REPO}/releases/tags/v$(version_norm "$1")"; }

sb_latest_version() {
  local _slv_json _slv_tag=""
  _slv_json="$(_release_api_latest)"
  if [ -n "$_slv_json" ]; then
    _slv_tag="$(printf '%s' "$_slv_json" | jq -r '.tag_name // empty' 2>/dev/null | tr -d '\r')"
  fi
  if [ -z "$_slv_tag" ]; then
    # 兜底：跟随 releases/latest 的跳转（HTTP 头里的 location 大小写不固定，必须忽略大小写匹配）
    if cmd_exists curl; then
      _slv_tag="$(curl -fsSI --connect-timeout 10 "https://github.com/${ESB_REPO}/releases/latest" 2>/dev/null \
        | tr -d '\r' | awk -F'/' 'tolower($1) ~ /^location:/ {print $NF}' | tail -1)"
    fi
  fi
  version_norm "$_slv_tag"
  return 0
}

script_latest_version() {
  local _slv_url="https://raw.githubusercontent.com/${ESB_REPO}/${ESB_REPO_BRANCH}/EasySB/VERSION"
  if [ "${ESB_OFFLINE:-0}" = "1" ]; then printf '\n'; return 0; fi
  if cmd_exists curl; then
    curl -fsSL --connect-timeout 10 "$_slv_url" 2>/dev/null | tr -d '\r\n' | head -c 32
  fi
  printf '\n'
  return 0
}

sb_asset_name() {
  printf 'sing-box-%s-%s.tar.gz\n' "$(version_norm "$1")" "${ESB_ASSET:-linux-amd64}"
}

sb_asset_url() {
  printf 'https://github.com/%s/releases/download/v%s/%s\n' "$ESB_REPO" "$(version_norm "$1")" "$(sb_asset_name "$1")"
}

# 从 API 取该资产的 sha256（形如 sha256:xxx），取不到输出空
sb_asset_digest() {
  local _sad_ver="$1" _sad_name="$2" _sad_json=""
  _sad_json="$(_release_api_tag "$_sad_ver")"
  [ -n "$_sad_json" ] || return 0
  printf '%s' "$_sad_json" | jq -r --arg n "$_sad_name" \
    '.assets[]? | select(.name==$n) | (.digest // "")' 2>/dev/null | tr -d '\r' | head -1
  return 0
}

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
sb_ensure_user() {
  if [ "${ESB_INIT:-systemd}" != "systemd" ]; then return 0; fi
  if ! id sing-box >/dev/null 2>&1; then
    log_info "创建 sing-box 系统用户"
    run_gate "创建 sing-box 用户" useradd -r -s /usr/sbin/nologin -d "$ESB_STATE_DIR" sing-box >/dev/null 2>&1 \
      || run_gate "创建 sing-box 用户(adduser)" adduser -S -D -H -s /sbin/nologin sing-box >/dev/null 2>&1 \
      || log_warn "无法创建 sing-box 用户，服务将以 root 运行"
  fi
  return 0
}

# 服务以 sing-box 用户运行（unit 里的 User=sing-box），而配置文件是 root 写的：
# 这里把配置与证书调成 root:sing-box 640/750，否则服务启动时会 permission denied。
sb_fix_perms() {
  local _sb_fp_grp="sing-box"
  if [ "${ESB_INIT:-systemd}" != "systemd" ]; then return 0; fi
  if ! id "$_sb_fp_grp" >/dev/null 2>&1; then return 0; fi
  if [ -d "$ESB_CONF_DIR" ]; then
    run_gate "设置配置目录属主" chown "root:${_sb_fp_grp}" "$ESB_CONF_DIR" >/dev/null 2>&1 || true
    run_gate "设置配置目录权限" chmod 750 "$ESB_CONF_DIR" >/dev/null 2>&1 || true
  fi
  if [ -f "$ESB_CONFIG" ]; then
    run_gate "设置配置属主" chown "root:${_sb_fp_grp}" "$ESB_CONFIG" >/dev/null 2>&1 || true
    run_gate "设置配置权限" chmod 640 "$ESB_CONFIG" >/dev/null 2>&1 || true
  fi
  if [ -d "$ESB_CERT_DIR" ]; then
    run_gate "设置证书属主" chown -R "root:${_sb_fp_grp}" "$ESB_CERT_DIR" >/dev/null 2>&1 || true
    chmod 750 "$ESB_CERT_DIR" 2>/dev/null || true
    find "$ESB_CERT_DIR" -maxdepth 1 -type f -name '*.key' -exec chmod 640 {} + 2>/dev/null || true
    find "$ESB_CERT_DIR" -maxdepth 1 -type f -name '*.crt' -exec chmod 644 {} + 2>/dev/null || true
  fi
  return 0
}

sb_ensure_dirs() {
  mkdir -p "$ESB_CONF_DIR" "$ESB_CERT_DIR" "$ESB_CLIENT_DIR" "$ESB_STATE_DIR" "$ESB_BACKUP_DIR" "$(dirname "$ESB_BIN")" 2>/dev/null || true
  chmod 750 "$ESB_CONF_DIR" "$ESB_STATE_DIR" 2>/dev/null || true
  chmod 700 "$ESB_DIR" "$ESB_SECRET_DIR" 2>/dev/null || true
  return 0
}

# sb_install <version|latest> [--no-service]
sb_install() {
  local _sb_install_req="${1:-latest}"
  local _sb_install_ver="" _sb_install_asset _sb_install_url _sb_install_dir
  local _sb_install_tmp _sb_install_tgz _sb_install_bin _sb_install_old=""

  if [ "${ESB_GATE:-0}" = "1" ] && [ "${ESB_STUB_BIN:-0}" = "1" ]; then
    log_warn "沙箱模式：跳过真实下载"
    return 0
  fi

  _sb_install_ver="$(version_norm "$_sb_install_req")"
  if [ -z "$_sb_install_ver" ] || [ "$_sb_install_ver" = "latest" ]; then
    log_info "查询最新版本…"
    _sb_install_ver="$(sb_latest_version)"
  fi
  if [ -z "$_sb_install_ver" ]; then
    error "无法获取最新版本号（网络不可达？）。可手动指定版本号重试"
    return 1
  fi

  # 版本下限提示：本仓库编译的内核从 1.14 起，AnyTLS 从 1.12 起才存在
  version_cmp "$_sb_install_ver" "1.12.0"
  if [ "$?" = "1" ]; then
    log_warn "所选内核 v${_sb_install_ver} 低于 1.12：AnyTLS 协议不可用（本仓库提供的内核从 1.14 起）"
  fi

  _sb_install_asset="$(sb_asset_name "$_sb_install_ver")"
  _sb_install_url="$(sb_asset_url "$_sb_install_ver")"
  _sb_install_dir="${ESB_TMP}/kernel-${_sb_install_ver}"
  rm -rf "$_sb_install_dir"; mkdir -p "$_sb_install_dir" || return 1
  _sb_install_tgz="${_sb_install_dir}/${_sb_install_asset}"

  log_info "下载 sing-box v${_sb_install_ver}（${ESB_ASSET}）"
  log_debug "URL: $_sb_install_url"
  if ! http_get "$_sb_install_url" "$_sb_install_tgz"; then
    error "下载失败：$_sb_install_url"
    log_info "说明：内核只从本仓库 releases 安装（本仓库编译的内核从 1.14 起），指定更旧的版本会 404"
    log_info "可先手动下载后放到 $ESB_TMP 再重试，或检查服务器网络/代理"
    return 1
  fi

  # 校验 sha256（以 API 提供的 digest 为准）
  local _sb_install_digest _sb_install_sum
  _sb_install_digest="$(sb_asset_digest "$_sb_install_ver" "$_sb_install_asset")"
  _sb_install_sum="$(sha256_of "$_sb_install_tgz")" || { error "无法计算下载文件校验和"; return 1; }
  if [ -n "$_sb_install_digest" ]; then
    if [ "${_sb_install_digest#sha256:}" != "$_sb_install_sum" ]; then
      error "校验和与官方发布不一致，已中止安装"
      log_err "期望：${_sb_install_digest#sha256:}"
      log_err "实际：$_sb_install_sum"
      return 1
    fi
    log_ok "校验和匹配：$_sb_install_sum"
  else
    log_warn "未能从 API 获取官方校验和，已计算本地校验和：$_sb_install_sum"
  fi

  # 解压（独立目录，避免解到别的版本）
  tar -xzf "$_sb_install_tgz" -C "$_sb_install_dir" || { error "解压失败"; return 1; }
  _sb_install_bin="$(find "$_sb_install_dir" -type f -name sing-box -perm -u+x | head -1)"
  if [ -z "$_sb_install_bin" ]; then
    _sb_install_bin="$(find "$_sb_install_dir" -type f -name 'sing-box' | head -1)"
  fi
  [ -n "$_sb_install_bin" ] || { error "压缩包中未找到 sing-box 可执行文件"; return 1; }
  chmod 755 "$_sb_install_bin" || true

  # 自证版本（防止装到错误的版本）
  local _sb_install_report
  _sb_install_report="$("$_sb_install_bin" version 2>/dev/null | head -1 | tr -d '\r')"
  if ! printf '%s' "$_sb_install_report" | grep -q "$_sb_install_ver"; then
    error "下载的二进制版本与请求不符：期望 $_sb_install_ver，实际 [$_sb_install_report]"
    return 1
  fi

  # 备份旧内核
  if sb_installed; then
    _sb_install_old="$(sb_version)"
    if [ -n "$_sb_install_old" ] && [ "$_sb_install_old" != "$_sb_install_ver" ]; then
      mkdir -p "$ESB_BACKUP_DIR" 2>/dev/null || true
      cp -p "$ESB_BIN" "${ESB_BACKUP_DIR}/sing-box.${_sb_install_old}" 2>/dev/null \
        && log_info "已备份旧内核：${ESB_BACKUP_DIR}/sing-box.${_sb_install_old}"
    fi
  fi

  sb_ensure_dirs
  sb_ensure_user
  if ! run_gate "安装内核" install -m 0755 "$_sb_install_bin" "${ESB_BIN}.new"; then
    # 沙箱/无 install 时用 cp
    cp -f "$_sb_install_bin" "${ESB_BIN}.new" || { error "拷贝内核失败"; return 1; }
    chmod 755 "${ESB_BIN}.new" 2>/dev/null || true
  fi
  mv -f "${ESB_BIN}.new" "$ESB_BIN" || { error "替换内核失败"; return 1; }
  log_ok "sing-box v${_sb_install_ver} 已安装到 $ESB_BIN"

  unit_install
  sb_fix_perms >/dev/null 2>&1 || true
  sb_service enable >/dev/null 2>&1 || true

  state_set_str ".kernel.version" "$_sb_install_ver" || true
  state_set_str ".kernel.arch_asset" "$ESB_ASSET" || true
  state_set_str ".kernel.binary" "$ESB_BIN" || true
  state_set_str ".kernel.installed_at" "$(esb_now)" || true
  state_set_str ".kernel.checksum" "sha256:$_sb_install_sum" || true
  return 0
}

sb_update() {
  local _sb_update_cur _sb_update_new
  _sb_update_cur="$(sb_version)"
  log_info "当前内核版本：${_sb_update_cur:-未安装}"
  log_info "查询仓库最新版本…"
  _sb_update_new="$(sb_latest_version)"
  if [ -z "$_sb_update_new" ]; then
    error "无法获取最新版本（网络不可达）"
    return 1
  fi
  if [ -n "$_sb_update_cur" ] && [ "$_sb_update_cur" = "$_sb_update_new" ]; then
    log_ok "已是最新版本（v${_sb_update_new}），无需更新"
    return 0
  fi
  log_info "准备更新：${_sb_update_cur:-无} → ${_sb_update_new}"
  sb_install "$_sb_update_new" || return 1
  if [ -f "$ESB_CONFIG" ]; then
    if sb_check_config "$ESB_CONFIG"; then
      sb_service restart || log_warn "服务重启失败，请检查 systemctl status sing-box"
    else
      log_warn "新内核校验配置未通过，请检查配置与版本兼容性"
    fi
  fi
  log_ok "内核更新完成：v${_sb_update_new}"
  return 0
}

# ---------------------------------------------------------------------------
# 配置校验 / 能力探测
# ---------------------------------------------------------------------------
sb_check_config() {
  local _sbcc_file="${1:-$ESB_CONFIG}" _sbcc_err
  [ -f "$_sbcc_file" ] || { error "配置文件不存在：$_sbcc_file"; return 1; }
  sb_installed || { log_warn "未安装 sing-box，跳过配置校验"; return 0; }
  if _sbcc_err="$("$ESB_BIN" check -c "$_sbcc_file" 2>&1)"; then
    log_debug "配置校验通过：$_sbcc_file"
    return 0
  fi
  log_err "sing-box check 失败："
  printf '%s\n' "$_sbcc_err" | sed 's/^/    /' >&2
  esb_log_raw "[CHECK] $_sbcc_err"
  return 1
}

# 生成探针用的临时证书（TLS inbound 探针需要真实文件，否则会被误判为不支持）
_probe_tls_files() {
  local _ptf_dir="$1"
  [ -f "${_ptf_dir}/probe.crt" ] && [ -f "${_ptf_dir}/probe.key" ] && return 0
  cmd_exists openssl || return 1
  openssl ecparam -genkey -name prime256v1 -out "${_ptf_dir}/probe.key" >/dev/null 2>&1 || return 1
  openssl req -new -x509 -key "${_ptf_dir}/probe.key" -out "${_ptf_dir}/probe.crt" -days 1 \
    -subj "/CN=probe.local" >/dev/null 2>&1 || return 1
  return 0
}

# 探针配置片段（inbounds 数组）
_probe_prog() {
  case "$1" in
    anytls_inbound)
      printf '%s' '[{"type":"anytls","listen":"127.0.0.1","listen_port":1,
        "users":[{"password":"probe"}],
        "tls":{"enabled":true,"certificate_path":"CERT","key_path":"KEY"}}]' ;;
    tuic_inbound)
      printf '%s' '[{"type":"tuic","listen":"127.0.0.1","listen_port":2,
        "users":[{"uuid":"00000000-0000-0000-0000-000000000000","password":"probe"}],
        "zero_rtt_handshake":false,
        "tls":{"enabled":true,"certificate_path":"CERT","key_path":"KEY"}}]' ;;
    hysteria2_inbound)
      printf '%s' '[{"type":"hysteria2","listen":"127.0.0.1","listen_port":3,
        "users":[{"password":"probe"}],
        "tls":{"enabled":true,"certificate_path":"CERT","key_path":"KEY"}}]' ;;
    vmess_ws_transport)
      printf '%s' '[{"type":"vmess","listen":"127.0.0.1","listen_port":4,
        "users":[{"uuid":"00000000-0000-0000-0000-000000000000","alterId":0}],
        "transport":{"type":"ws","path":"/vmess","max_early_data":2048,
                     "early_data_header_name":"Sec-WebSocket-Protocol"},
        "tls":{"enabled":true,"certificate_path":"CERT","key_path":"KEY"}}]' ;;
    vless_reality_inbound)
      printf '%s' '[{"type":"vless","listen":"127.0.0.1","listen_port":5,
        "users":[{"uuid":"00000000-0000-0000-0000-000000000000","flow":"xtls-rprx-vision"}],
        "tls":{"enabled":true,"server_name":"probe.local",
               "reality":{"enabled":true,
                          "handshake":{"server":"probe.local","server_port":443},
                          "private_key":"SCytw0AxhrG8S2HNArRWsXXM6xZup0HdSOa2OExE9Gc",
                          "short_id":["01234567"]}}}]' ;;
    legacy_sniff_field)
      printf '%s' '[{"type":"mixed","listen":"127.0.0.1","listen_port":6,"sniff":true}]' ;;
    *) return 1 ;;
  esac
  return 0
}

# probe_inbound <名字> → true / false / unknown
probe_inbound() {
  local _pi_name="$1" _pi_dir="${ESB_TMP}/probe"
  mkdir -p "$_pi_dir" || { printf 'unknown\n'; return 0; }
  local _pi_prog; _pi_prog="$(_probe_prog "$_pi_name")" || { printf 'unknown\n'; return 0; }
  local _pi_crt="" _pi_key=""
  if printf '%s' "$_pi_prog" | grep -q 'CERT'; then
    if _probe_tls_files "$_pi_dir"; then
      _pi_crt="$_pi_dir/probe.crt"; _pi_key="$_pi_dir/probe.key"
    else
      printf 'unknown\n'; return 0
    fi
  fi
  printf '%s' "$_pi_prog" | jq --arg c "$_pi_crt" --arg k "$_pi_key" \
    'map(if .tls then .tls.certificate_path=$c | .tls.key_path=$k else . end)' \
    >"${_pi_dir}/in.json" 2>/dev/null || { printf 'unknown\n'; return 0; }
  jq -n --slurpfile inb "${_pi_dir}/in.json" \
    '{log:{level:"warn"}, inbounds:$inb[0], outbounds:[{type:"direct",tag:"direct"}]}' \
    >"${_pi_dir}/cfg.json" 2>/dev/null || { printf 'unknown\n'; return 0; }
  if "$ESB_BIN" check -c "${_pi_dir}/cfg.json" >/dev/null 2>&1; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
  return 0
}

probe_capabilities() {
  sb_installed || { log_warn "未安装 sing-box，跳过能力探测"; return 1; }
  jq_ok || { log_warn "缺少 jq，跳过能力探测"; return 1; }
  local _pc_dir="${ESB_TMP}/probe" _pc_cap="${ESB_DIR}/capabilities.json"
  rm -rf "$_pc_dir"; mkdir -p "$_pc_dir" || return 1

  # 控制探针一：最小合法配置必须被接受
  jq -n '{log:{level:"warn"}, outbounds:[{type:"direct",tag:"direct"}]}' >"${_pc_dir}/valid.json"
  if ! "$ESB_BIN" check -c "${_pc_dir}/valid.json" >/dev/null 2>&1; then
    log_warn "控制探针失败：最小合法配置被拒绝（探针路径/二进制有问题），放弃能力探测"
    return 1
  fi
  # 控制探针二：含未知字段的配置必须被拒绝
  jq -n '{log:{level:"warn"}, outbounds:[{type:"direct",tag:"direct"}], easysb_bogus:true}' >"${_pc_dir}/invalid.json"
  if "$ESB_BIN" check -c "${_pc_dir}/invalid.json" >/dev/null 2>&1; then
    log_warn "控制探针失败：非法配置被接受（check 未在真正校验），放弃能力探测"
    return 1
  fi

  local _pc_out='{}' _pc_name _pc_val
  for _pc_name in anytls_inbound tuic_inbound hysteria2_inbound vmess_ws_transport \
                  vless_reality_inbound legacy_sniff_field; do
    _pc_val="$(probe_inbound "$_pc_name")"
    _pc_out="$(printf '%s' "$_pc_out" | jq --arg k "$_pc_name" --arg v "$_pc_val" '. + {($k):$v}')"
  done
  _pc_out="$(printf '%s' "$_pc_out" | jq --arg v "$(sb_version)" '. + {version:$v, probed_at:(now|todate)}')"
  printf '%s\n' "$_pc_out" | json_write "$_pc_cap" 600 && log_ok "能力探测结果已写入：$_pc_cap"
  return 0
}

# ---------------------------------------------------------------------------
# systemd unit / 服务
# ---------------------------------------------------------------------------
unit_install() {
  if [ "${ESB_INIT:-systemd}" = "systemd" ]; then
    mkdir -p "$ESB_UNIT_DIR" || return 1
    local _unit_file="${ESB_UNIT_DIR}/sing-box.service"
    cat <<EOF | file_write "$_unit_file" 644
[Unit]
Description=sing-box service (EasySB)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
User=sing-box
StateDirectory=sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=${ESB_BIN} -D ${ESB_STATE_DIR} -C ${ESB_CONF_DIR} run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    run_gate "systemctl daemon-reload" systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
  fi
  # openrc / sysvinit 兜底
  local _init_dir="${ESB_ROOT:-}/etc/init.d"
  mkdir -p "$_init_dir" 2>/dev/null || return 1
  cat <<EOF | file_write "${_init_dir}/sing-box" 755
#!/bin/sh
### BEGIN INIT INFO
# Provides:          sing-box
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: sing-box service (EasySB)
### END INIT INFO
DAEMON="${ESB_BIN}"
ARGS="-D ${ESB_STATE_DIR} -C ${ESB_CONF_DIR} run"
PIDFILE="/var/run/sing-box.pid"
case "\$1" in
  start)   "\$DAEMON" \$ARGS & echo \$! >"\$PIDFILE" ;;
  stop)    [ -f "\$PIDFILE" ] && kill "\$(cat "\$PIDFILE")" && rm -f "\$PIDFILE" ;;
  restart) "\$0" stop; sleep 1; "\$0" start ;;
  status)  [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null ;;
  *)       echo "用法: \$0 {start|stop|restart|status}"; exit 2 ;;
esac
exit 0
EOF
  log_info "已安装 init.d 脚本：${_init_dir}/sing-box"
  return 0
}

unit_remove() {
  if [ "${ESB_INIT:-systemd}" = "systemd" ]; then
    rm -f "${ESB_UNIT_DIR}/sing-box.service" 2>/dev/null || true
    run_gate "systemctl daemon-reload" systemctl daemon-reload >/dev/null 2>&1 || true
  else
    rm -f "${ESB_ROOT:-}/etc/init.d/sing-box" 2>/dev/null || true
  fi
  return 0
}

sb_service() { service_mgr sing-box "${1:-status}"; }

sb_running() { sb_service status; }

sb_status_line() {
  local _ssl_state="未运行" _ssl_ver _ssl_enabled
  if sb_running; then _ssl_state="${C_GREEN}运行中${C_RESET}"; else _ssl_state="${C_RED}未运行${C_RESET}"; fi
  _ssl_ver="$(sb_version)"; [ -n "$_ssl_ver" ] || _ssl_ver="未安装"
  printf '  sing-box                 : %b（内核 %s）\n' "$_ssl_state" "$_ssl_ver"
  local _ssl_p _ssl_ports=""
  for _ssl_p in $(proto_enabled_list); do
    _ssl_ports="$_ssl_ports ${_ssl_p}:$(proto_port "$_ssl_p")"
  done
  printf '  已启用协议               :%s\n' "${_ssl_ports:- 无}"
  _ssl_enabled="$(state_get .domain)"
  printf '  域名                     : %s\n' "${_ssl_enabled:-未设置}"
  return 0
}

# ---------------------------------------------------------------------------
# 卸载内核
# ---------------------------------------------------------------------------
sb_uninstall() {
  sb_service stop >/dev/null 2>&1 || true
  sb_service disable >/dev/null 2>&1 || true
  unit_remove
  if sb_installed; then
    local _sb_uninstall_ver; _sb_uninstall_ver="$(sb_version)"
    mkdir -p "$ESB_BACKUP_DIR" 2>/dev/null || true
    [ -n "$_sb_uninstall_ver" ] && cp -p "$ESB_BIN" "${ESB_BACKUP_DIR}/sing-box.${_sb_uninstall_ver}" 2>/dev/null
    rm -f "$ESB_BIN" 2>/dev/null || true
    log_ok "内核已卸载（备份保留在 ${ESB_BACKUP_DIR}）"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 脚本自更新
# ---------------------------------------------------------------------------
esb_self_path() {
  local _esp="${ESB_SELF:-}"
  if [ -z "$_esp" ] && [ -n "${BASH_SOURCE[0]:-}" ]; then
    _esp="${BASH_SOURCE[0]}"
  fi
  [ -n "$_esp" ] || return 1
  case "$_esp" in
    /dev/fd/*|/proc/*) return 1 ;;
  esac
  [ -f "$_esp" ] || return 1
  printf '%s\n' "$_esp"
  return 0
}

script_update() {
  local _su_url="https://raw.githubusercontent.com/${ESB_REPO}/${ESB_REPO_BRANCH}/EasySB/dist/easysb.sh"
  local _su_tmp="${ESB_TMP}/easysb.sh.new" _su_self="" _su_newver
  log_info "检查脚本更新…"
  _su_newver="$(script_latest_version)"
  if [ -n "$_su_newver" ]; then
    log_info "仓库脚本版本：v${_su_newver}　当前版本：v${ESB_SCRIPT_VERSION}"
    if [ "$(version_norm "$_su_newver")" = "$(version_norm "$ESB_SCRIPT_VERSION")" ]; then
      log_ok "脚本已是最新版本"
      return 0
    fi
  else
    log_warn "无法从仓库读取版本号，将直接尝试下载最新脚本"
  fi
  if ! http_get "$_su_url" "$_su_tmp"; then
    error "下载脚本失败：$_su_url"
    return 1
  fi
  if ! bash -n "$_su_tmp"; then
    error "下载的脚本语法校验未通过，已中止更新（保留原脚本）"
    rm -f "$_su_tmp"
    return 1
  fi
  _su_self="$(esb_self_path || true)"
  if [ -z "$_su_self" ]; then
    log_warn "当前以管道方式运行（$(printf '%s' "${BASH_SOURCE[0]:-未知}")），无法原地替换"
    log_info "新版脚本已保存到：$_su_tmp"
    return 0
  fi
  mkdir -p "$ESB_BACKUP_DIR" 2>/dev/null || true
  cp -p "$_su_self" "${ESB_BACKUP_DIR}/easysb.sh.$(esb_ts)" 2>/dev/null || true
  if ! run_gate "替换脚本" install -m 0755 "$_su_tmp" "${_su_self}.new"; then
    cp -f "$_su_tmp" "${_su_self}.new" || { error "写入新脚本失败"; return 1; }
    chmod 755 "${_su_self}.new" 2>/dev/null || true
  fi
  mv -f "${_su_self}.new" "$_su_self" || { error "替换脚本失败"; return 1; }
  log_ok "脚本已更新到 v${_su_newver:-最新}，旧版本备份在 ${ESB_BACKUP_DIR}"
  log_info "请重新运行脚本以使用新版本"
  return 0
}


# ===== 内联模块：lib/60-firewall.sh =====
#!/usr/bin/env bash
# =============================================================================
# EasySB — 60-firewall.sh
# 防火墙：后端探测 / 只增删本工具打标签的放行规则 / 端口跳跃（UDP 重定向）
# 依赖：00-core.sh, 10-detect.sh, 20-state.sh
#
# 硬性约束（docs/INTERFACES.md §0 规则 3）：
#   * 只增删本工具自己打标签的规则，绝不清空/重置任何表，绝不 `ufw disable`，
#     绝不关闭 firewalld/SELinux，绝不碰别人的规则：
#       ufw        → 规则一律带 `comment EasySB` 标签；删除时优先按编号定位带标签的规则
#       firewalld  → 端口按默认 zone 增删（--add-port/--remove-port），同时在 state 登记
#       nftables   → 本工具专用表 `inet easysb`（自有链 input / prerouting），
#                    回收只需 `nft delete table inet easysb`，永远不需要 `nft flush ruleset`
#       iptables   → 自有链 EASYSB_IN（filter）/ EASYSB_HOP（nat）；绝不 -F 内建链，
#                    跳转只插入/删除本工具自己的那一条
#   * 所有系统变更命令一律走 run_gate（ESB_GATE=1 时只记录不执行）。
#   * UI 能调用的函数一律 `error "…"; return 1`，绝不 exit。
#   * 卸载（fw_revert_all）必须回收全部规则，含端口跳跃的重定向。
#
# 端口范围写法随后端不同：nft/ufw → `20000-30000`，iptables → `20000:30000`，firewalld → `20000-30000`。
# 状态登记：.firewall.backend / .firewall.rules[]="<port>/<tcp|udp>" / .firewall.hop{enabled,range,to_port}
# =============================================================================
# shellcheck shell=bash

# ufw 规则注释标签（= 本工具的“所有权”标记）
ESB_FW_TAG="EasySB"
# nft 专用表：family + 表名
ESB_FW_NFT_FAMILY="inet"
ESB_FW_NFT_NAME="easysb"
# iptables 专用链
ESB_FW_IPT_CHAIN="EASYSB_IN"       # filter 表：放行规则
ESB_FW_IPT_HOP_CHAIN="EASYSB_HOP"  # nat 表：端口跳跃重定向

# ---------------------------------------------------------------------------
# 规则记录（state.firewall.rules）小工具
# ---------------------------------------------------------------------------
_fw_rule_key() { printf '%s/%s\n' "$1" "$2"; }

# 传输协议校验（只返回状态，不 exit）
_fw_transport_valid() {
  case "${1-}" in
    tcp|udp) return 0 ;;
    '') error "传输协议不能为空（tcp|udp）"; return 1 ;;
    *) error "传输协议必须是 tcp 或 udp：$1"; return 1 ;;
  esac
}

# stdout：state 中登记的规则，每行一条；无记录时输出空
_fw_rules_list() {
  state_get_raw '(.firewall.rules // [])[]?' | tr -d '\r'
  return 0
}

# stdin：每行一条规则 → 去重排序后写入 state.firewall.rules
_fw_rules_set() {
  local _fw_rs_json=""
  _fw_rs_json="$(grep -v '^[[:space:]]*$' | sort -u | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null || true)"
  [ -n "$_fw_rs_json" ] || _fw_rs_json='[]'
  state_set .firewall.rules "$_fw_rs_json" || return 1
  return 0
}

_fw_rules_add() {
  local _fw_ra_key="$1"
  { _fw_rules_list; printf '%s\n' "$_fw_ra_key"; } | _fw_rules_set
}

_fw_rules_del() {
  local _fw_rd_key="$1"
  { _fw_rules_list | grep -vxF "$_fw_rd_key"; } | _fw_rules_set
}

# 0 = 该规则已登记（说明本工具已放过这条）
_fw_rule_recorded() {
  local _fw_rr_key="$1"
  local _fw_rr_all=""
  _fw_rr_all=" $(printf '%s' "$(_fw_rules_list | tr '\n' ' ')") "
  case "$_fw_rr_all" in
    *" $_fw_rr_key "*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# 后端探测
# ---------------------------------------------------------------------------
# 只探测、绝不写 state —— fw_status 这类只读路径必须用它（用 fw_backend 会写状态）
_fw_detect_backend() {
  local _fw_db_out=""
  # 1) ufw（已启用）
  if cmd_exists ufw; then
    _fw_db_out="$(ufw status 2>/dev/null | tr -d '\r' || true)"
    case "$_fw_db_out" in
      *"Status: active"*) printf 'ufw\n'; return 0 ;;
    esac
  fi
  # 2) firewalld（运行中）
  if cmd_exists firewall-cmd; then
    _fw_db_out="$(firewall-cmd --state 2>/dev/null | tr -d '\r\n ' || true)"
    if [ "$_fw_db_out" = "running" ]; then printf 'firewalld\n'; return 0; fi
  fi
  # 3) nftables（nft 存在且能读规则集）
  if cmd_exists nft; then
    if nft list ruleset >/dev/null 2>&1; then printf 'nftables\n'; return 0; fi
  fi
  # 4) iptables
  if cmd_exists iptables; then printf 'iptables\n'; return 0; fi
  printf 'none\n'
  return 0
}

# stdout：ufw|firewalld|nftables|iptables|none；结果持久化到 .firewall.backend
# 优先级：$ESB_FW_BACKEND 覆盖 > ufw > firewalld > nftables > iptables > none
fw_backend() {
  local _fw_b_backend="${ESB_FW_BACKEND:-}"
  if [ -z "$_fw_b_backend" ]; then
    _fw_b_backend="$(_fw_detect_backend)"
  fi
  case "$_fw_b_backend" in
    ufw|firewalld|nftables|iptables|none) ;;
    *) error "不支持的防火墙后端：$_fw_b_backend（可选 ufw|firewalld|nftables|iptables|none）"; return 1 ;;
  esac
  if [ -n "${ESB_STATE:-}" ] && [ -f "$ESB_STATE" ]; then
    state_set_str ".firewall.backend" "$_fw_b_backend" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$_fw_b_backend"
  return 0
}

# 变更路径用的后端：优先用实时探测结果；实时探测不到但 state 里有记录（工具被卸载等）时沿用记录
_fw_backend_for_change() {
  local _fw_bfc_backend=""
  _fw_bfc_backend="$(fw_backend)" || return 1
  if [ "$_fw_bfc_backend" = "none" ]; then
    _fw_bfc_backend="$(state_get .firewall.backend)"
    [ -n "$_fw_bfc_backend" ] || _fw_bfc_backend="none"
  fi
  printf '%s\n' "$_fw_bfc_backend"
  return 0
}

# ---------------------------------------------------------------------------
# ufw
# ---------------------------------------------------------------------------
_fw_ufw_open() {
  local _fw_uo_port="$1"
  local _fw_uo_proto="$2"
  run_gate "ufw 放行 ${_fw_uo_port}/${_fw_uo_proto}" \
    ufw allow "${_fw_uo_port}/${_fw_uo_proto}" comment "$ESB_FW_TAG" || return 1
  return 0
}

# 删除：优先按编号定位“带 EasySB 标签”的规则（绝对不会误删别人同端口的规则）；
# 定位不到（例如 ESB_GATE=1 只记录不执行时读不到真实规则）时按规则本体删除。
_fw_ufw_close() {
  local _fw_uc_port="$1"
  local _fw_uc_proto="$2"
  local _fw_uc_spec="${_fw_uc_port}/${_fw_uc_proto}"
  local _fw_uc_nums=""
  local _fw_uc_n=""
  _fw_uc_nums="$(ufw status numbered 2>/dev/null | tr -d '\r' \
      | grep -F "$ESB_FW_TAG" \
      | grep -E "(^|[^0-9])${_fw_uc_port}/${_fw_uc_proto}" \
      | sed -n 's/^\[[[:space:]]*\([0-9][0-9]*\)\].*/\1/p' | sort -rn || true)"
  if [ -n "$_fw_uc_nums" ]; then
    for _fw_uc_n in $_fw_uc_nums; do
      # 编号从大到小删除，避免删除过程中编号前移
      run_gate "ufw 删除规则 #$_fw_uc_n（$_fw_uc_spec，标签 $ESB_FW_TAG）" \
        ufw --force delete "$_fw_uc_n" || log_warn "ufw 删除规则 #$_fw_uc_n 失败"
    done
    return 0
  fi
  run_gate "ufw 关闭 $_fw_uc_spec" ufw delete allow "$_fw_uc_spec" \
    || log_warn "ufw 删除规则 $_fw_uc_spec 失败（可能已不存在）"
  return 0
}

# ---------------------------------------------------------------------------
# firewalld
# ---------------------------------------------------------------------------
_fw_firewalld_zone() {
  local _fw_fz_zone=""
  _fw_fz_zone="$(firewall-cmd --get-default-zone 2>/dev/null | tr -d '\r\n ' || true)"
  [ -n "$_fw_fz_zone" ] || _fw_fz_zone="public"
  printf '%s\n' "$_fw_fz_zone"
  return 0
}

_fw_firewalld_open() {
  local _fw_fo_port="$1"
  local _fw_fo_proto="$2"
  local _fw_fo_zone=""
  _fw_fo_zone="$(_fw_firewalld_zone)"
  run_gate "firewalld 放行 ${_fw_fo_port}/${_fw_fo_proto}（zone=${_fw_fo_zone}）" \
    firewall-cmd --permanent --zone="$_fw_fo_zone" --add-port="${_fw_fo_port}/${_fw_fo_proto}" || return 1
  run_gate "firewalld 重载规则" firewall-cmd --reload || return 1
  return 0
}

_fw_firewalld_close() {
  local _fw_fc_port="$1"
  local _fw_fc_proto="$2"
  local _fw_fc_zone=""
  _fw_fc_zone="$(_fw_firewalld_zone)"
  run_gate "firewalld 关闭 ${_fw_fc_port}/${_fw_fc_proto}（zone=${_fw_fc_zone}）" \
    firewall-cmd --permanent --zone="$_fw_fc_zone" --remove-port="${_fw_fc_port}/${_fw_fc_proto}" \
    || log_warn "firewalld 移除端口 ${_fw_fc_port}/${_fw_fc_proto} 失败（可能已不存在）"
  run_gate "firewalld 重载规则" firewall-cmd --reload || log_warn "firewalld 重载失败"
  return 0
}

# ---------------------------------------------------------------------------
# nftables（专用表 inet easysb）
# ---------------------------------------------------------------------------
# 链不存在才创建（add 是幂等的，但链已存在时重复 add 会报错，所以先查）
_fw_nft_chain_ensure() {
  local _fw_nce_chain="$1"
  local _fw_nce_spec="$2"
  if nft list chain "$ESB_FW_NFT_FAMILY" "$ESB_FW_NFT_NAME" "$_fw_nce_chain" >/dev/null 2>&1; then
    return 0
  fi
  run_gate "nft 创建专用表 ${ESB_FW_NFT_FAMILY} ${ESB_FW_NFT_NAME}" \
    nft add table "$ESB_FW_NFT_FAMILY" "$ESB_FW_NFT_NAME" || return 1
  run_gate "nft 创建链 $_fw_nce_chain" \
    nft add chain "$ESB_FW_NFT_FAMILY" "$ESB_FW_NFT_NAME" "$_fw_nce_chain" "$_fw_nce_spec" || return 1
  return 0
}

# 按 handle 精确定位（列表里带 `# handle N` 才能定位）
_fw_nft_handle_for() {
  local _fw_nhf_chain="$1"
  local _fw_nhf_proto="$2"
  local _fw_nhf_dport="$3"
  local _fw_nhf_out=""
  local _fw_nhf_line=""
  local _fw_nhf_handle=""
  _fw_nhf_out="$(nft -a list chain "$ESB_FW_NFT_FAMILY" "$ESB_FW_NFT_NAME" "$_fw_nhf_chain" 2>/dev/null | tr -d '\r' || true)"
  [ -n "$_fw_nhf_out" ] || return 1
  _fw_nhf_line="$(printf '%s\n' "$_fw_nhf_out" | grep -F "$_fw_nhf_proto dport $_fw_nhf_dport" | head -1 || true)"
  [ -n "$_fw_nhf_line" ] || return 1
  _fw_nhf_handle="$(printf '%s\n' "$_fw_nhf_line" | sed -n 's/.*# handle \([0-9][0-9]*\).*/\1/p' || true)"
  [ -n "$_fw_nhf_handle" ] || return 1
  printf '%s\n' "$_fw_nhf_handle"
  return 0
}

_fw_nft_open() {
  local _fw_no_port="$1"
  local _fw_no_proto="$2"
  _fw_nft_chain_ensure input '{ type filter hook input priority 0 ; policy accept ; }' || return 1
  run_gate "nft 放行 ${_fw_no_port}/${_fw_no_proto}" \
    nft add rule "$ESB_FW_NFT_FAMILY" "$ESB_FW_NFT_NAME" input "$_fw_no_proto" dport "$_fw_no_port" accept comment "$ESB_FW_TAG" \
    || return 1
  return 0
}

_fw_nft_close() {
  local _fw_nc_port="$1"
  local _fw_nc_proto="$2"
  local _fw_nc_handle=""
  _fw_nc_handle="$(_fw_nft_handle_for input "$_fw_nc_proto" "$_fw_nc_port" || true)"
  if [ -n "$_fw_nc_handle" ]; then
    run_gate "nft 删除规则 handle $_fw_nc_handle（${_fw_nc_proto} dport ${_fw_nc_port}）" \
      nft delete rule "$ESB_FW_NFT_FAMILY" "$ESB_FW_NFT_NAME" input handle "$_fw_nc_handle" \
      || log_warn "nft 删除规则 handle $_fw_nc_handle 失败"
    return 0
  fi
  run_gate "nft 关闭 ${_fw_nc_proto} dport ${_fw_nc_port}" \
    nft delete rule "$ESB_FW_NFT_FAMILY" "$ESB_FW_NFT_NAME" input "$_fw_nc_proto" dport "$_fw_nc_port" accept comment "$ESB_FW_TAG" \
    || log_warn "nft 删除规则 ${_fw_nc_proto} dport ${_fw_nc_port} 失败（可能已不存在）"
  return 0
}

# 回收整个专用表：表里只有本工具的链与规则
_fw_nft_reclaim() {
  run_gate "nft 回收专用表 ${ESB_FW_NFT_FAMILY} ${ESB_FW_NFT_NAME}" \
    nft delete table "$ESB_FW_NFT_FAMILY" "$ESB_FW_NFT_NAME" \
    || log_warn "删除 nft 表 ${ESB_FW_NFT_FAMILY} ${ESB_FW_NFT_NAME} 失败（可能不存在）"
  return 0
}

# ---------------------------------------------------------------------------
# iptables（自有链，绝不 -F 内建链）
# ---------------------------------------------------------------------------
_fw_ipt_chain_ensure() {
  local _fw_ice_table="$1"
  local _fw_ice_chain="$2"
  if iptables -w -t "$_fw_ice_table" -n -L "$_fw_ice_chain" >/dev/null 2>&1; then
    return 0
  fi
  run_gate "iptables 创建链 $_fw_ice_chain（$_fw_ice_table 表）" \
    iptables -w -t "$_fw_ice_table" -N "$_fw_ice_chain" || return 1
  return 0
}

# 只插入/复用“指向本工具自有链”的那一条跳转
_fw_ipt_jump_ensure() {
  local _fw_ije_table="$1"
  local _fw_ije_chain="$2"
  local _fw_ije_target="$3"
  if iptables -w -t "$_fw_ije_table" -C "$_fw_ije_chain" -j "$_fw_ije_target" >/dev/null 2>&1; then
    return 0
  fi
  run_gate "iptables 在 $_fw_ije_chain 插入跳转到 $_fw_ije_target" \
    iptables -w -t "$_fw_ije_table" -I "$_fw_ije_chain" 1 -j "$_fw_ije_target" || return 1
  return 0
}

_fw_ipt_open() {
  local _fw_io_port="$1"
  local _fw_io_proto="$2"
  _fw_ipt_chain_ensure filter "$ESB_FW_IPT_CHAIN" || return 1
  _fw_ipt_jump_ensure filter INPUT "$ESB_FW_IPT_CHAIN" || return 1
  run_gate "iptables 放行 ${_fw_io_port}/${_fw_io_proto}" \
    iptables -w -t filter -A "$ESB_FW_IPT_CHAIN" -p "$_fw_io_proto" --dport "$_fw_io_port" -j ACCEPT || return 1
  return 0
}

_fw_ipt_close() {
  local _fw_ic_port="$1"
  local _fw_ic_proto="$2"
  run_gate "iptables 关闭 ${_fw_ic_port}/${_fw_ic_proto}" \
    iptables -w -t filter -D "$ESB_FW_IPT_CHAIN" -p "$_fw_ic_proto" --dport "$_fw_ic_port" -j ACCEPT \
    || log_warn "iptables 删除规则 ${_fw_ic_port}/${_fw_ic_proto} 失败（可能已不存在）"
  return 0
}

# 回收 filter 链：先摘跳转，再删（此时应为空链）
_fw_ipt_reclaim() {
  run_gate "iptables 移除 INPUT → ${ESB_FW_IPT_CHAIN} 跳转" \
    iptables -w -t filter -D INPUT -j "$ESB_FW_IPT_CHAIN" \
    || log_warn "iptables 移除 INPUT 跳转失败（可能不存在）"
  run_gate "iptables 删除 filter 链 ${ESB_FW_IPT_CHAIN}" \
    iptables -w -t filter -X "$ESB_FW_IPT_CHAIN" \
    || log_warn "iptables 删除链 ${ESB_FW_IPT_CHAIN} 失败（可能不存在或非空）"
  return 0
}

# ---------------------------------------------------------------------------
# 单条规则的增删分发
# ---------------------------------------------------------------------------
_fw_open_one() {
  local _fw_oo_backend="$1"
  local _fw_oo_port="$2"
  local _fw_oo_proto="$3"
  case "$_fw_oo_backend" in
    ufw)       _fw_ufw_open       "$_fw_oo_port" "$_fw_oo_proto" ;;
    firewalld) _fw_firewalld_open "$_fw_oo_port" "$_fw_oo_proto" ;;
    nftables)  _fw_nft_open       "$_fw_oo_port" "$_fw_oo_proto" ;;
    iptables)  _fw_ipt_open       "$_fw_oo_port" "$_fw_oo_proto" ;;
    *) error "不支持的防火墙后端，无法放行：$_fw_oo_backend"; return 1 ;;
  esac
}

_fw_close_one() {
  local _fw_co_backend="$1"
  local _fw_co_port="$2"
  local _fw_co_proto="$3"
  case "$_fw_co_backend" in
    ufw)       _fw_ufw_close       "$_fw_co_port" "$_fw_co_proto" ;;
    firewalld) _fw_firewalld_close "$_fw_co_port" "$_fw_co_proto" ;;
    nftables)  _fw_nft_close       "$_fw_co_port" "$_fw_co_proto" ;;
    iptables)  _fw_ipt_close       "$_fw_co_port" "$_fw_co_proto" ;;
    *) error "不支持的防火墙后端，无法关闭：$_fw_co_backend"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 公共 API：放行 / 关闭单条规则
# ---------------------------------------------------------------------------
# 只添加带 EasySB 标签的规则；重复调用幂等（不会重复下发，也不会重复登记）
fw_open() {
  local _fw_open_port="${1-}"
  local _fw_open_proto="${2-}"
  local _fw_open_key=""
  local _fw_open_backend=""
  _fw_transport_valid "$_fw_open_proto" || return 1
  validate_port "$_fw_open_port" || return 1
  _fw_open_key="$(_fw_rule_key "$_fw_open_port" "$_fw_open_proto")"
  _fw_open_backend="$(_fw_backend_for_change)" || return 1
  if [ "$_fw_open_backend" = "none" ]; then
    log_warn "未检测到可用的防火墙（ufw/firewalld/nftables/iptables），跳过放行 ${_fw_open_key}"
    return 0
  fi
  if _fw_rule_recorded "$_fw_open_key"; then
    log_debug "规则已在记录中，跳过：$_fw_open_key"
    return 0
  fi
  if ! _fw_open_one "$_fw_open_backend" "$_fw_open_port" "$_fw_open_proto"; then
    error "防火墙放行失败：$_fw_open_key（后端 $_fw_open_backend）"
    return 1
  fi
  if ! _fw_rules_add "$_fw_open_key"; then
    # 登记失败 = 卸载时无法回收，立刻回滚刚下发的规则
    error "无法在 state 中登记规则 $_fw_open_key，正在回滚该规则"
    _fw_close_one "$_fw_open_backend" "$_fw_open_port" "$_fw_open_proto" >/dev/null 2>&1 || true
    return 1
  fi
  log_ok "防火墙已放行：$_fw_open_key（$_fw_open_backend）"
  return 0
}

# 只关闭本工具登记过的规则；从没登记过的直接跳过（绝不碰别人的规则）
fw_close() {
  local _fw_close_port="${1-}"
  local _fw_close_proto="${2-}"
  local _fw_close_key=""
  local _fw_close_backend=""
  _fw_transport_valid "$_fw_close_proto" || return 1
  validate_port "$_fw_close_port" || return 1
  _fw_close_key="$(_fw_rule_key "$_fw_close_port" "$_fw_close_proto")"
  if ! _fw_rule_recorded "$_fw_close_key"; then
    log_debug "规则不在本工具记录中，跳过：$_fw_close_key"
    return 0
  fi
  _fw_close_backend="$(_fw_backend_for_change)" || return 1
  if [ "$_fw_close_backend" = "none" ]; then
    log_warn "未检测到可用的防火墙，无法关闭 $_fw_close_key（记录保留，稍后可重试）"
    return 1
  fi
  _fw_close_one "$_fw_close_backend" "$_fw_close_port" "$_fw_close_proto" || {
    log_warn "关闭 $_fw_close_key 失败（记录保留，稍后可重试）"
    return 1
  }
  _fw_rules_del "$_fw_close_key" || { log_warn "规则记录更新失败：$_fw_close_key"; return 1; }
  log_ok "防火墙已关闭：$_fw_close_key（$_fw_close_backend）"
  return 0
}

# ---------------------------------------------------------------------------
# 依据 state 计算需要的端口
# ---------------------------------------------------------------------------
# stdout：每行一条 "<port>/<tcp|udp>"（协议端口 + 伪装站点端口）
_fw_required_rules() {
  local _fw_rr_p=""
  local _fw_rr_port=""
  local _fw_rr_trans=""
  for _fw_rr_p in $(proto_enabled_list); do
    _fw_rr_port="$(state_get ".protocols[\"$_fw_rr_p\"].port")"
    [ -n "$_fw_rr_port" ] || continue
    case "$_fw_rr_p" in
      hysteria2|tuic) _fw_rr_trans="udp" ;;
      *)              _fw_rr_trans="tcp" ;;
    esac
    printf '%s/%s\n' "$_fw_rr_port" "$_fw_rr_trans"
  done
  if [ "$(state_get .web.enabled)" = "true" ]; then
    _fw_rr_port="$(state_get .web.http_port)"
    [ -n "$_fw_rr_port" ] && printf '%s/tcp\n' "$_fw_rr_port"
    if [ "$(state_get .web.tls)" = "true" ]; then
      _fw_rr_port="$(state_get .web.tls_port)"
      [ -n "$_fw_rr_port" ] && printf '%s/tcp\n' "$_fw_rr_port"
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 公共 API：全量同步
# ---------------------------------------------------------------------------
fw_apply_all() {
  local _fw_aa_backend=""
  local _fw_aa_want=""
  local _fw_aa_want_flat=""
  local _fw_aa_have=""
  local _fw_aa_key=""
  local _fw_aa_port=""
  local _fw_aa_proto=""
  local _fw_aa_opened=0
  local _fw_aa_closed=0
  local _fw_aa_hop_enabled=""
  local _fw_aa_hop_range=""
  local _fw_aa_hop_to=""
  _fw_aa_backend="$(fw_backend)" || return 1
  if [ "$_fw_aa_backend" = "none" ]; then
    log_warn "未检测到可用的防火墙（ufw/firewalld/nftables/iptables），跳过端口放行"
    return 0
  fi

  _fw_aa_want="$(_fw_required_rules)"
  _fw_aa_want_flat=" $(printf '%s' "$_fw_aa_want" | tr '\n' ' ') "

  # 1) 放行缺失的端口
  # shellcheck disable=SC2086
  for _fw_aa_key in $_fw_aa_want; do
    _fw_aa_port="${_fw_aa_key%%/*}"
    _fw_aa_proto="${_fw_aa_key##*/}"
    if _fw_rule_recorded "$_fw_aa_key"; then continue; fi
    if ! fw_open "$_fw_aa_port" "$_fw_aa_proto"; then
      error "放行端口失败：$_fw_aa_key"
      return 1
    fi
    _fw_aa_opened=$((_fw_aa_opened + 1))
  done

  # 2) 关闭 state 中已不再需要的端口
  _fw_aa_have="$(_fw_rules_list)"
  # shellcheck disable=SC2086
  for _fw_aa_key in $_fw_aa_have; do
    case "$_fw_aa_want_flat" in
      *" $_fw_aa_key "*) continue ;;
    esac
    _fw_aa_port="${_fw_aa_key%%/*}"
    _fw_aa_proto="${_fw_aa_key##*/}"
    if fw_close "$_fw_aa_port" "$_fw_aa_proto"; then
      _fw_aa_closed=$((_fw_aa_closed + 1))
    fi
  done

  # 3) 端口跳跃：需要则下发 UDP 重定向，不需要则回收
  _fw_aa_hop_enabled="$(state_get '.protocols.hysteria2.hop.enabled')"
  _fw_aa_hop_range="$(state_get '.protocols.hysteria2.hop.range')"
  if [ "$_fw_aa_hop_enabled" = "true" ] && proto_enabled hysteria2; then
    _fw_aa_hop_to="$(proto_port hysteria2)"
    if ! fw_hop_apply "$_fw_aa_hop_range" "$_fw_aa_hop_to"; then
      error "应用端口跳跃失败（$_fw_aa_hop_range → $_fw_aa_hop_to）"
      return 1
    fi
  else
    fw_hop_clear >/dev/null 2>&1 || log_warn "端口跳跃规则回收失败（可稍后重试）"
  fi

  log_ok "防火墙已同步（$_fw_aa_backend）：新增 $_fw_aa_opened 条，回收 $_fw_aa_closed 条"
  return 0
}

# ---------------------------------------------------------------------------
# 端口跳跃（UDP 端口范围重定向到真实端口）
# ---------------------------------------------------------------------------
# nft：专用表里的 prerouting 链（`udp dport 20000-30000 redirect to :443`）
_fw_hop_nft_apply() {
  local _fw_hna_a="$1"
  local _fw_hna_b="$2"
  local _fw_hna_to="$3"
  _fw_nft_chain_ensure prerouting '{ type nat hook prerouting priority dstnat ; policy accept ; }' || return 1
  run_gate "nft 端口跳跃 udp ${_fw_hna_a}-${_fw_hna_b} → ${_fw_hna_to}" \
    nft add rule "$ESB_FW_NFT_FAMILY" "$ESB_FW_NFT_NAME" prerouting udp dport "${_fw_hna_a}-${_fw_hna_b}" redirect to ":${_fw_hna_to}" \
    || return 1
  return 0
}

_fw_hop_nft_clear() {
  local _fw_hnc_a="$1"
  local _fw_hnc_b="$2"
  local _fw_hnc_to="$3"
  local _fw_hnc_handle=""
  _fw_hnc_handle="$(_fw_nft_handle_for prerouting udp "${_fw_hnc_a}-${_fw_hnc_b}" || true)"
  if [ -n "$_fw_hnc_handle" ]; then
    run_gate "nft 删除端口跳跃规则 handle $_fw_hnc_handle（udp ${_fw_hnc_a}-${_fw_hnc_b}）" \
      nft delete rule "$ESB_FW_NFT_FAMILY" "$ESB_FW_NFT_NAME" prerouting handle "$_fw_hnc_handle" \
      || log_warn "nft 删除端口跳跃规则 handle $_fw_hnc_handle 失败"
    return 0
  fi
  run_gate "nft 删除端口跳跃规则 udp ${_fw_hnc_a}-${_fw_hnc_b}" \
    nft delete rule "$ESB_FW_NFT_FAMILY" "$ESB_FW_NFT_NAME" prerouting udp dport "${_fw_hnc_a}-${_fw_hnc_b}" redirect to ":${_fw_hnc_to}" \
    || log_warn "nft 删除端口跳跃规则失败（可能已不存在）"
  return 0
}

# iptables：nat 表自有链 EASYSB_HOP + PREROUTING 上唯一一条跳转
_fw_hop_ipt_apply() {
  local _fw_hia_a="$1"
  local _fw_hia_b="$2"
  local _fw_hia_to="$3"
  _fw_ipt_chain_ensure nat "$ESB_FW_IPT_HOP_CHAIN" || return 1
  _fw_ipt_jump_ensure nat PREROUTING "$ESB_FW_IPT_HOP_CHAIN" || return 1
  run_gate "iptables 端口跳跃 udp ${_fw_hia_a}:${_fw_hia_b} → ${_fw_hia_to}" \
    iptables -w -t nat -A "$ESB_FW_IPT_HOP_CHAIN" -p udp --dport "${_fw_hia_a}:${_fw_hia_b}" -j REDIRECT --to-ports "$_fw_hia_to" \
    || return 1
  return 0
}

_fw_hop_ipt_clear() {
  local _fw_hic_a="$1"
  local _fw_hic_b="$2"
  local _fw_hic_to="$3"
  run_gate "iptables 删除端口跳跃重定向 udp ${_fw_hic_a}:${_fw_hic_b}" \
    iptables -w -t nat -D "$ESB_FW_IPT_HOP_CHAIN" -p udp --dport "${_fw_hic_a}:${_fw_hic_b}" -j REDIRECT --to-ports "$_fw_hic_to" \
    || log_warn "iptables 删除端口跳跃规则失败（可能已不存在）"
  # 只摘掉“指向本工具自有链”的那一条跳转
  run_gate "iptables 移除 PREROUTING → ${ESB_FW_IPT_HOP_CHAIN} 跳转" \
    iptables -w -t nat -D PREROUTING -j "$ESB_FW_IPT_HOP_CHAIN" \
    || log_warn "iptables 移除 PREROUTING 跳转失败（可能已不存在）"
  run_gate "iptables 删除 nat 链 ${ESB_FW_IPT_HOP_CHAIN}" \
    iptables -w -t nat -X "$ESB_FW_IPT_HOP_CHAIN" \
    || log_warn "iptables 删除链 ${ESB_FW_IPT_HOP_CHAIN} 失败（可能不存在或非空）"
  return 0
}

# ufw 自身无法做 REDIRECT：放行整个 UDP 范围，再借本机 iptables 补一条重定向
_fw_hop_ufw_apply() {
  local _fw_hua_a="$1"
  local _fw_hua_b="$2"
  local _fw_hua_to="$3"
  run_gate "ufw 放行端口跳跃范围 udp ${_fw_hua_a}:${_fw_hua_b}" \
    ufw allow "${_fw_hua_a}:${_fw_hua_b}/udp" comment "$ESB_FW_TAG" || return 1
  if cmd_exists iptables; then
    _fw_hop_ipt_apply "$_fw_hua_a" "$_fw_hua_b" "$_fw_hua_to" || return 1
  else
    log_warn "本机没有 iptables，端口跳跃只能放行端口范围、无法重定向到 $_fw_hua_to"
  fi
  return 0
}

_fw_hop_ufw_clear() {
  local _fw_huc_a="$1"
  local _fw_huc_b="$2"
  local _fw_huc_to="$3"
  run_gate "ufw 关闭端口跳跃范围 udp ${_fw_huc_a}:${_fw_huc_b}" \
    ufw delete allow "${_fw_huc_a}:${_fw_huc_b}/udp" \
    || log_warn "ufw 删除端口跳跃范围规则失败（可能已不存在）"
  if cmd_exists iptables; then
    _fw_hop_ipt_clear "$_fw_huc_a" "$_fw_huc_b" "$_fw_huc_to"
  fi
  return 0
}

_fw_hop_firewalld_apply() {
  local _fw_hfa_a="$1"
  local _fw_hfa_b="$2"
  local _fw_hfa_to="$3"
  local _fw_hfa_zone=""
  _fw_hfa_zone="$(_fw_firewalld_zone)"
  run_gate "firewalld 放行端口跳跃范围 udp ${_fw_hfa_a}-${_fw_hfa_b}（zone=${_fw_hfa_zone}）" \
    firewall-cmd --permanent --zone="$_fw_hfa_zone" --add-port="${_fw_hfa_a}-${_fw_hfa_b}/udp" || return 1
  run_gate "firewalld 端口跳跃重定向 udp ${_fw_hfa_a}-${_fw_hfa_b} → ${_fw_hfa_to}（zone=${_fw_hfa_zone}）" \
    firewall-cmd --permanent --zone="$_fw_hfa_zone" \
      --add-forward-port="port=${_fw_hfa_a}-${_fw_hfa_b}:proto=udp:toport=${_fw_hfa_to}" || return 1
  run_gate "firewalld 重载规则" firewall-cmd --reload || return 1
  return 0
}

_fw_hop_firewalld_clear() {
  local _fw_hfc_a="$1"
  local _fw_hfc_b="$2"
  local _fw_hfc_to="$3"
  local _fw_hfc_zone=""
  _fw_hfc_zone="$(_fw_firewalld_zone)"
  run_gate "firewalld 删除端口跳跃重定向 udp ${_fw_hfc_a}-${_fw_hfc_b}（zone=${_fw_hfc_zone}）" \
    firewall-cmd --permanent --zone="$_fw_hfc_zone" \
      --remove-forward-port="port=${_fw_hfc_a}-${_fw_hfc_b}:proto=udp:toport=${_fw_hfc_to}" \
    || log_warn "firewalld 删除端口跳跃重定向失败（可能已不存在）"
  run_gate "firewalld 关闭端口跳跃范围 udp ${_fw_hfc_a}-${_fw_hfc_b}（zone=${_fw_hfc_zone}）" \
    firewall-cmd --permanent --zone="$_fw_hfc_zone" --remove-port="${_fw_hfc_a}-${_fw_hfc_b}/udp" \
    || log_warn "firewalld 删除端口跳跃范围失败（可能已不存在）"
  run_gate "firewalld 重载规则" firewall-cmd --reload || log_warn "firewalld 重载失败"
  return 0
}

_fw_hop_backend_apply() {
  local _fw_hba_backend="$1"
  local _fw_hba_a="$2"
  local _fw_hba_b="$3"
  local _fw_hba_to="$4"
  case "$_fw_hba_backend" in
    nftables)  _fw_hop_nft_apply       "$_fw_hba_a" "$_fw_hba_b" "$_fw_hba_to" ;;
    iptables)  _fw_hop_ipt_apply       "$_fw_hba_a" "$_fw_hba_b" "$_fw_hba_to" ;;
    ufw)       _fw_hop_ufw_apply       "$_fw_hba_a" "$_fw_hba_b" "$_fw_hba_to" ;;
    firewalld) _fw_hop_firewalld_apply "$_fw_hba_a" "$_fw_hba_b" "$_fw_hba_to" ;;
    *) error "不支持端口跳跃的防火墙后端：$_fw_hba_backend"; return 1 ;;
  esac
}

_fw_hop_backend_clear() {
  local _fw_hbc_backend="$1"
  local _fw_hbc_a="$2"
  local _fw_hbc_b="$3"
  local _fw_hbc_to="$4"
  case "$_fw_hbc_backend" in
    nftables)  _fw_hop_nft_clear       "$_fw_hbc_a" "$_fw_hbc_b" "$_fw_hbc_to" ;;
    iptables)  _fw_hop_ipt_clear       "$_fw_hbc_a" "$_fw_hbc_b" "$_fw_hbc_to" ;;
    ufw)       _fw_hop_ufw_clear       "$_fw_hbc_a" "$_fw_hbc_b" "$_fw_hbc_to" ;;
    firewalld) _fw_hop_firewalld_clear "$_fw_hbc_a" "$_fw_hbc_b" "$_fw_hbc_to" ;;
    *) return 0 ;;
  esac
}

# .firewall.hop 里存的 range 一律是 `20000-30000`（与 STATE.md 一致），按后端换成对应写法
_fw_hop_split_range() {
  local _fw_hsr_range="$1"
  _fw_hsr_range="$(printf '%s' "$_fw_hsr_range" | tr ':' '-')"
  case "$_fw_hsr_range" in
    *-*) printf '%s %s\n' "${_fw_hsr_range%%-*}" "${_fw_hsr_range##*-}" ;;
    *) return 1 ;;
  esac
  return 0
}

# 启用端口跳跃：range 如 20000-30000，to_port 是 hysteria2 的真实监听端口
fw_hop_apply() {
  local _fw_ha_range="${1-}"
  local _fw_ha_to="${2-}"
  local _fw_ha_norm=""
  local _fw_ha_a=""
  local _fw_ha_b=""
  local _fw_ha_backend=""
  local _fw_ha_enabled=""
  _fw_ha_norm="$(validate_port_range "$_fw_ha_range")" || return 1
  validate_port "$_fw_ha_to" || return 1
  _fw_ha_a="${_fw_ha_norm%%-*}"
  _fw_ha_b="${_fw_ha_norm##*-}"
  _fw_ha_backend="$(_fw_backend_for_change)" || return 1
  if [ "$_fw_ha_backend" = "none" ]; then
    error "未检测到可用的防火墙，无法设置端口跳跃"
    return 1
  fi
  _fw_ha_enabled="$(state_get .firewall.hop.enabled)"
  # 幂等：已启用且参数一致则跳过
  if [ "$_fw_ha_enabled" = "true" ] \
     && [ "$(state_get .firewall.hop.range)" = "$_fw_ha_norm" ] \
     && [ "$(state_get .firewall.hop.to_port)" = "$_fw_ha_to" ]; then
    log_debug "端口跳跃规则已存在，跳过：$_fw_ha_norm → $_fw_ha_to"
    return 0
  fi
  # 参数变了：先回收旧规则，避免残留两条重定向
  if [ "$_fw_ha_enabled" = "true" ]; then
    fw_hop_clear >/dev/null 2>&1 || log_warn "回收旧端口跳跃规则失败，继续按新参数下发"
  fi
  if ! _fw_hop_backend_apply "$_fw_ha_backend" "$_fw_ha_a" "$_fw_ha_b" "$_fw_ha_to"; then
    error "下发端口跳跃规则失败（$_fw_ha_norm → $_fw_ha_to）"
    return 1
  fi
  if ! state_set .firewall.hop "{\"enabled\":true,\"range\":\"$_fw_ha_norm\",\"to_port\":$_fw_ha_to}"; then
    error "无法在 state 中登记端口跳跃，正在回滚该规则"
    _fw_hop_backend_clear "$_fw_ha_backend" "$_fw_ha_a" "$_fw_ha_b" "$_fw_ha_to" >/dev/null 2>&1 || true
    return 1
  fi
  log_ok "端口跳跃已启用：UDP ${_fw_ha_norm} → ${_fw_ha_to}（后端 $_fw_ha_backend）"
  return 0
}

# 回收端口跳跃：只删本工具自己的链/表/跳转；从未启用过时什么都不做
fw_hop_clear() {
  local _fw_hc_range=""
  local _fw_hc_to=""
  local _fw_hc_backend=""
  local _fw_hc_pair=""
  local _fw_hc_a=""
  local _fw_hc_b=""
  _fw_hc_range="$(state_get .firewall.hop.range)"
  _fw_hc_to="$(state_get .firewall.hop.to_port)"
  # range 是“本工具是否下发过端口跳跃”的唯一凭据（回收后清空）
  if [ -z "$_fw_hc_range" ]; then
    log_debug "没有需要回收的端口跳跃规则"
    return 0
  fi
  _fw_hc_backend="$(state_get .firewall.backend)"
  [ -n "$_fw_hc_backend" ] || _fw_hc_backend="$(_fw_detect_backend)"
  _fw_hc_pair="$(_fw_hop_split_range "$_fw_hc_range" || true)"
  _fw_hc_a="${_fw_hc_pair%% *}"
  _fw_hc_b="${_fw_hc_pair##* }"
  case "$_fw_hc_to" in
    ''|*[!0-9]*) _fw_hc_to=0 ;;
  esac
  if [ "$_fw_hc_backend" != "none" ] && [ -n "$_fw_hc_a" ] && [ -n "$_fw_hc_b" ]; then
    _fw_hop_backend_clear "$_fw_hc_backend" "$_fw_hc_a" "$_fw_hc_b" "$_fw_hc_to" || {
      log_warn "端口跳跃规则回收失败（记录保留，可稍后重试）"
      return 1
    }
  fi
  state_set .firewall.hop '{"enabled":false,"range":"","to_port":0}' \
    || { log_warn "端口跳跃状态重置失败"; return 1; }
  log_ok "端口跳跃已关闭"
  return 0
}

# ---------------------------------------------------------------------------
# 公共 API：全量回收（卸载时调用）
# ---------------------------------------------------------------------------
fw_revert_all() {
  local _fw_ra_backend=""
  local _fw_ra_rules=""
  local _fw_ra_hop_enabled=""
  local _fw_ra_used=0
  local _fw_ra_key=""
  local _fw_ra_port=""
  local _fw_ra_proto=""
  _fw_ra_rules="$(_fw_rules_list)"
  _fw_ra_hop_enabled="$(state_get .firewall.hop.enabled)"
  [ -n "$_fw_ra_rules" ] && _fw_ra_used=1
  [ "$_fw_ra_hop_enabled" = "true" ] && _fw_ra_used=1

  # 从来没有加过规则：什么都不做（绝不凭空删除任何东西）
  if [ "$_fw_ra_used" = "0" ]; then
    log_debug "本工具没有添加过防火墙规则，无需回收"
    return 0
  fi

  _fw_ra_backend="$(state_get .firewall.backend)"
  [ -n "$_fw_ra_backend" ] || _fw_ra_backend="$(_fw_detect_backend)"

  # 1) 关闭登记过的每一条规则
  # shellcheck disable=SC2086
  for _fw_ra_key in $_fw_ra_rules; do
    _fw_ra_port="${_fw_ra_key%%/*}"
    _fw_ra_proto="${_fw_ra_key##*/}"
    if [ "$_fw_ra_backend" = "none" ]; then
      log_warn "未检测到防火墙后端，无法回收 $_fw_ra_key"
      continue
    fi
    _fw_close_one "$_fw_ra_backend" "$_fw_ra_port" "$_fw_ra_proto" || log_warn "回收 $_fw_ra_key 失败"
  done

  # 2) 端口跳跃（含 PREROUTING 跳转与自有链）
  fw_hop_clear >/dev/null 2>&1 || log_warn "端口跳跃回收失败"

  # 3) 回收本工具的容器（nft 专用表 / iptables 自有链）
  case "$_fw_ra_backend" in
    nftables) _fw_nft_reclaim ;;
    iptables) _fw_ipt_reclaim ;;
    *) : ;;
  esac

  # 4) 清空登记并把后端标记为“无”
  printf '' | _fw_rules_set || { error "清空规则记录失败"; return 1; }
  state_set_str ".firewall.backend" "none" >/dev/null 2>&1 || true
  log_ok "本工具的防火墙规则已全部回收"
  return 0
}

# ---------------------------------------------------------------------------
# 公共 API：状态摘要（只读，绝不修改任何东西）
# ---------------------------------------------------------------------------
fw_status() {
  local _fw_st_live=""
  local _fw_st_rec=""
  local _fw_st_rules=""
  local _fw_st_count=0
  local _fw_st_r=""
  local _fw_st_hop_enabled=""
  local _fw_st_hop_range=""
  local _fw_st_hop_to=""
  local _fw_st_hop_spell=""
  # 注意：这里必须用 _fw_detect_backend（只探测），fw_backend 会写 state
  _fw_st_live="$(_fw_detect_backend)"
  _fw_st_rec="$(state_get .firewall.backend)"
  ui_kv "防火墙后端" "$_fw_st_live"
  if [ -n "$_fw_st_rec" ] && [ "$_fw_st_rec" != "$_fw_st_live" ]; then
    ui_kv "记录的后端" "$_fw_st_rec"
  fi
  if [ "$_fw_st_live" = "none" ]; then
    ui_kv "说明" "未检测到 ufw / firewalld / nftables / iptables"
  fi
  _fw_st_rules="$(_fw_rules_list)"
  if [ -z "$_fw_st_rules" ]; then
    ui_kv "本工具规则" "无"
  else
    _fw_st_count="$(printf '%s\n' "$_fw_st_rules" | grep -c '[^[:space:]]' || true)"
    ui_kv "本工具规则" "${_fw_st_count} 条"
    for _fw_st_r in $_fw_st_rules; do
      printf '      %s%s%s\n' "$C_GREEN" "$_fw_st_r" "$C_RESET"
    done
  fi
  _fw_st_hop_enabled="$(state_get .firewall.hop.enabled)"
  _fw_st_hop_range="$(state_get .firewall.hop.range)"
  _fw_st_hop_to="$(state_get .firewall.hop.to_port)"
  if [ "$_fw_st_hop_enabled" = "true" ] && [ -n "$_fw_st_hop_range" ]; then
    _fw_st_hop_spell="$_fw_st_hop_range"
    if [ "$_fw_st_live" = "iptables" ]; then
      _fw_st_hop_spell="$(printf '%s' "$_fw_st_hop_range" | tr '-' ':')"
    fi
    ui_kv "端口跳跃" "已启用 UDP ${_fw_st_hop_spell} → ${_fw_st_hop_to}"
  else
    ui_kv "端口跳跃" "未启用"
  fi
  return 0
}


# ===== 内联模块：lib/70-web.sh =====
#!/usr/bin/env bash
# =============================================================================
# EasySB — 70-web.sh
# 伪装站点（camouflage website）：
#   nginx 安装 / 模板站点部署 / ACME webroot / 443 证书配置 / 重载 / 端口检查
# 依赖：00-core.sh（run_gate / log_* / file_write）、10-detect.sh（service_mgr /
#       port_in_use / os_pkg_install / pkg_name_for）、20-state.sh（state_get / state_set*）
#
# 设计约束（违反即缺陷）：
#   1. 只写、只删**本工具自己**的配置文件（默认 easysb.conf），绝不读取或修改其它站点配置；
#   2. 所有绝对路径都带 ESB_ROOT 前缀（ESB_WEB_ROOT / ESB_NGINX_CONF 可被 init 覆盖）；
#   3. 所有系统变更命令走 run_gate；任何 nginx 配置生效前必须先 nginx -t；
#   4. UI 可调用的函数一律 `error "…"; return 1`，绝不 exit；
#   5. nginx 配置由 heredoc + file_write 生成，禁止 sed 原地改；
#   6. 443 端口若被已启用的 TCP 协议占用，必须拒绝写入 443 配置（保持 80 单端口站点）。
# =============================================================================
# shellcheck shell=bash

# nginx 配置里的管理标记（测试与契约审计依赖它，请勿修改）
ESB_WEB_MARKER="EasySB-MANAGED 伪装站点"

# ---------------------------------------------------------------------------
# 路径与模板工具
# ---------------------------------------------------------------------------
# 沙箱一致性：显式传入的路径必须落在 ESB_ROOT 之内（为空则任意路径都合法）
_web_under_root() {
  local _web_ur_path="${1-}"
  if [ -z "${ESB_ROOT:-}" ]; then return 0; fi
  case "$_web_ur_path" in
    "${ESB_ROOT}"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# stdout：伪装站点根目录
_web_root() {
  local _web_root_var="${ESB_WEB_ROOT:-}"
  if [ -n "$_web_root_var" ] && _web_under_root "$_web_root_var"; then
    printf '%s\n' "$_web_root_var"
  else
    printf '%s\n' "${ESB_ROOT:-}/var/www/easysb"
  fi
  return 0
}

# stdout：nginx 站点配置目录（Debian/RHEL=conf.d，Alpine=http.d，兜底 conf.d）
_web_conf_dir() {
  local _web_cd_dir
  for _web_cd_dir in \
      "${ESB_ROOT:-}/etc/nginx/conf.d" \
      "${ESB_ROOT:-}/etc/nginx/http.d" \
      "${ESB_ROOT:-}/etc/nginx/sites-enabled"; do
    if [ -d "$_web_cd_dir" ]; then
      printf '%s\n' "$_web_cd_dir"
      return 0
    fi
  done
  printf '%s\n' "${ESB_ROOT:-}/etc/nginx/conf.d"
  return 0
}

# stdout：本工具独占的 nginx 配置文件路径
_web_conf_file() {
  local _web_cf_var="${ESB_NGINX_CONF:-}"
  if [ -n "$_web_cf_var" ] && _web_under_root "$_web_cf_var" && [ -d "$(dirname "$_web_cf_var")" ]; then
    printf '%s\n' "$_web_cf_var"
  else
    printf '%s/easysb.conf\n' "$(_web_conf_dir)"
  fi
  return 0
}

# 规范化反向代理目标（去首尾空白、去尾部斜杠），stdout 输出
_web_normalize_url() {
  local _web_nu_val="$(trim "${1-}")"
  case "$_web_nu_val" in
    */)
      if [ "${#_web_nu_val}" -gt 8 ]; then _web_nu_val="${_web_nu_val%/}"; fi
      ;;
  esac
  printf '%s\n' "$_web_nu_val"
  return 0
}

# 只允许写/删本工具自己的配置，防止 ESB_NGINX_CONF 被误配到别人的站点文件上
_web_conf_owned() {
  case "$(basename "${1-}")" in
    *easysb*) return 0 ;;
    *) return 1 ;;
  esac
}

_web_conf_bak() { printf '%s.easysb.bak\n' "$1"; }

_web_template_known() {
  case "${1-}" in
    blog|corp|blank|custom|proxy) return 0 ;;
    *) return 1 ;;
  esac
}

_web_template_label() {
  case "${1-}" in
    blog)   printf '个人博客\n' ;;
    corp)   printf '企业官网\n' ;;
    blank)  printf '200 空白页\n' ;;
    custom) printf '自定义 HTML\n' ;;
    proxy)  printf '反向代理到真实站点\n' ;;
    *)      printf '%s\n' "${1-}" ;;
  esac
  return 0
}

# 模板列表（stdout TSV：key<TAB>名称）
web_templates() {
  local _web_tpl_k
  for _web_tpl_k in blog corp blank custom proxy; do
    printf '%s\t%s\n' "$_web_tpl_k" "$(_web_template_label "$_web_tpl_k")"
  done
  return 0
}

# ---------------------------------------------------------------------------
# nginx 存在性 / 版本 / 服务动作
# ---------------------------------------------------------------------------
web_installed() {
  if cmd_exists nginx; then return 0; fi
  local _web_inst_p
  for _web_inst_p in \
      "${ESB_ROOT:-}/usr/sbin/nginx" \
      "${ESB_ROOT:-}/sbin/nginx" \
      "${ESB_ROOT:-}/usr/bin/nginx"; do
    if [ -x "$_web_inst_p" ]; then return 0; fi
  done
  return 1
}

# stdout：nginx 版本号（形如 1.24.0），取不到输出空
_web_nginx_version() {
  local _web_nv_out=""
  if ! web_installed; then return 0; fi
  _web_nv_out="$(nginx -v 2>&1 | tr -d '\r' | sed -n 's|.*nginx/\([0-9][0-9.]*\).*|\1|p' | head -1)"
  printf '%s\n' "$_web_nv_out"
  return 0
}

# nginx 服务动作：优先 service_mgr；没有 init 系统（容器/沙箱）时直接操作 nginx 进程
_web_service() {
  local _web_svc_action="${1:-status}"
  if [ "${ESB_INIT:-none}" != "none" ] || [ -x "${ESB_ROOT:-}/etc/init.d/nginx" ]; then
    service_mgr nginx "$_web_svc_action"
    return $?
  fi
  case "$_web_svc_action" in
    status)
      log_debug "没有服务管理器，无法判断 nginx 运行状态"
      return 1
      ;;
    start)   run_gate "nginx start" nginx ;;
    reload)  run_gate "nginx reload" nginx -s reload ;;
    restart) run_gate "nginx restart" nginx -s reload ;;
    stop)    run_gate "nginx stop" nginx -s quit ;;
    enable|disable) return 0 ;;
    *)
      error "未知的 nginx 服务动作：$_web_svc_action"
      return 1
      ;;
  esac
}

# nginx -t：0=配置合法。沙箱（ESB_GATE=1）里只记录不执行。
_web_conf_test() {
  local _web_ct_out="" _web_ct_line=""
  if [ "${ESB_GATE:-0}" = "1" ]; then
    run_gate "nginx -t" nginx -t
    return 0
  fi
  if _web_ct_out="$(nginx -t 2>&1)"; then
    log_debug "nginx -t 通过"
    return 0
  fi
  log_warn "nginx -t 未通过，已拒绝重载（运行中的 nginx 不受影响）"
  printf '%s\n' "$_web_ct_out" | tr -d '\r' | while IFS= read -r _web_ct_line; do
    log_warn "    $_web_ct_line"
  done
  return 1
}

web_reload() {
  if ! web_installed; then
    error "nginx 未安装，无法重载配置"
    return 1
  fi
  if ! _web_conf_test; then
    return 1
  fi
  if ! _web_service reload; then
    log_warn "nginx 重载失败，尝试重启以加载新配置"
    if ! _web_service restart; then
      error "nginx 重启失败，请手动检查 nginx -t 与服务日志"
      return 1
    fi
  fi
  log_ok "nginx 配置已生效"
  return 0
}

web_install() {
  if web_installed; then
    log_ok "nginx 已安装（$(_web_nginx_version)）"
    return 0
  fi
  log_info "安装 nginx（包管理器：${ESB_PKG:-unknown}）"
  if ! os_pkg_install "$(pkg_name_for nginx)"; then
    error "nginx 安装失败，请手动安装后重试（apt install nginx / dnf install nginx / apk add nginx）"
    return 1
  fi
  mkdir -p "$(_web_conf_dir)" 2>/dev/null || true
  if ! _web_service enable; then log_warn "nginx 开机自启设置失败（不影响本次使用）"; fi
  if ! _web_service start; then log_warn "nginx 启动失败，请检查 nginx -t 与服务日志"; fi
  if ! web_installed; then
    error "安装后仍未找到 nginx 可执行文件，请手动检查安装结果"
    return 1
  fi
  log_ok "nginx 安装完成（$(_web_nginx_version)）"
  return 0
}

# ---------------------------------------------------------------------------
# 站点内容（内联 CSS，无任何外部 CDN 依赖）
# ---------------------------------------------------------------------------
_web_page_blog() {
  cat <<'HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>云间笔记 · 个人博客</title>
<style>
  :root{--fg:#1b1f24;--muted:#5c6672;--line:#e6e8eb;--accent:#2f6feb;--bg:#fbfbfd;--card:#fff}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);line-height:1.75;
       font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans SC","PingFang SC","Microsoft YaHei",sans-serif}
  a{color:var(--accent);text-decoration:none}
  a:hover{text-decoration:underline}
  header{background:var(--card);border-bottom:1px solid var(--line)}
  .wrap{max-width:820px;margin:0 auto;padding:0 20px}
  .bar{display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;padding:18px 0}
  .brand{font-size:20px;font-weight:600;letter-spacing:.5px}
  nav a{margin-left:18px;color:var(--muted);font-size:15px}
  main{padding:36px 0 56px}
  h1{font-size:30px;margin:0 0 8px}
  .lead{color:var(--muted);margin:0 0 30px}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:16px}
  .card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px 20px}
  .card h3{margin:0 0 8px;font-size:17px}
  .card p{margin:0;color:var(--muted);font-size:14.5px}
  .meta{color:var(--muted);font-size:13px;margin-top:10px}
  footer{border-top:1px solid var(--line);color:var(--muted);font-size:13px;padding:22px 0;text-align:center}
  @media (max-width:600px){h1{font-size:24px}nav a{margin-left:12px}}
</style>
</head>
<body>
<header>
  <div class="wrap bar">
    <div class="brand">云间笔记</div>
    <nav><a href="/">首页</a><a href="/archive">归档</a><a href="/about">关于</a></nav>
  </div>
</header>
<main class="wrap">
  <h1>用文字记录，与技术慢慢相处</h1>
  <p class="lead">这里是我的个人博客：写网络与自建服务，也写读书和日常。</p>
  <section class="cards">
    <article class="card">
      <h3>自建网络服务入门</h3>
      <p>从一台最小配置的服务器开始，把需要的东西一件件搭起来。</p>
      <div class="meta">2026-08-30 · 网络</div>
    </article>
    <article class="card">
      <h3>给站点配一张证书</h3>
      <p>让网站支持 HTTPS，其实比想象中简单，也不影响正在运行的服务。</p>
      <div class="meta">2026-09-05 · 运维</div>
    </article>
    <article class="card">
      <h3>最近在读的书</h3>
      <p>技术之外的一点阅读记录，慢慢补充中。</p>
      <div class="meta">2026-09-12 · 随笔</div>
    </article>
  </section>
</main>
<footer><div class="wrap">© 2026 云间笔记 · 保留所有权利</div></footer>
</body>
</html>
HTML
}

_web_page_corp() {
  cat <<'HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>远山科技 · 企业官网</title>
<style>
  :root{--fg:#141a21;--muted:#5b6673;--line:#e3e7ec;--accent:#0f62fe;--bg:#fff}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);line-height:1.7;
       font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans SC","PingFang SC","Microsoft YaHei",sans-serif}
  a{color:inherit;text-decoration:none}
  .wrap{max-width:1040px;margin:0 auto;padding:0 22px}
  header{border-bottom:1px solid var(--line);position:sticky;top:0;background:rgba(255,255,255,.94)}
  .bar{display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;padding:16px 0}
  .logo{font-size:19px;font-weight:700;letter-spacing:1px}
  nav a{margin-left:20px;color:var(--muted);font-size:15px}
  .hero{padding:64px 0 52px;border-bottom:1px solid var(--line)}
  .hero h1{margin:0 0 14px;font-size:36px;line-height:1.3}
  .hero p{margin:0 0 26px;color:var(--muted);font-size:16.5px;max-width:640px}
  .btn{display:inline-block;background:var(--accent);color:#fff;padding:11px 22px;border-radius:8px;font-size:15px}
  .btn.ghost{background:transparent;color:var(--accent);border:1px solid var(--accent);margin-left:10px}
  section{padding:52px 0}
  h2{font-size:23px;margin:0 0 22px}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:20px}
  .box{border:1px solid var(--line);border-radius:12px;padding:22px}
  .box h3{margin:0 0 10px;font-size:17px}
  .box p{margin:0;color:var(--muted);font-size:14.5px}
  footer{border-top:1px solid var(--line);padding:26px 0;color:var(--muted);font-size:13.5px}
  @media (max-width:600px){.hero h1{font-size:27px}nav a{margin-left:14px}.btn.ghost{margin:10px 0 0 0}}
</style>
</head>
<body>
<header>
  <div class="wrap bar">
    <div class="logo">远山科技</div>
    <nav><a href="#product">产品</a><a href="#solution">解决方案</a><a href="#contact">联系我们</a></nav>
  </div>
</header>
<div class="wrap">
  <section class="hero">
    <h1>让每一台服务器都稳定、可靠、可维护</h1>
    <p>远山科技为中小企业提供基础架构与网络服务，从选型、部署到日常运维，把复杂的事情做简单。</p>
    <a class="btn" href="#contact">联系我们</a><a class="btn ghost" href="#product">了解产品</a>
  </section>
  <section id="product">
    <h2>主要服务</h2>
    <div class="grid">
      <div class="box"><h3>基础架构部署</h3><p>服务器初始化、系统加固、服务编排，交付即用。</p></div>
      <div class="box"><h3>网络与加速</h3><p>链路优化、证书管理与域名规划，访问更快更稳。</p></div>
      <div class="box"><h3>运维托管</h3><p>监控告警、备份恢复与应急响应，7×24 小时值守。</p></div>
    </div>
  </section>
  <section id="contact">
    <h2>联系我们</h2>
    <div class="grid">
      <div class="box"><h3>商务咨询</h3><p>邮箱：contact@example.com<br>工作时间：周一至周五 9:00 - 18:00</p></div>
      <div class="box"><h3>技术支持</h3><p>邮箱：support@example.com<br>电话：400-000-0000</p></div>
    </div>
  </section>
</div>
<footer><div class="wrap">© 2026 远山科技 · 京ICP备00000000号</div></footer>
</body>
</html>
HTML
}

_web_page_blank() {
  cat <<'HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Welcome</title>
</head>
<body></body>
</html>
HTML
}

_web_page_custom_placeholder() {
  cat <<'HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>自定义站点</title>
<style>
  body{margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center;background:#f7f8fa;
       color:#1b1f24;font-family:-apple-system,"Noto Sans SC","Microsoft YaHei",sans-serif}
  .box{max-width:560px;padding:28px 30px;background:#fff;border:1px solid #e6e8eb;border-radius:12px;line-height:1.8}
  code{background:#f1f3f5;padding:2px 6px;border-radius:4px}
</style>
</head>
<body>
  <div class="box">
    <h1>自定义站点已就绪</h1>
    <p>请把你自己的 <code>index.html</code> 及静态资源放入本目录，刷新页面即可看到效果。</p>
    <p>本页面由 EasySB 生成，仅作为占位；覆盖后不会再被自动改写。</p>
  </div>
</body>
</html>
HTML
}

# 写站点首页；proxy 模板不写任何页面文件
_web_page_write() {
  local _web_pw_tpl="${1-}" _web_pw_root _web_pw_file
  _web_pw_root="$(_web_root)"
  _web_pw_file="${_web_pw_root}/index.html"
  case "$_web_pw_tpl" in
    blog)   _web_page_blog   | file_write "$_web_pw_file" 644 ;;
    corp)   _web_page_corp   | file_write "$_web_pw_file" 644 ;;
    blank)  _web_page_blank  | file_write "$_web_pw_file" 644 ;;
    custom)
      if [ -f "$_web_pw_file" ]; then
        log_info "custom 模板：保留已有首页 ${_web_pw_file}"
        return 0
      fi
      _web_page_custom_placeholder | file_write "$_web_pw_file" 644
      ;;
    *) return 0 ;;
  esac
  if [ ! -f "$_web_pw_file" ]; then
    error "写入站点首页失败：$_web_pw_file"
    return 1
  fi
  log_info "站点首页已写入：$_web_pw_file"
  return 0
}

# ---------------------------------------------------------------------------
# 证书 / 端口相关判定
# ---------------------------------------------------------------------------
_web_tls_port() {
  local _web_tp="${1-}"
  if [ -z "$_web_tp" ]; then _web_tp="$(state_get .web.tls_port)"; fi
  case "$_web_tp" in
    ''|*[!0-9]*) _web_tp=443 ;;
  esac
  if [ "$_web_tp" -lt 1 ] || [ "$_web_tp" -gt 65535 ]; then _web_tp=443; fi
  printf '%s\n' "$_web_tp"
  return 0
}

# stdout：证书文件真实路径（state 里可能存了带/不带 ESB_ROOT 前缀的路径）
_web_resolve_path() {
  local _web_rp_path="${1-}" _web_rp_alt=""
  if [ -z "$_web_rp_path" ]; then return 1; fi
  if [ -f "$_web_rp_path" ]; then
    printf '%s\n' "$_web_rp_path"
    return 0
  fi
  if [ -n "${ESB_ROOT:-}" ]; then
    case "$_web_rp_path" in
      "${ESB_ROOT}"/*) _web_rp_alt="$_web_rp_path" ;;
      *) _web_rp_alt="${ESB_ROOT}${_web_rp_path}" ;;
    esac
    if [ -f "$_web_rp_alt" ]; then
      printf '%s\n' "$_web_rp_alt"
      return 0
    fi
  fi
  return 1
}

# stdout：两行，第一行证书、第二行私钥；缺任意一个则 return 1
_web_tls_cert_paths() {
  local _web_tcp_crt="" _web_tcp_key=""
  _web_tcp_crt="$(_web_resolve_path "$(state_get .cert.crt)")" || return 1
  _web_tcp_key="$(_web_resolve_path "$(state_get .cert.key)")" || return 1
  if [ -z "$_web_tcp_crt" ] || [ -z "$_web_tcp_key" ]; then return 1; fi
  printf '%s\n%s\n' "$_web_tcp_crt" "$_web_tcp_key"
  return 0
}

# stdout：占用该端口的已启用 TCP 协议 key（无冲突则无输出）
_web_tcp_conflict() {
  local _web_tc_port="${1-}" _web_tc_k _web_tc_p
  if [ -z "$_web_tc_port" ]; then return 1; fi
  for _web_tc_k in vless-vision-reality vmess-ws-tls anytls; do
    if ! proto_enabled "$_web_tc_k"; then continue; fi
    _web_tc_p="$(proto_port "$_web_tc_k")"
    if [ -n "$_web_tc_p" ] && [ "$_web_tc_p" = "$_web_tc_port" ]; then
      printf '%s\n' "$_web_tc_k"
      return 0
    fi
  done
  return 1
}

# 0 = 现在可以写 443（.web.tls=true + 证书齐 + 端口未被启用协议占用）
_web_tls_ready() {
  local _web_tr_owner=""
  if [ "$(state_get .web.tls)" != "true" ]; then return 1; fi
  if ! _web_tls_cert_paths >/dev/null 2>&1; then return 1; fi
  _web_tr_owner="$(_web_tcp_conflict "$(_web_tls_port)")"
  if [ -n "$_web_tr_owner" ]; then return 1; fi
  return 0
}

# 443 的 listen 行：nginx >= 1.25.1 用独立指令 http2 on;，更老的版本用 listen 参数形式
_web_tls_listen_lines() {
  local _web_tll_port="${1:-443}" _web_tll_ver _web_tll_maj _web_tll_rest _web_tll_min _web_tll_pat
  local _web_tll_kw=" http2" _web_tll_on=""
  _web_tll_ver="$(_web_nginx_version)"
  case "$_web_tll_ver" in
    ''|*[!0-9.]*)
      _web_tll_ver=""
      ;;
  esac
  if [ -n "$_web_tll_ver" ]; then
    _web_tll_maj="${_web_tll_ver%%.*}"
    _web_tll_rest="${_web_tll_ver#*.}"
    _web_tll_min="${_web_tll_rest%%.*}"
    _web_tll_pat="${_web_tll_rest#*.}"
    if [ "$_web_tll_pat" = "$_web_tll_rest" ]; then _web_tll_pat=0; fi
    case "$_web_tll_maj" in ''|*[!0-9]*) _web_tll_maj=0 ;; esac
    case "$_web_tll_min" in ''|*[!0-9]*) _web_tll_min=0 ;; esac
    case "$_web_tll_pat" in ''|*[!0-9]*) _web_tll_pat=0 ;; esac
    if [ "$_web_tll_maj" -gt 1 ]; then
      _web_tll_kw=""; _web_tll_on="    http2 on;"
    elif [ "$_web_tll_maj" -eq 1 ] && [ "$_web_tll_min" -gt 25 ]; then
      _web_tll_kw=""; _web_tll_on="    http2 on;"
    elif [ "$_web_tll_maj" -eq 1 ] && [ "$_web_tll_min" -eq 25 ] && [ "$_web_tll_pat" -ge 1 ]; then
      _web_tll_kw=""; _web_tll_on="    http2 on;"
    fi
  fi
  printf '    listen %s ssl%s;\n' "$_web_tll_port" "$_web_tll_kw"
  printf '    listen [::]:%s ssl%s;\n' "$_web_tll_port" "$_web_tll_kw"
  if [ -n "$_web_tll_on" ]; then printf '%s\n' "$_web_tll_on"; fi
  return 0
}

# ---------------------------------------------------------------------------
# nginx 配置生成（heredoc → file_write，绝不 sed -i）
# ---------------------------------------------------------------------------
# $1 = 模板 key，$2 = 1 写入 443 站点 / 0 仅 80
_web_conf_render() {
  local _web_cr_tpl="${1:-blog}" _web_cr_tls="${2:-0}"
  local _web_cr_root _web_cr_http_port _web_cr_domain _web_cr_name _web_cr_target=""
  local _web_cr_tls_port="" _web_cr_crt="" _web_cr_key="" _web_cr_listen="" _web_cr_proxy="0"

  _web_cr_root="$(_web_root)"
  _web_cr_http_port="$(state_get .web.http_port)"
  case "$_web_cr_http_port" in
    ''|*[!0-9]*) _web_cr_http_port=80 ;;
  esac
  _web_cr_domain="$(state_get .domain)"
  _web_cr_name="$_web_cr_domain"
  if [ -z "$_web_cr_name" ]; then _web_cr_name="_"; fi
  _web_cr_target="$(_web_normalize_url "$(state_get .web.proxy_target)")"
  _web_cr_proxy="0"
  if [ "$_web_cr_tpl" = "proxy" ]; then
    if [ -n "$_web_cr_target" ]; then
      _web_cr_proxy="1"
    else
      # 目标缺失时绝不生成 `proxy_pass ;`（那是非法配置），退化为静态块
      log_debug "反向代理目标为空，本次退化为静态站点块"
    fi
  fi

  if [ "$_web_cr_tls" = "1" ]; then
    _web_cr_tls_port="$(_web_tls_port)"
    _web_cr_crt="$(_web_tls_cert_paths | sed -n 1p)"
    _web_cr_key="$(_web_tls_cert_paths | sed -n 2p)"
    _web_cr_listen="$(_web_tls_listen_lines "$_web_cr_tls_port")"
  fi

  # ---- 文件头（管理标记） ----
  cat <<EOF
# =============================================================================
# ${ESB_WEB_MARKER}
#   站点模板 : ${_web_cr_tpl}（$(_web_template_label "$_web_cr_tpl")）
#   生成时间 : $(esb_now)
#   说明     : 本文件由 EasySB 生成并独占管理，只包含本工具自己的 server 块；
#              EasySB 不会读取或修改其它站点的 nginx 配置。
#              手工修改会在下次部署/应用证书时被覆盖。
# =============================================================================
EOF

  # ---- 反代模板需要的 WebSocket 升级映射（http 上下文，名称带 easysb 前缀避免撞名） ----
  if [ "$_web_cr_proxy" = "1" ]; then
    cat <<'EOF'

# 反向代理：WebSocket / HTTP 升级支持（仅本文件使用）
map $http_upgrade $easysb_connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
  fi

  # ---- 80 端口 server 块 ----
  cat <<EOF

server {
    listen ${_web_cr_http_port};
    listen [::]:${_web_cr_http_port};
    server_name ${_web_cr_name};

    root ${_web_cr_root};
    index index.html;

    # 隐藏 nginx 版本，避免指纹
    server_tokens off;
    access_log off;

    # ACME http-01 挑战目录：证书签发与续期不需要停站点、不影响正在运行的服务
    location /.well-known/acme-challenge/ {
        root ${_web_cr_root};
        default_type "text/plain";
        try_files \$uri =404;
    }

EOF

  if [ "$_web_cr_tls" = "1" ] && [ -n "$_web_cr_domain" ]; then
    cat <<'EOF'
    # 已启用 HTTPS：明文请求跳转（上面的 acme-challenge 位置优先匹配，不受影响）
    location / {
        return 301 https://$host$request_uri;
    }
EOF
  elif [ "$_web_cr_proxy" = "1" ]; then
    cat <<EOF
    location / {
        proxy_pass ${_web_cr_target};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$easysb_connection_upgrade;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
EOF
  else
    cat <<'EOF'
    location / {
        try_files $uri $uri/ /index.html;
    }
EOF
  fi
  printf '}\n'

  # ---- 443 端口 server 块 ----
  if [ "$_web_cr_tls" = "1" ]; then
    cat <<EOF

server {
${_web_cr_listen}
    server_name ${_web_cr_name};

    ssl_certificate     ${_web_cr_crt};
    ssl_certificate_key ${_web_cr_key};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache   shared:easysb_ssl:10m;
    ssl_session_tickets off;

    root ${_web_cr_root};
    index index.html;
    server_tokens off;
    access_log off;

    location /.well-known/acme-challenge/ {
        root ${_web_cr_root};
        default_type "text/plain";
        try_files \$uri =404;
    }

EOF
    if [ "$_web_cr_proxy" = "1" ]; then
      cat <<EOF
    location / {
        proxy_pass ${_web_cr_target};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$easysb_connection_upgrade;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF
    else
      cat <<'EOF'
    location / {
        try_files $uri $uri/ /index.html;
    }
}
EOF
    fi
  fi
  return 0
}

# 写本工具的 nginx 配置（先备份旧版本，失败可从 .easysb.bak 恢复）
_web_conf_write() {
  local _web_cw_tpl="${1:-blog}" _web_cw_tls="${2:-0}"
  local _web_cw_conf _web_cw_dir _web_cw_bak
  _web_cw_conf="$(_web_conf_file)"
  _web_cw_dir="$(dirname "$_web_cw_conf")"
  _web_cw_bak="$(_web_conf_bak "$_web_cw_conf")"

  if ! _web_conf_owned "$_web_cw_conf"; then
    error "拒绝写入非本工具管理的 nginx 配置：$_web_cw_conf（文件名必须包含 easysb）"
    return 1
  fi
  if ! mkdir -p "$_web_cw_dir" 2>/dev/null; then
    error "无法创建 nginx 配置目录：$_web_cw_dir"
    return 1
  fi
  if [ -f "$_web_cw_conf" ]; then
    if ! cp -f "$_web_cw_conf" "$_web_cw_bak" 2>/dev/null; then
      log_warn "无法备份现有配置（$_web_cw_bak），继续写入"
    fi
  fi
  if ! _web_conf_render "$_web_cw_tpl" "$_web_cw_tls" | file_write "$_web_cw_conf" 644; then
    error "写入 nginx 配置失败：$_web_cw_conf"
    return 1
  fi
  log_info "已生成 nginx 配置：$_web_cw_conf"
  return 0
}

# 回滚到写入前的配置（没有备份就删除）
_web_conf_rollback() {
  local _web_crb_conf _web_crb_bak
  _web_crb_conf="$(_web_conf_file)"
  _web_crb_bak="$(_web_conf_bak "$_web_crb_conf")"
  if [ -f "$_web_crb_bak" ]; then
    if cp -f "$_web_crb_bak" "$_web_crb_conf" 2>/dev/null; then
      log_warn "已恢复到写入前的 nginx 配置：$_web_crb_conf"
    else
      log_warn "恢复 nginx 配置失败，请手工检查：$_web_crb_conf"
    fi
    return 0
  fi
  rm -f "$_web_crb_conf" 2>/dev/null || true
  log_warn "已移除本次生成的 nginx 配置：$_web_crb_conf"
  return 0
}

# ---------------------------------------------------------------------------
# 对外 API：部署 / 关闭 / 状态
# ---------------------------------------------------------------------------
web_deploy() {
  local _web_dp_key="${1-}"
  local _web_dp_conf _web_dp_root _web_dp_target="" _web_dp_tls=0

  if ! _web_template_known "$_web_dp_key"; then
    error "未知的站点模板：${_web_dp_key:-（空）}（可选：blog / corp / blank / custom / proxy）"
    return 1
  fi
  if ! web_installed; then
    error "nginx 未安装，请先执行 web_install"
    return 1
  fi
  if [ ! -f "$ESB_STATE" ]; then
    if ! state_init; then
      error "无法初始化状态文件：$ESB_STATE"
      return 1
    fi
  fi

  _web_dp_conf="$(_web_conf_file)"
  _web_dp_root="$(_web_root)"

  if [ "$_web_dp_key" = "proxy" ]; then
    _web_dp_target="$(_web_normalize_url "$(state_get .web.proxy_target)")"
    if [ -z "$_web_dp_target" ]; then
      error "反向代理模板需要先设置目标地址（state .web.proxy_target，例如 https://example.org）"
      return 1
    fi
    case "$_web_dp_target" in
      http://*|https://*) ;;
      *)
        error "反向代理目标必须以 http:// 或 https:// 开头：$_web_dp_target"
        return 1
        ;;
    esac
  fi

  if ! mkdir -p "${_web_dp_root}/.well-known/acme-challenge" 2>/dev/null; then
    error "无法创建站点根目录：$_web_dp_root"
    return 1
  fi

  if [ "$_web_dp_key" != "proxy" ]; then
    if ! _web_page_write "$_web_dp_key"; then
      return 1
    fi
  fi

  if _web_tls_ready; then _web_dp_tls=1; fi
  if ! _web_conf_write "$_web_dp_key" "$_web_dp_tls"; then
    return 1
  fi
  if ! web_reload; then
    log_err "nginx 配置校验/重载失败，已回滚本次生成的配置"
    _web_conf_rollback
    return 1
  fi

  state_set_str ".web.template" "$_web_dp_key" >/dev/null 2>&1 || true
  state_set_str ".web.root" "$_web_dp_root" >/dev/null 2>&1 || true
  state_set ".web.enabled" "true" >/dev/null 2>&1 || true
  if [ -z "$(state_get .web.http_port)" ]; then
    state_set ".web.http_port" "80" >/dev/null 2>&1 || true
  fi

  log_ok "伪装站点已部署：$_web_dp_key（$(_web_template_label "$_web_dp_key")）"
  log_info "站点根目录：$_web_dp_root"
  if [ "$_web_dp_tls" = "1" ]; then
    log_ok "已同时启用 443（HTTPS）站点：$(state_get .cert.domain)"
  elif [ "$(state_get .web.tls)" = "true" ]; then
    log_warn "已请求 HTTPS，但证书缺失或端口冲突，本次仅生成 80 站点（可用 web_apply_cert 查看原因）"
  fi
  return 0
}

web_disable() {
  local _web_ds_conf _web_ds_bak
  _web_ds_conf="$(_web_conf_file)"
  _web_ds_bak="$(_web_conf_bak "$_web_ds_conf")"

  if [ ! -f "$_web_ds_conf" ]; then
    state_set ".web.enabled" "false" >/dev/null 2>&1 || true
    log_info "伪装站点未部署（找不到 $_web_ds_conf），已同步状态"
    return 0
  fi
  if ! _web_conf_owned "$_web_ds_conf"; then
    error "拒绝删除非本工具管理的 nginx 配置：$_web_ds_conf（文件名必须包含 easysb）"
    return 1
  fi

  # 保留一份可恢复的备份（扩展名不是 .conf，不会被 nginx 加载）
  cp -f "$_web_ds_conf" "$_web_ds_bak" 2>/dev/null || log_warn "无法备份待删除的配置：$_web_ds_bak"
  if ! rm -f "$_web_ds_conf" 2>/dev/null; then
    error "无法删除 nginx 配置：$_web_ds_conf"
    return 1
  fi
  log_info "已移除 nginx 配置：$_web_ds_conf"

  if ! web_reload; then
    log_warn "移除配置后 nginx 校验未通过，备份保留在 $_web_ds_bak"
    return 1
  fi
  state_set ".web.enabled" "false" >/dev/null 2>&1 || true
  log_ok "伪装站点已关闭（站点根目录内容保留：$(_web_root)）"
  return 0
}

web_status() {
  local _web_st_conf _web_st_root _web_st_installed="未安装" _web_st_run="未知"
  local _web_st_deployed="未部署" _web_st_tpl="-" _web_st_tls="未启用" _web_st_443="未写入"
  local _web_st_cert="未应用" _web_st_target="-" _web_st_http="80" _web_st_tls_port="443" _web_st_rc=1
  local _web_st_body="" _web_st_crt="" _web_st_key=""

  _web_st_conf="$(_web_conf_file)"
  _web_st_root="$(_web_root)"
  _web_st_http="$(state_get .web.http_port)"
  if [ -z "$_web_st_http" ]; then _web_st_http="80"; fi
  _web_st_tls_port="$(_web_tls_port)"

  if web_installed; then
    _web_st_installed="已安装（nginx/$(_web_nginx_version)）"
  fi
  if [ "${ESB_INIT:-none}" != "none" ] || [ -x "${ESB_ROOT:-}/etc/init.d/nginx" ]; then
    if _web_service status; then _web_st_run="运行中"; else _web_st_run="未运行"; fi
  fi

  if [ -f "$_web_st_conf" ]; then
    _web_st_deployed="已部署"
    _web_st_rc=0
  fi
  _web_st_tpl="$(state_get .web.template)"
  if [ -z "$_web_st_tpl" ]; then _web_st_tpl="blog"; fi

  if [ "$(state_get .web.tls)" = "true" ]; then
    _web_st_tls="已启用（端口 ${_web_st_tls_port}）"
  fi
  if [ -f "$_web_st_conf" ]; then
    if grep -qE "^[[:space:]]*listen[[:space:]]+(\[::\]:)?${_web_st_tls_port}[[:space:]]+ssl" "$_web_st_conf" 2>/dev/null; then
      _web_st_443="已写入"
    fi
  fi
  _web_st_crt="$(_web_resolve_path "$(state_get .cert.crt)" || true)"
  _web_st_key="$(_web_resolve_path "$(state_get .cert.key)" || true)"
  if [ -n "$_web_st_crt" ] && [ -n "$_web_st_key" ]; then
    _web_st_cert="$(state_get .cert.domain)"
    if [ -z "$_web_st_cert" ]; then _web_st_cert="已应用"; fi
    _web_st_cert="${_web_st_cert}（$(basename "$_web_st_crt") + $(basename "$_web_st_key")）"
  fi
  _web_st_target="$(trim "$(state_get .web.proxy_target)")"
  if [ -z "$_web_st_target" ]; then _web_st_target="-"; fi

  printf '%s\n' "伪装站点（nginx）"
  printf '  %-16s: %s\n' "nginx" "$_web_st_installed"
  printf '  %-16s: %s\n' "nginx 服务" "$_web_st_run"
  printf '  %-16s: %s\n' "站点状态" "$_web_st_deployed"
  printf '  %-16s: %s（%s）\n' "站点模板" "$_web_st_tpl" "$(_web_template_label "$_web_st_tpl")"
  printf '  %-16s: %s\n' "站点根目录" "$_web_st_root"
  printf '  %-16s: %s\n' "HTTP 端口" "$_web_st_http"
  printf '  %-16s: %s\n' "HTTPS" "$_web_st_tls"
  printf '  %-16s: %s\n' "443 配置" "$_web_st_443"
  printf '  %-16s: %s\n' "证书" "$_web_st_cert"
  printf '  %-16s: %s\n' "反代目标" "$_web_st_target"
  printf '  %-16s: %s\n' "ACME webroot" "${_web_st_root}/.well-known/acme-challenge"
  printf '  %-16s: %s\n' "配置文件" "$_web_st_conf"
  return "$_web_st_rc"
}

# ---------------------------------------------------------------------------
# 对外 API：ACME webroot / 443 证书 / 端口检查
# ---------------------------------------------------------------------------
web_acme_webroot() {
  local _web_aw_root _web_aw_dir
  _web_aw_root="$(_web_root)"
  _web_aw_dir="${_web_aw_root}/.well-known/acme-challenge"
  if ! mkdir -p "$_web_aw_dir" 2>/dev/null; then
    error "无法创建 ACME 挑战目录：$_web_aw_dir"
    return 1
  fi
  chmod 755 "$_web_aw_root" "$_web_aw_root/.well-known" "$_web_aw_dir" 2>/dev/null || true
  printf '%s\n' "$_web_aw_dir"
  return 0
}

# 把已应用的证书写进 nginx（443）。端口被已启用的 TCP 协议占用时拒绝，保持 80 单端口站点。
web_apply_cert() {
  local _web_ac_conf _web_ac_port _web_ac_owner _web_ac_crt="" _web_ac_key="" _web_ac_tpl=""
  local _web_ac_conflict_port=""

  _web_ac_conf="$(_web_conf_file)"
  _web_ac_port="$(_web_tls_port)"

  if [ "$(state_get .web.tls)" != "true" ]; then
    error "伪装站点未启用 HTTPS（state .web.tls 不是 true），未写入 443 配置（站点仍为 80）"
    return 1
  fi
  if ! validate_port "$_web_ac_port"; then
    return 1
  fi
  if ! web_installed; then
    error "nginx 未安装，请先执行 web_install"
    return 1
  fi

  # 1) 与已启用的 TCP 协议抢端口 → 直接拒绝，绝不制造端口冲突
  _web_ac_owner="$(_web_tcp_conflict "$_web_ac_port")"
  if [ -n "$_web_ac_owner" ]; then
    log_warn "伪装站点保持仅 80 端口：端口 ${_web_ac_port} 已被启用的协议 ${_web_ac_owner} 占用，未写入 443 配置"
    error "拒绝写入 443 站点配置：端口 ${_web_ac_port} 与已启用协议 ${_web_ac_owner} 冲突（可改 .web.tls_port 或关闭该协议后重试）"
    # 状态必须如实反映结果：否则订阅地址会给出一个并不存在的 https 地址
    state_set ".web.tls" "false" >/dev/null 2>&1 || true
    return 1
  fi

  # 2) 证书必须真实存在
  _web_ac_crt="$(_web_tls_cert_paths | sed -n 1p)"
  _web_ac_key="$(_web_tls_cert_paths | sed -n 2p)"
  if [ -z "$_web_ac_crt" ] || [ -z "$_web_ac_key" ]; then
    error "没有可用的证书文件（state .cert.crt / .cert.key），请先在证书管理中申请并应用证书"
    state_set ".web.tls" "false" >/dev/null 2>&1 || true
    return 1
  fi

  # 3) 端口被本机其它进程占用时给出明确警告（reload 会失败并自动回滚）
  if port_in_use "$_web_ac_port" tcp; then
    if ! _web_port_is_ours "$_web_ac_port"; then
      log_warn "端口 ${_web_ac_port} 已被本机其它进程占用，nginx 可能无法监听该端口"
    fi
  fi

  _web_ac_tpl="$(state_get .web.template)"
  if ! _web_template_known "$_web_ac_tpl"; then _web_ac_tpl="blog"; fi

  if ! _web_conf_write "$_web_ac_tpl" 1; then
    return 1
  fi
  if ! web_reload; then
    log_err "nginx 校验/重载失败，已回滚 443 配置"
    _web_conf_rollback
    state_set ".web.tls" "false" >/dev/null 2>&1 || true
    return 1
  fi
  log_ok "已写入 443（HTTPS）站点配置：$_web_ac_conf"
  log_info "证书：$_web_ac_crt"
  return 0
}

# 端口是否被本工具自己的伪装站点占用（配置里声明了 listen 且 nginx 已安装）
_web_port_is_ours() {
  local _web_po_port="${1-}" _web_po_conf
  _web_po_conf="$(_web_conf_file)"
  if [ ! -f "$_web_po_conf" ]; then return 1; fi
  if ! grep -qE "^[[:space:]]*listen[[:space:]]+(\[::\]:)?${_web_po_port}([[:space:]]|;|\$)" "$_web_po_conf" 2>/dev/null; then
    return 1
  fi
  web_installed || return 1
  return 0
}

# 0 = 端口可用（空闲，或只被本工具自己的伪装站点占用）
web_port_free() {
  local _web_pf_port="${1-}"
  if ! validate_port "$_web_pf_port" >/dev/null 2>&1; then
    error "端口无效：${_web_pf_port:-（空）}（应为 1-65535 的整数）"
    return 1
  fi
  if ! port_in_use "$_web_pf_port" tcp; then
    return 0
  fi
  if _web_port_is_ours "$_web_pf_port"; then
    log_debug "端口 $_web_pf_port 由本工具的伪装站点占用，视为可用"
    return 0
  fi
  log_warn "端口 $_web_pf_port 已被其它进程占用"
  return 1
}


# ===== 内联模块：lib/80-subscribe.sh =====
#!/usr/bin/env bash
# =============================================================================
# EasySB — 80-subscribe.sh
# 节点链接与订阅：分享链接输出、多格式订阅文件（base64 通用 / sing-box JSON /
# Mihomo(Clash) YAML）、订阅站点（复用伪装站点或独立 nginx 站点）、订阅 URL 与二维码
# 依赖：00-core.sh, 10-detect.sh, 20-state.sh, 40-render.sh
# =============================================================================
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# token / 路径
# ---------------------------------------------------------------------------
sub_token() {
  local _sub_token_tok
  _sub_token_tok="$(state_get .sub.token)"
  if [ -z "$_sub_token_tok" ]; then
    _sub_token_tok="$(gen_hex 16)"
    state_set_str ".sub.token" "$_sub_token_tok" || return 1
  fi
  printf '%s\n' "$_sub_token_tok"
  return 0
}

sub_token_regen() {
  local _sub_token_regen_tok
  _sub_token_regen_tok="$(gen_hex 16)"
  state_set_str ".sub.token" "$_sub_token_regen_tok" || return 1
  printf '%s\n' "$_sub_token_regen_tok"
  return 0
}

# 订阅是否复用伪装站点（伪装站点开启时自动复用）
sub_use_site() {
  if [ "$(state_get .web.enabled)" = "true" ] && [ "$(state_get .sub.serve_via_site)" = "true" ]; then
    return 0
  fi
  return 1
}

sub_url_base() {
  local _sub_url_base_domain _sub_url_base_scheme _sub_url_base_port="" _sub_url_base_wport=""
  _sub_url_base_domain="$(state_get .domain)"
  if sub_use_site; then
    if [ "$(state_get .web.tls)" = "true" ] && [ -f "$(state_get .cert.crt)" ]; then
      _sub_url_base_scheme="https"
      _sub_url_base_wport="$(state_get .web.tls_port)"
      [ "$_sub_url_base_wport" = "443" ] || _sub_url_base_port=":${_sub_url_base_wport}"
    else
      _sub_url_base_scheme="http"
      _sub_url_base_wport="$(state_get .web.http_port)"
      [ "$_sub_url_base_wport" = "80" ] || _sub_url_base_port=":${_sub_url_base_wport}"
    fi
    printf '%s://%s%s/sub/%s\n' "$_sub_url_base_scheme" "$_sub_url_base_domain" "$_sub_url_base_port" "$(sub_token)"
  else
    _sub_url_base_port="$(state_get .sub.port)"; [ -n "$_sub_url_base_port" ] || _sub_url_base_port=8080
    [ "$_sub_url_base_port" = "80" ] || _sub_url_base_port=":${_sub_url_base_port}"
    printf 'http://%s%s/sub/%s\n' "$_sub_url_base_domain" "$_sub_url_base_port" "$(sub_token)"
  fi
  return 0
}

# 订阅文件所在目录（token 目录）
sub_dir() {
  local _sub_dir_root=""
  if sub_use_site; then
    # 站点根目录以 web 模块的解析结果为准（它保证路径落在 ESB_ROOT 之下）
    if command -v _web_root >/dev/null 2>&1; then
      _sub_dir_root="$(_web_root)"
    else
      _sub_dir_root="$(esb_rooted "$(state_get .web.root)")"
    fi
  else
    _sub_dir_root="$(esb_rooted "$(state_get .sub.root)")"
  fi
  [ -n "$_sub_dir_root" ] || _sub_dir_root="${ESB_ROOT}/var/www/easysb-sub"
  printf '%s/sub/%s\n' "$_sub_dir_root" "$(sub_token)"
  return 0
}

sub_formats() {
  cat <<'EOF'
base64	通用订阅（v2rayN / Shadowrocket / NekoBox 等，Base64 节点列表）
links	纯文本节点链接（每行一条）
singbox	sing-box 客户端配置（JSON）
mihomo	Mihomo / Clash 配置（YAML）
EOF
  return 0
}

# ---------------------------------------------------------------------------
# 生成内容
# ---------------------------------------------------------------------------
sub_links_text() {
  local _sub_links_text_l
  render_links | while IFS= read -r _sub_links_text_l; do
    [ -n "$_sub_links_text_l" ] || continue
    printf '%s\n' "$_sub_links_text_l"
  done
  return 0
}

sub_links_base64() {
  sub_links_text | base64 | tr -d '\n'
  printf '\n'
  return 0
}

_mihomo_yaml_quote() {
  # YAML 双引号字符串转义（值里可能出现的反斜杠与双引号都要转义）
  local _mhq_s="$1"
  _mhq_s="$(printf '%s' "$_mhq_s" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  printf '"%s"' "$_mhq_s"
  return 0
}

sub_mihomo_yaml() {
  local _mh_domain _mh_port _mh_p _mh_name _mh_prefix
  _mh_domain="$(state_get .domain)"
  [ -n "$_mh_domain" ] || { error "尚未设置域名，无法生成 Mihomo 配置"; return 1; }
  _mh_prefix="$(state_get .sub.name)"; [ -n "$_mh_prefix" ] || _mh_prefix="EasySB"

  printf '# EasySB 订阅 · Mihomo/Clash 配置（由脚本生成，请勿手改）\n'
  printf 'mixed-port: 7890\n'
  printf 'allow-lan: false\n'
  printf 'mode: rule\n'
  printf 'log-level: warning\n'
  printf 'ipv6: false\n'
  printf 'external-controller: 127.0.0.1:9090\n'
  printf 'dns:\n'
  printf '  enable: true\n'
  printf '  ipv6: false\n'
  printf '  enhanced-mode: fake-ip\n'
  printf '  fake-ip-range: 198.18.0.1/16\n'
  printf '  nameserver:\n'
  printf '    - https://223.5.5.5/dns-query\n'
  printf '    - https://1.1.1.1/dns-query\n'
  printf '  fallback:\n'
  printf '    - https://8.8.8.8/dns-query\n'
  printf 'proxies:\n'

  local _mh_names=""
  for _mh_p in $(proto_enabled_list); do
    _mh_name="$(printf '%s-%s' "$_mh_prefix" "$_mh_p")"
    _mh_names="$_mh_names $_mh_name"
    _mh_port="$(proto_port "$_mh_p")"
    case "$_mh_p" in
      vless-vision-reality)
        printf '  - name: %s\n' "$(_mihomo_yaml_quote "$_mh_name")"
        printf '    type: vless\n'
        printf '    server: %s\n' "$(_mihomo_yaml_quote "$_mh_domain")"
        printf '    port: %s\n' "$_mh_port"
        printf '    uuid: %s\n' "$(_mihomo_yaml_quote "$(secret_get vless_uuid)")"
        printf '    network: tcp\n'
        printf '    tls: true\n'
        printf '    udp: true\n'
        printf '    flow: xtls-rprx-vision\n'
        printf '    servername: %s\n' "$(_mihomo_yaml_quote "$(state_get .reality.server_name)")"
        printf '    client-fingerprint: chrome\n'
        printf '    reality-opts:\n'
        printf '      public-key: %s\n' "$(_mihomo_yaml_quote "$(state_get .reality.public_key)")"
        printf '      short-id: %s\n' "$(_mihomo_yaml_quote "$(state_get .reality.short_id)")"
        ;;
      vmess-ws-tls)
        printf '  - name: %s\n' "$(_mihomo_yaml_quote "$_mh_name")"
        printf '    type: vmess\n'
        printf '    server: %s\n' "$(_mihomo_yaml_quote "$_mh_domain")"
        printf '    port: %s\n' "$_mh_port"
        printf '    uuid: %s\n' "$(_mihomo_yaml_quote "$(secret_get vmess_uuid)")"
        printf '    alterId: 0\n'
        printf '    cipher: auto\n'
        printf '    udp: true\n'
        printf '    tls: true\n'
        printf '    servername: %s\n' "$(_mihomo_yaml_quote "$_mh_domain")"
        printf '    client-fingerprint: chrome\n'
        printf '    network: ws\n'
        printf '    ws-opts:\n'
        printf '      path: %s\n' "$(_mihomo_yaml_quote "$(state_get '.protocols["vmess-ws-tls"].path')")"
        printf '      headers:\n'
        printf '        Host: %s\n' "$(_mihomo_yaml_quote "$_mh_domain")"
        ;;
      hysteria2)
        printf '  - name: %s\n' "$(_mihomo_yaml_quote "$_mh_name")"
        printf '    type: hysteria2\n'
        printf '    server: %s\n' "$(_mihomo_yaml_quote "$_mh_domain")"
        printf '    port: %s\n' "$_mh_port"
        printf '    password: %s\n' "$(_mihomo_yaml_quote "$(secret_get hysteria2_password)")"
        printf '    sni: %s\n' "$(_mihomo_yaml_quote "$_mh_domain")"
        printf '    alpn:\n'
        printf '      - h3\n'
        printf '    skip-cert-verify: false\n'
        if [ "$(state_get '.protocols.hysteria2.hop.enabled')" = "true" ]; then
          printf '    ports: %s\n' "$(_mihomo_yaml_quote "$(state_get '.protocols.hysteria2.hop.range')")"
          printf '    hop-interval: %s\n' "$(printf '%s' "$(state_get '.protocols.hysteria2.hop.interval')" | tr -d 's')"
        fi
        ;;
      tuic)
        printf '  - name: %s\n' "$(_mihomo_yaml_quote "$_mh_name")"
        printf '    type: tuic\n'
        printf '    server: %s\n' "$(_mihomo_yaml_quote "$_mh_domain")"
        printf '    port: %s\n' "$_mh_port"
        printf '    uuid: %s\n' "$(_mihomo_yaml_quote "$(secret_get tuic_uuid)")"
        printf '    password: %s\n' "$(_mihomo_yaml_quote "$(secret_get tuic_password)")"
        printf '    congestion-controller: bbr\n'
        printf '    udp-relay-mode: native\n'
        printf '    sni: %s\n' "$(_mihomo_yaml_quote "$_mh_domain")"
        printf '    alpn:\n'
        printf '      - h3\n'
        ;;
      anytls)
        printf '  - name: %s\n' "$(_mihomo_yaml_quote "$_mh_name")"
        printf '    type: anytls\n'
        printf '    server: %s\n' "$(_mihomo_yaml_quote "$_mh_domain")"
        printf '    port: %s\n' "$_mh_port"
        printf '    password: %s\n' "$(_mihomo_yaml_quote "$(secret_get anytls_password)")"
        printf '    sni: %s\n' "$(_mihomo_yaml_quote "$_mh_domain")"
        printf '    udp: true\n'
        printf '    client-fingerprint: chrome\n'
        ;;
    esac
  done

  local _mh_list=""
  local _mh_n
  for _mh_n in $_mh_names; do
    _mh_list="${_mh_list}      - ${_mh_n}\n"
  done
  printf 'proxy-groups:\n'
  printf '  - name: PROXY\n'
  printf '    type: select\n'
  printf '    proxies:\n'
  printf '      - AUTO\n'
  printf '%b' "$_mh_list"
  printf '  - name: AUTO\n'
  printf '    type: url-test\n'
  printf '    url: http://www.gstatic.com/generate_204\n'
  printf '    interval: 300\n'
  printf '    tolerance: 50\n'
  printf '    proxies:\n'
  printf '%b' "$_mh_list"
  printf 'rules:\n'
  printf '  - GEOIP,private,DIRECT,no-resolve\n'
  printf '  - GEOSITE,cn,DIRECT\n'
  printf '  - GEOIP,CN,DIRECT\n'
  printf '  - MATCH,PROXY\n'
  return 0
}

sub_singbox_json() {
  local _sub_singbox_json_src="${ESB_CLIENT_DIR}/all.json"
  [ -f "$_sub_singbox_json_src" ] || { render_client_all || return 1; }
  cat "$_sub_singbox_json_src"
  return 0
}

# ---------------------------------------------------------------------------
# 写入订阅文件
# ---------------------------------------------------------------------------
sub_write_files() {
  local _sub_write_dir
  _sub_write_dir="$(sub_dir)"
  mkdir -p "$_sub_write_dir" || { error "无法创建订阅目录 $_sub_write_dir"; return 1; }
  # nginx 以自己的用户读取订阅文件，因此这里放宽到 644/755（订阅目录里只有节点信息，
  # 泄露等同于节点泄露 —— URL 里的 token 就是访问凭据，务必不要在公开渠道分享订阅 URL）
  chmod 755 "$(dirname "$_sub_write_dir")" 2>/dev/null || true
  chmod 755 "$_sub_write_dir" 2>/dev/null || true

  local _sub_write_tmp="${ESB_TMP}/sub.$$"
  mkdir -p "$_sub_write_tmp" || return 1

  sub_links_text >"${_sub_write_tmp}/links.txt" || return 1
  sub_links_base64 >"${_sub_write_tmp}/sub" || return 1
  sub_singbox_json >"${_sub_write_tmp}/singbox.json" || return 1
  if sub_mihomo_yaml >"${_sub_write_tmp}/mihomo.yaml"; then
    :
  else
    log_warn "Mihomo 配置生成失败（已跳过该格式）"
    rm -f "${_sub_write_tmp}/mihomo.yaml"
  fi
  {
    printf 'EasySB 订阅信息\n'
    printf '生成时间：%s\n' "$(esb_now)"
    printf '域名：%s\n' "$(state_get .domain)"
    printf '协议：%s\n' "$(proto_enabled_list)"
    printf '说明：本目录内容包含全部节点凭据，请勿公开分享。\n'
  } >"${_sub_write_tmp}/info.txt"

  local _sub_write_f
  for _sub_write_f in "$_sub_write_tmp"/*; do
    [ -f "$_sub_write_f" ] || continue
    chmod 644 "$_sub_write_f" 2>/dev/null || true
    mv -f "$_sub_write_f" "${_sub_write_dir}/" || { error "写入订阅文件失败：$_sub_write_f"; return 1; }
  done
  rm -rf "$_sub_write_tmp"

  # 本地也留一份纯文本链接，方便直接复制
  sub_links_text >"${ESB_CLIENT_DIR}/links.txt" 2>/dev/null || true
  chmod 600 "${ESB_CLIENT_DIR}/links.txt" 2>/dev/null || true
  log_ok "订阅文件已生成：$_sub_write_dir"
  return 0
}

sub_url_list() {
  local _sub_url_base
  _sub_url_base="$(sub_url_base)"
  printf 'base64\t%s/sub\n' "$_sub_url_base"
  printf 'links\t%s/links.txt\n' "$_sub_url_base"
  printf 'singbox\t%s/singbox.json\n' "$_sub_url_base"
  printf 'mihomo\t%s/mihomo.yaml\n' "$_sub_url_base"
  return 0
}

sub_url() {
  # 主订阅地址（通用 Base64，客户端里填这个）
  printf '%s/sub\n' "$(sub_url_base)"
  return 0
}

# ---------------------------------------------------------------------------
# 订阅站点
# ---------------------------------------------------------------------------
sub_nginx_conf() {
  printf '%s/easysb-sub.conf\n' "$(dirname "$ESB_NGINX_CONF")"
  return 0
}

sub_nginx_conf_dir() {
  local _sub_nginx_conf_dir_d
  for _sub_nginx_conf_dir_d in \
      "${ESB_ROOT}/etc/nginx/conf.d" \
      "${ESB_ROOT}/etc/nginx/http.d" \
      "${ESB_ROOT}/etc/nginx/sites-enabled"; do
    if [ -d "$_sub_nginx_conf_dir_d" ]; then printf '%s\n' "$_sub_nginx_conf_dir_d"; return 0; fi
  done
  printf '%s\n' "${ESB_ROOT}/etc/nginx/conf.d"
  return 0
}

sub_site_deploy() {
  local _sub_site_deploy_root _sub_site_deploy_port _sub_site_deploy_conf
  _sub_site_deploy_root="$(esb_rooted "$(state_get .sub.root)")"
  [ -n "$_sub_site_deploy_root" ] || _sub_site_deploy_root="${ESB_ROOT}/var/www/easysb-sub"
  _sub_site_deploy_port="$(state_get .sub.port)"; [ -n "$_sub_site_deploy_port" ] || _sub_site_deploy_port=8080
  _sub_site_deploy_conf="$(sub_nginx_conf_dir)/easysb-sub.conf"

  if ! web_installed; then
    log_warn "未安装 nginx，无法部署订阅站点"
    return 1
  fi
  mkdir -p "$_sub_site_deploy_root" 2>/dev/null || return 1
  mkdir -p "$(dirname "$_sub_site_deploy_conf")" 2>/dev/null || return 1

  cat <<EOF | file_write "$_sub_site_deploy_conf" 644
# EasySB 订阅站点（由 EasySB 自动生成，请勿手动修改；需要删除请用脚本菜单）
server {
    listen ${_sub_site_deploy_port};
    listen [::]:${_sub_site_deploy_port};
    server_name _;
    root ${_sub_site_deploy_root};
    autoindex off;
    access_log off;

    location /sub/ {
        add_header Cache-Control "no-store";
        try_files \$uri \$uri/ =404;
    }

    location / {
        return 404;
    }
}
EOF
  if ! run_gate "nginx -t" nginx -t >/dev/null 2>&1; then
    log_warn "nginx 配置校验未通过，已移除订阅站点配置"
    rm -f "$_sub_site_deploy_conf" 2>/dev/null || true
    return 1
  fi
  service_mgr nginx reload >/dev/null 2>&1 || service_mgr nginx restart >/dev/null 2>&1 || true
  log_ok "订阅站点已部署：http://$(state_get .domain):${_sub_site_deploy_port}/sub/<token>/"
  return 0
}

sub_site_remove() {
  local _sub_site_remove_conf
  _sub_site_remove_conf="$(sub_nginx_conf_dir)/easysb-sub.conf"
  [ -f "$_sub_site_remove_conf" ] || return 0
  rm -f "$_sub_site_remove_conf" 2>/dev/null || true
  if run_gate "nginx -t" nginx -t >/dev/null 2>&1; then
    service_mgr nginx reload >/dev/null 2>&1 || true
  fi
  log_info "已移除独立订阅站点配置"
  return 0
}

sub_enable() {
  if [ -z "$(proto_enabled_list)" ]; then
    error "尚未启用任何协议，无法生成订阅"
    return 1
  fi
  local _sub_enable_port
  render_clients >/dev/null 2>&1 || true
  sub_write_files || return 1
  if ! sub_use_site; then
    _sub_enable_port="$(state_get .sub.port)"; [ -n "$_sub_enable_port" ] || _sub_enable_port=8080
    sub_site_deploy || log_warn "订阅站点部署失败，订阅文件已生成在 $(sub_dir)"
    fw_open "$_sub_enable_port" tcp >/dev/null 2>&1 || true
  fi
  state_set ".sub.enabled" "true" >/dev/null 2>&1 || true
  log_ok "订阅已启用"
  return 0
}

sub_disable() {
  state_set ".sub.enabled" "false" >/dev/null 2>&1 || true
  sub_site_remove
  fw_close "$(state_get .sub.port)" tcp >/dev/null 2>&1 || true
  log_info "订阅已关闭（订阅文件仍保留在 $(sub_dir)）"
  return 0
}

sub_status() {
  local _sub_status_enabled _sub_status_dir
  _sub_status_enabled="$(state_get .sub.enabled)"
  _sub_status_dir="$(sub_dir)"
  printf '  订阅状态　：%s\n' "$([ "$_sub_status_enabled" = "true" ] && echo '已启用' || echo '未启用')"
  printf '  订阅目录　：%s\n' "$_sub_status_dir"
  if [ "$_sub_status_enabled" = "true" ]; then
    printf '  订阅地址　：%s\n' "$(sub_url)"
    sub_url_list | while IFS="$(printf '\t')" read -r _sub_status_k _sub_status_v; do
      printf '    %-9s %s\n' "$_sub_status_k" "$_sub_status_v"
    done
  fi
  return 0
}

sub_refresh() {
  # 配置变更后刷新订阅内容（静默、失败不影响主流程）
  if [ "$(state_get .sub.enabled)" = "true" ]; then
    render_clients >/dev/null 2>&1 || true
    sub_write_files >/dev/null 2>&1 || log_warn "订阅文件刷新失败，可在菜单中手动重新生成"
  fi
  return 0
}


# ===== 内联模块：lib/90-ui.sh =====
#!/usr/bin/env bash
# =============================================================================
# EasySB — 90-ui.sh
# 交互层：主菜单 / 部署向导 / 证书管理 / 伪装站点 / 更新 / 客户端 / 状态 / 卸载
# 依赖：全部模块
# =============================================================================
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# 主菜单
# ---------------------------------------------------------------------------
ui_main() {
  local _ui_main_choice=""
  while :; do
    ui_title "EasySB · sing-box 一键部署管理面板 v${ESB_SCRIPT_VERSION}"
    sb_status_line
    ui_blank
    printf '  1) 一键部署 / 修改部署\n'
    printf '  2) 运行状态\n'
    printf '  3) 服务管理（启动 / 停止 / 重启 / 日志）\n'
    printf '  4) 证书管理（申请 / 列表 / 应用 / 删除）\n'
    printf '  5) 伪装站点\n'
    printf '  6) 客户端配置与分享链接\n'
    printf '  7) 更新（sing-box 内核 / EasySB 脚本）\n'
    printf '  8) 卸载 EasySB\n'
    printf '  0) 退出\n'
    ui_blank
    printf '请选择 [0-8]: '
    IFS= read -r _ui_main_choice || _ui_main_choice="0"
    _ui_main_choice="${_ui_main_choice%$'\r'}"
    case "$_ui_main_choice" in
      1) ui_deploy_wizard ;;
      2) ui_status_menu ;;
      3) ui_service_menu ;;
      4) ui_cert_menu ;;
      5) ui_web_menu ;;
      6) ui_clients_menu ;;
      7) ui_update_menu ;;
      8) ui_uninstall ;;
      0|q|Q|exit|quit) log_info "已退出"; return 0 ;;
      '') ;;
      *) log_warn "无效的选项：$_ui_main_choice" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
ui_status_menu() {
  ui_title "运行状态"
  sb_status_line
  ui_blank
  if [ -f "$ESB_STATE" ]; then
    render_summary
  else
    log_warn "尚未部署（找不到 $ESB_STATE）"
  fi
  ui_blank
  printf '  配置文件   : %s\n' "$ESB_CONFIG"
  printf '  客户端配置 : %s\n' "$ESB_CLIENT_DIR"
  printf '  日志文件   : %s\n' "$ESB_LOG"
  if [ -f "$ESB_DIR/capabilities.json" ]; then
    printf '  能力探测   : %s\n' "$(jq -c . "$ESB_DIR/capabilities.json" 2>/dev/null | head -c 200)"
  fi
  ui_blank
  fw_status 2>/dev/null || true
  if [ -f "$ESB_WEB_ROOT/index.html" ]; then
    ui_blank
    web_status 2>/dev/null || true
  fi
  pause
  return 0
}

ui_service_menu() {
  local _ui_service_choice=""
  while :; do
    ui_title "服务管理"
    sb_status_line
    ui_blank
    printf '  1) 启动　2) 停止　3) 重启　4) 重载配置　5) 查看实时日志　0) 返回\n'
    printf '请选择: '
    IFS= read -r _ui_service_choice || _ui_service_choice="0"
    _ui_service_choice="${_ui_service_choice%$'\r'}"
    case "$_ui_service_choice" in
      1) sb_service start && log_ok "已启动" ;;
      2) sb_service stop && log_ok "已停止" ;;
      3) sb_service restart && log_ok "已重启" ;;
      4) sb_service reload && log_ok "已重载" ;;
      5)
        log_info "按 Ctrl+C 退出日志查看"
        if [ "${ESB_INIT:-systemd}" = "systemd" ]; then
          journalctl -u sing-box -n 60 -f
        elif [ -f "$ESB_LOG" ]; then
          tail -n 60 -f "$ESB_LOG"
        else
          log_warn "没有可用的日志来源"
        fi
        ;;
      0|'') return 0 ;;
      *) log_warn "无效选项" ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# 部署向导
# ---------------------------------------------------------------------------
ui_prompt_domain() {
  local _ui_prompt_domain_val="" _ui_prompt_domain_cur _ui_prompt_domain_rc _ui_prompt_domain_try=0
  _ui_prompt_domain_cur="$(state_get .domain)"
  while :; do
    _ui_prompt_domain_try=$((_ui_prompt_domain_try + 1))
    if [ "$_ui_prompt_domain_try" -gt 5 ] || esb_input_exhausted; then
      error "未获得有效域名（stdin 已结束或连续输入无效），已中止"
      return 1
    fi
    ask_input _ui_prompt_domain_val "请输入部署域名（必填，需已解析到本机）" "$_ui_prompt_domain_cur"
    if ! validate_domain "$_ui_prompt_domain_val"; then continue; fi
    domain_resolves_to "$_ui_prompt_domain_val"
    _ui_prompt_domain_rc=$?
    case "$_ui_prompt_domain_rc" in
      0) log_ok "域名解析正常（指向本机）" ;;
      1) log_warn "该域名解析到别的 IP，证书申请将失败，请确认解析已指向本机 $(detect_local_ips)"
         ask_yesno "仍要使用该域名继续吗？" n || continue ;;
      2) log_warn "域名当前无法解析（可能还没生效），建议先完成解析"
         ask_yesno "忽略并继续吗？" n || continue ;;
      3) log_warn "本机缺少 DNS 查询工具，跳过域名解析检查" ;;
    esac
    state_set_str ".domain" "$_ui_prompt_domain_val" || return 1
    return 0
  done
}

ui_prompt_email() {
  local _ui_prompt_email_val="" _ui_prompt_email_cur
  _ui_prompt_email_cur="$(state_get .email)"
  while :; do
    ask_input _ui_prompt_email_val "请输入 ACME 证书申请邮箱（用于到期提醒）" "$_ui_prompt_email_cur"
    if validate_email "$_ui_prompt_email_val"; then
      state_set_str ".email" "$_ui_prompt_email_val" || return 1
      return 0
    fi
    ask_yesno "邮箱格式看起来不对，仍然使用吗？" n || continue
    state_set_str ".email" "$_ui_prompt_email_val" || return 1
    return 0
  done
}

ui_prompt_protocols() {
  local _ui_prompt_protocols_sel="" _ui_prompt_protocols_k
  local -a _ui_prompt_protocols_items=()
  # 必须用数组传参：协议标签里带空格，拼成字符串再展开会被词分割成乱码菜单
  for _ui_prompt_protocols_k in $(esb_proto_keys); do
    _ui_prompt_protocols_items+=("${_ui_prompt_protocols_k}|$(proto_label "$_ui_prompt_protocols_k" | tr -d '\n')|on")
  done
  ask_multi _ui_prompt_protocols_sel "请选择要部署的协议（默认全部五个）" "${_ui_prompt_protocols_items[@]}"
  if [ -z "$(trim "$_ui_prompt_protocols_sel")" ]; then
    log_warn "没有选择任何协议"
    return 1
  fi
  local _ui_prompt_protocols_p
  for _ui_prompt_protocols_p in $(esb_proto_keys); do
    case " $_ui_prompt_protocols_sel " in
      *" $_ui_prompt_protocols_p "*) state_proto_set_field "$_ui_prompt_protocols_p" ".enabled" "true" || return 1 ;;
      *) state_proto_set_field "$_ui_prompt_protocols_p" ".enabled" "false" || return 1 ;;
    esac
  done
  log_ok "已选择：$(proto_enabled_list)"
  return 0
}

# 端口冲突检查（本工具内部 + 系统占用）
ui_check_ports() {
  local _ui_check_ports_p _ui_check_ports_port _ui_check_ports_proto _ui_check_ports_seen="" _ui_check_ports_bad=0
  for _ui_check_ports_p in $(proto_enabled_list); do
    _ui_check_ports_port="$(proto_port "$_ui_check_ports_p")"
    case "$_ui_check_ports_p" in
      hysteria2|tuic) _ui_check_ports_proto="udp" ;;
      *) _ui_check_ports_proto="tcp" ;;
    esac
    case "$_ui_check_ports_seen" in
      *"$_ui_check_ports_proto/$_ui_check_ports_port"*)
        log_warn "端口冲突：${_ui_check_ports_proto}/${_ui_check_ports_port} 被多个协议使用"
        _ui_check_ports_bad=1
        ;;
    esac
    _ui_check_ports_seen="$_ui_check_ports_seen $_ui_check_ports_proto/$_ui_check_ports_port"
    if port_in_use "$_ui_check_ports_port" "$_ui_check_ports_proto" && [ ! -x "$ESB_BIN" ]; then
      log_warn "${_ui_check_ports_proto}/${_ui_check_ports_port} 已被系统上的其它程序占用（${_ui_check_ports_p}）"
      _ui_check_ports_bad=1
    fi
  done
  return "$_ui_check_ports_bad"
}

ui_prompt_ports() {
  local _ui_prompt_ports_ans="" _ui_prompt_ports_p _ui_prompt_ports_val
  ui_blank
  printf '  默认端口组合（互不冲突）：\n'
  for _ui_prompt_ports_p in $(proto_enabled_list); do
    printf '      %-22s %s/%s\n' "$_ui_prompt_ports_p" \
      "$(case "$_ui_prompt_ports_p" in hysteria2|tuic) echo UDP ;; *) echo TCP ;; esac)" "$(proto_port "$_ui_prompt_ports_p")"
  done
  if ask_yesno "是否修改端口？" n; then
    for _ui_prompt_ports_p in $(proto_enabled_list); do
      while :; do
        ask_input _ui_prompt_ports_val "  ${_ui_prompt_ports_p} 端口" "$(proto_port "$_ui_prompt_ports_p")"
        if validate_port "$_ui_prompt_ports_val"; then
          state_proto_set_field "$_ui_prompt_ports_p" ".port" "$_ui_prompt_ports_val" || return 1
          break
        fi
      done
    done
    ask_input _ui_prompt_ports_ans "是否修改端口跳跃范围（当前 $(state_get '.protocols.hysteria2.hop.range')）？留空保持不变" ""
    if [ -n "$_ui_prompt_ports_ans" ] && validate_port_range "$_ui_prompt_ports_ans" >/dev/null; then
      local _ui_prompt_ports_range
      _ui_prompt_ports_range="$(validate_port_range "$_ui_prompt_ports_ans")"
      state_set_str ".protocols.hysteria2.hop.range" "$_ui_prompt_ports_range"
    fi
  fi
  if proto_enabled hysteria2; then
    if ask_yesno "是否为 Hysteria2 启用端口跳跃（服务端 DNAT 重定向，抗封锁更强）？" y; then
      state_proto_set_field hysteria2 ".hop.enabled" "true" || return 1
      local _ui_prompt_ports_hop
      ask_input _ui_prompt_ports_hop "  端口跳跃范围" "$(state_get '.protocols.hysteria2.hop.range')"
      if validate_port_range "$_ui_prompt_ports_hop" >/dev/null 2>&1; then
        state_set_str ".protocols.hysteria2.hop.range" "$(validate_port_range "$_ui_prompt_ports_hop")" || return 1
      else
        log_warn "范围格式不正确，保持默认 $(state_get '.protocols.hysteria2.hop.range')"
      fi
    else
      state_proto_set_field hysteria2 ".hop.enabled" "false" || return 1
    fi
  fi
  return 0
}

# 生成密钥（已有则保留）
ui_gen_secrets() {
  log_info "生成 / 校验节点密钥…"
  local _ui_gen_secrets_key _ui_gen_secrets_val _ui_gen_secrets_kp
  for _ui_gen_secrets_key in vless_uuid vmess_uuid tuic_uuid tuic_password hysteria2_password anytls_password; do
    _ui_gen_secrets_val="$(secret_get "$_ui_gen_secrets_key")"
    if [ -z "$_ui_gen_secrets_val" ]; then
      case "$_ui_gen_secrets_key" in
        *_uuid) _ui_gen_secrets_val="$(gen_uuid)" ;;
        *)      _ui_gen_secrets_val="$(gen_secret 16)" ;;
      esac
      secret_set "$_ui_gen_secrets_key" "$_ui_gen_secrets_val" || return 1
      log_debug "已生成 $_ui_gen_secrets_key：$(mask_secret "$_ui_gen_secrets_val")"
    fi
  done
  if [ -z "$(state_get .reality.private_key)" ]; then
    _ui_gen_secrets_kp="$(reality_keypair)" || return 1
    state_set_str ".reality.private_key" "${_ui_gen_secrets_kp%% *}" || return 1
    state_set_str ".reality.public_key" "${_ui_gen_secrets_kp##* }" || return 1
    state_set_str ".reality.short_id" "$(gen_hex 4)" || return 1
    log_debug "已生成 REALITY 密钥对"
  fi
  state_set_str ".reality.server_name" "$(state_get .reality.handshake_server)" >/dev/null 2>&1 || true
  return 0
}

ui_install_kernel() {
  local _ui_install_kernel_ver="${1:-latest}"
  if sb_installed; then
    log_ok "已安装 sing-box v$(sb_version)"
    if ! ask_yesno "是否重新安装/切换版本？" n; then return 0; fi
    ask_input _ui_install_kernel_ver "输入版本号（留空=最新）" "latest"
  fi
  sb_install "${_ui_install_kernel_ver:-latest}" || return 1
  return 0
}

# 证书准备（部署过程中调用）
ui_prepare_cert() {
  local _ui_prepare_cert_need=0 _ui_prepare_cert_p
  for _ui_prepare_cert_p in $(proto_enabled_list); do
    if proto_needs_cert "$_ui_prepare_cert_p"; then _ui_prepare_cert_need=1; break; fi
  done
  [ "$_ui_prepare_cert_need" = "1" ] || { log_info "所选协议均无需证书（REALITY 免证书）"; return 0; }

  local _ui_prepare_cert_domain; _ui_prepare_cert_domain="$(state_get .domain)"
  if [ "$(state_get .cert.domain)" = "$_ui_prepare_cert_domain" ] && render_cert_ready; then
    log_ok "已有可用证书：$(state_get .cert.crt)"
    return 0
  fi
  if render_cert_ready; then
    log_info "当前已应用证书域名：$(state_get .cert.domain)（与部署域名 $_ui_prepare_cert_domain 不一致）"
  fi

  if ! cert_tool_installed; then
    log_warn "尚未安装证书申请工具 acme.sh"
    ask_yesno "现在安装 acme.sh 吗？" y || { error "没有证书无法部署需要证书的协议"; return 1; }
    cert_tool_install || return 1
  fi

  local _ui_prepare_cert_mode=""
  if [ "$(state_get .web.enabled)" = "true" ]; then
    log_info "已开启伪装站点，推荐使用 webroot 方式申请证书（不影响 80 端口服务）"
    ask_single _ui_prepare_cert_mode "请选择证书申请方式" \
      "webroot|Webroot（借用伪装站点的 80 端口）" \
      "standalone|Standalone（临时占用 80 端口）" \
      "dns|DNS API（无需 80 端口，适合已占用 80 的情况）"
  else
    ask_single _ui_prepare_cert_mode "请选择证书申请方式" \
      "standalone|Standalone（临时占用 80 端口）" \
      "webroot|Webroot（自己指定网站根目录）" \
      "dns|DNS API（无需 80 端口）"
  fi
  local _ui_prepare_cert_arg="$_ui_prepare_cert_mode"
  if [ "$_ui_prepare_cert_mode" = "dns" ]; then
    local _ui_prepare_cert_prov
    local -a _ui_prepare_cert_prov_items=()
    while IFS="|" read -r _k _v; do
      [ -n "$_k" ] && _ui_prepare_cert_prov_items+=("${_k}|${_v}")
    done <<EOF
$(dns_provider_list)
EOF
    ask_single _ui_prepare_cert_prov "请选择 DNS 服务商" "${_ui_prepare_cert_prov_items[@]}"
    _ui_prepare_cert_arg="dns:$_ui_prepare_cert_prov"
    ui_dns_env_tip "$_ui_prepare_cert_prov"
  fi
  cert_apply "$_ui_prepare_cert_domain" "$_ui_prepare_cert_arg" || return 1
  cert_use "$_ui_prepare_cert_domain" >/dev/null 2>&1 || true
  return 0
}

ui_dns_env_tip() {
  local _ui_dns_env_tip_prov="$1" _ui_dns_env_tip_file="$ESB_SECRET_DIR/dns.env"
  ui_blank
  log_info "DNS API 凭据文件：$_ui_dns_env_tip_file（权限 600，每行 KEY=value）"
  case "$_ui_dns_env_tip_prov" in
    dns_cf) printf '  例如：CF_Token=你的Cloudflare_API_Token\n' ;;
    dns_dp) printf '  例如：DP_Id=你的DNSPod_ID\\nDP_Key=你的DNSPod_Key\n' ;;
    dns_ali) printf '  例如：Ali_Key=你的AccessKeyId\\nAli_Secret=你的AccessKeySecret\n' ;;
    dns_gd) printf '  例如：GD_Key=你的GoDaddy_Key\\nGD_Secret=你的GoDaddy_Secret\n' ;;
    dns_huaweicloud) printf '  例如：HUAWEICLOUD_Username=账号\\nHUAWEICLOUD_Password=密码\\nHUAWEICLOUD_ProjectID=项目ID\n' ;;
  esac
  if [ ! -f "$_ui_dns_env_tip_file" ]; then
    log_warn "凭据文件还不存在，请先创建并填入凭据（方式：菜单【证书管理】外的 shell 里手动创建，或现在输入）"
    if ask_yesno "现在输入凭据（写入 600 文件）？" n; then
      local _ui_dns_env_tip_line=""
      printf '请输入 KEY=value（可多行，直接回车结束）：\n'
      : >"$_ui_dns_env_tip_file"
      chmod 600 "$_ui_dns_env_tip_file" 2>/dev/null || true
      while :; do
        IFS= read -r _ui_dns_env_tip_line || break
        _ui_dns_env_tip_line="${_ui_dns_env_tip_line%$'\r'}"
        [ -n "$_ui_dns_env_tip_line" ] || break
        printf '%s\n' "$_ui_dns_env_tip_line" >>"$_ui_dns_env_tip_file"
      done
      log_ok "凭据已保存到 $_ui_dns_env_tip_file"
    fi
  fi
  return 0
}

ui_deploy_wizard() {
  ui_title "EasySB 一键部署向导"
  detect_all
  printf '  系统：%s　架构：%s　包管理器：%s　服务管理：%s\n' "$ESB_OS_PRETTY" "$ESB_ARCH" "$ESB_PKG" "$ESB_INIT"
  ESB_PUBLIC_IP="${ESB_PUBLIC_IP:-$(detect_public_ip)}"
  [ -n "$ESB_PUBLIC_IP" ] && state_set_str ".server_ip" "$ESB_PUBLIC_IP" >/dev/null 2>&1
  printf '  本机 IP：%s　公网 IP：%s\n' "$(detect_local_ips)" "${ESB_PUBLIC_IP:-未知}"

  if ! deps_check; then
    log_err "依赖不满足，无法继续"
    pause
    return 1
  fi

  ui_step "第一步：域名与邮箱（强制域名部署）"
  ui_prompt_domain || return 1
  ui_prompt_email || return 1

  ui_step "第二步：选择协议"
  ui_prompt_protocols || return 1
  ui_prompt_ports || return 1

  ui_step "第三步：伪装站点"
  local _ui_deploy_wizard_web_sel="" _ui_deploy_wizard_web_tpl=""
  if ask_yesno "是否部署伪装站点（推荐，配合证书申请与域名访问更自然）？" y; then
    web_templates >"${ESB_TMP}/web_templates.tsv" 2>/dev/null || true
    local -a _ui_deploy_wizard_items=()
    while IFS="$(printf '\t')" read -r _ui_deploy_wizard_k _ui_deploy_wizard_l; do
      [ -n "$_ui_deploy_wizard_k" ] || continue
      _ui_deploy_wizard_items+=("${_ui_deploy_wizard_k}|${_ui_deploy_wizard_l}")
    done <"${ESB_TMP}/web_templates.tsv"
    if [ "${#_ui_deploy_wizard_items[@]}" -gt 0 ]; then
      ask_single _ui_deploy_wizard_web_tpl "请选择伪装站点模板" "${_ui_deploy_wizard_items[@]}"
    else
      _ui_deploy_wizard_web_tpl="blog"
    fi
    if [ "$_ui_deploy_wizard_web_tpl" = "proxy" ]; then
      ask_input _ui_deploy_wizard_web_sel "请输入要反代的真实站点（如 https://www.example.org）" "$(state_get .web.proxy_target)"
      state_set_str ".web.proxy_target" "$_ui_deploy_wizard_web_sel"
    fi
    state_set ".web.enabled" "true"
    state_set_str ".web.template" "$_ui_deploy_wizard_web_tpl"
    local _ui_deploy_wizard_webcert="n"
    if ask_yesno "是否为伪装站点启用 HTTPS（443，需要证书且端口未被协议占用）？" y; then
      state_set ".web.tls" "true"
    else
      state_set ".web.tls" "false"
    fi
    _ui_deploy_wizard_webcert=""
  else
    state_set ".web.enabled" "false"
  fi

  ui_step "第四步：安装 sing-box 内核（来自本仓库 releases）"
  ui_install_kernel latest || { log_err "内核安装失败，已中止部署"; pause; return 1; }
  probe_capabilities >/dev/null 2>&1 || log_warn "能力探测未完成（不影响使用）"

  ui_step "第五步：生成节点密钥"
  ui_gen_secrets || { log_err "密钥生成失败"; pause; return 1; }

  ui_step "第六步：证书"
  if [ "$(state_get .web.enabled)" = "true" ]; then
    web_install || log_warn "nginx 安装失败，伪装站点与 webroot 证书申请可能不可用"
    web_deploy "$(state_get .web.template)" || log_warn "伪装站点部署失败，可稍后在菜单中重试"
  fi
  ui_prepare_cert || { log_err "证书准备失败，无法完成需要证书的协议部署"; pause; return 1; }

  ui_step "第七步：生成配置并启动服务"
  local _ui_deploy_wizard_backup
  _ui_deploy_wizard_backup="$(esb_backup "deploy")" || true
  render_config || { log_err "配置生成失败，已中止"; pause; return 1; }
  if ! sb_check_config "$ESB_CONFIG"; then
    log_err "配置校验未通过，已中止部署（原配置未被破坏）"
    pause
    return 1
  fi
  ui_check_ports || log_warn "存在端口冲突或占用，请确认后再启动服务"
  if [ "$(state_get .web.enabled)" = "true" ] && [ "$(state_get .web.tls)" = "true" ]; then
    web_apply_cert || log_warn "伪装站点 HTTPS 未启用（原因见上），站点仍可通过 80 端口访问"
  fi
  fw_apply_all || log_warn "防火墙规则同步失败，请检查防火墙状态"
  state_set_str ".installed_at" "$(esb_now)" >/dev/null 2>&1
  state_set_str ".script_version" "$ESB_SCRIPT_VERSION" >/dev/null 2>&1
  sb_service enable >/dev/null 2>&1 || true
  if ! sb_service restart; then
    log_err "服务启动失败：请查看日志（journalctl -u sing-box -n 50），修复后可在【服务管理】里重启"
    log_info "配置与客户端产物不受影响，继续生成客户端配置与订阅"
  else
    sleep 1
    if sb_running; then
      log_ok "sing-box 已启动"
    else
      log_warn "服务未处于运行状态，请查看日志排查"
    fi
  fi

  ui_step "第八步：生成客户端配置与订阅"
  render_clients || log_warn "客户端配置生成失败"
  cert_reloadcmd_setup >/dev/null 2>&1 || true
  if ask_yesno "是否同时启用订阅（一个链接导入全部节点，自动跟随配置变化）？" y; then
    if sub_enable; then
      ui_blank
      printf '%s订阅地址：%s%s\n' "$C_BOLD" "$(sub_url)" "$C_RESET"
      printf '%s（在客户端里粘贴即可；也可用下面的二维码直接扫）%s\n' "$C_DIM" "$C_RESET"
      ui_show_qr "$(sub_url)" >/dev/null 2>&1 || log_info "（未安装 qrencode，跳过二维码）"
    fi
  fi

  ui_blank
  ui_title "部署完成"
  render_summary
  ui_blank
  log_info "客户端配置目录：$ESB_CLIENT_DIR"
  ui_show_links
  pause
  return 0
}

# ---------------------------------------------------------------------------
# 证书管理
# ---------------------------------------------------------------------------
ui_cert_menu() {
  local _ui_cert_menu_choice=""
  while :; do
    ui_title "证书管理"
    local _ui_cert_menu_applied_domain; _ui_cert_menu_applied_domain="$(state_get .cert.domain)"
    printf '  当前已应用证书：%s\n' "${_ui_cert_menu_applied_domain:-无}"
    if [ -n "$_ui_cert_menu_applied_domain" ]; then
      printf '  剩余有效期　　：%s 天\n' "$(cert_expiring_days "$_ui_cert_menu_applied_domain")"
    fi
    ui_blank
    printf '  1) 申请新证书\n'
    printf '  2) 证书列表\n'
    printf '  3) 应用证书到 sing-box\n'
    printf '  4) 删除证书\n'
    printf '  5) 续期（全部）\n'
    printf '  6) 查看证书详情\n'
    printf '  7) 续期后自动重载服务\n'
    printf '  0) 返回\n'
    printf '请选择 [0-7]: '
    IFS= read -r _ui_cert_menu_choice || _ui_cert_menu_choice="0"
    _ui_cert_menu_choice="${_ui_cert_menu_choice%$'\r'}"
    case "$_ui_cert_menu_choice" in
      1) ui_cert_apply_flow ;;
      2) ui_cert_list_flow ;;
      3) ui_cert_use_flow ;;
      4) ui_cert_delete_flow ;;
      5) ui_cert_renew_flow ;;
      6) ui_cert_detail_flow ;;
      7) cert_reloadcmd_setup && log_ok "已设置续期后自动重载" ;;
      0|'') return 0 ;;
      *) log_warn "无效选项" ;;
    esac
    pause
  done
}

ui_cert_apply_flow() {
  local _ui_cert_apply_flow_domain _ui_cert_apply_flow_mode _ui_cert_apply_flow_arg
  ask_input _ui_cert_apply_flow_domain "请输入证书域名" "$(state_get .domain)"
  validate_domain "$_ui_cert_apply_flow_domain" || return 1
  if ! cert_tool_installed; then
    ask_yesno "尚未安装 acme.sh，现在安装？" y || return 1
    cert_tool_install || return 1
  fi
  if [ "$(state_get .web.enabled)" = "true" ]; then
    ask_single _ui_cert_apply_flow_mode "选择申请方式" \
      "webroot|Webroot（借用伪装站点的 80 端口）" \
      "standalone|Standalone（临时占用 80 端口）" \
      "dns|DNS API（无需 80 端口）"
  else
    ask_single _ui_cert_apply_flow_mode "选择申请方式" \
      "standalone|Standalone（临时占用 80 端口）" \
      "webroot|Webroot（网站根目录）" \
      "dns|DNS API（无需 80 端口）"
  fi
  _ui_cert_apply_flow_arg="$_ui_cert_apply_flow_mode"
  if [ "$_ui_cert_apply_flow_mode" = "dns" ]; then
    local _ui_cert_apply_flow_prov
    local -a _ui_cert_apply_flow_prov_items=()
    while IFS="|" read -r _k _v; do
      [ -n "$_k" ] && _ui_cert_apply_flow_prov_items+=("${_k}|${_v}")
    done <<EOF
$(dns_provider_list)
EOF
    ask_single _ui_cert_apply_flow_prov "选择 DNS 服务商" "${_ui_cert_apply_flow_prov_items[@]}"
    _ui_cert_apply_flow_arg="dns:$_ui_cert_apply_flow_prov"
    ui_dns_env_tip "$_ui_cert_apply_flow_prov"
  fi
  cert_apply "$_ui_cert_apply_flow_domain" "$_ui_cert_apply_flow_arg" || return 1
  log_ok "证书申请成功"
  if ask_yesno "是否立即应用到 sing-box？" y; then
    cert_use "$_ui_cert_apply_flow_domain" || log_warn "应用失败，请检查配置校验输出"
  fi
  return 0
}

ui_cert_list_flow() {
  local _ui_cert_list_flow_line
  ui_blank
  printf '  %-28s %-12s %-8s %s\n' "域名" "来源" "剩余天数" "是否已应用"
  ui_hr
  cert_list >"${ESB_TMP}/certs.tsv" 2>/dev/null || true
  if [ ! -s "${ESB_TMP}/certs.tsv" ]; then
    log_info "暂无证书，请先申请"
    return 0
  fi
  while IFS="$(printf '\t')" read -r _ui_cert_list_flow_line _ _ _ui_cert_list_flow_days _ui_cert_list_flow_src _ui_cert_list_flow_applied; do
    [ -n "$_ui_cert_list_flow_line" ] || continue
    printf '  %-28s %-12s %-8s %s\n' "$_ui_cert_list_flow_line" "$_ui_cert_list_flow_src" "$_ui_cert_list_flow_days" \
      "$([ "$_ui_cert_list_flow_applied" = "1" ] && echo '是' || echo '否')"
  done <"${ESB_TMP}/certs.tsv"
  return 0
}

ui_cert_use_flow() {
  local _ui_cert_use_flow_domain="" _ui_cert_use_flow_line
  local -a _ui_cert_use_flow_items=()
  cert_list >"${ESB_TMP}/certs.tsv" 2>/dev/null || true
  if [ ! -s "${ESB_TMP}/certs.tsv" ]; then log_info "暂无证书"; return 0; fi
  while IFS="$(printf '\t')" read -r _ui_cert_use_flow_line _ _ _ui_cert_use_flow_domain _ _; do
    [ -n "$_ui_cert_use_flow_line" ] || continue
    _ui_cert_use_flow_items+=("${_ui_cert_use_flow_line}|${_ui_cert_use_flow_line}（剩余 ${_ui_cert_use_flow_domain:-?} 天）")
  done <"${ESB_TMP}/certs.tsv"
  local _ui_cert_use_flow_pick
  ask_single _ui_cert_use_flow_pick "请选择要应用的证书" "${_ui_cert_use_flow_items[@]}"
  cert_use "$_ui_cert_use_flow_pick" || return 1
  log_ok "已应用证书：$_ui_cert_use_flow_pick"
  return 0
}

ui_cert_delete_flow() {
  local _ui_cert_delete_flow_domain="" _ui_cert_delete_flow_line _ui_cert_delete_flow_pick
  local -a _ui_cert_delete_flow_items=()
  cert_list >"${ESB_TMP}/certs.tsv" 2>/dev/null || true
  if [ ! -s "${ESB_TMP}/certs.tsv" ]; then log_info "暂无证书"; return 0; fi
  while IFS="$(printf '\t')" read -r _ui_cert_delete_flow_line _ _ _ui_cert_delete_flow_domain _ _; do
    [ -n "$_ui_cert_delete_flow_line" ] || continue
    _ui_cert_delete_flow_items+=("${_ui_cert_delete_flow_line}|${_ui_cert_delete_flow_line}（剩余 ${_ui_cert_delete_flow_domain:-?} 天）")
  done <"${ESB_TMP}/certs.tsv"
  ask_single _ui_cert_delete_flow_pick "请选择要删除的证书" "${_ui_cert_delete_flow_items[@]}"
  ui_blank
  if [ "$_ui_cert_delete_flow_pick" = "$(state_get .cert.domain)" ]; then
    log_warn "该证书正在被 sing-box 使用，删除后需要重新申请并应用，否则服务会启动失败"
    ask_yesno "确认强制删除？" n || return 0
    cert_delete "$_ui_cert_delete_flow_pick" --force || return 1
  else
    ask_yesno "确认删除证书 $_ui_cert_delete_flow_pick？" n || return 0
    cert_delete "$_ui_cert_delete_flow_pick" || return 1
  fi
  log_ok "已删除"
  return 0
}

ui_cert_renew_flow() {
  ui_blank
  log_info "开始续期全部证书…"
  cert_renew_all || log_warn "部分证书续期失败，请查看输出"
  return 0
}

ui_cert_detail_flow() {
  local _ui_cert_detail_flow_domain="" _ui_cert_detail_flow_line _ui_cert_detail_flow_pick
  local -a _ui_cert_detail_flow_items=()
  cert_list >"${ESB_TMP}/certs.tsv" 2>/dev/null || true
  if [ ! -s "${ESB_TMP}/certs.tsv" ]; then log_info "暂无证书"; return 0; fi
  while IFS="$(printf '\t')" read -r _ui_cert_detail_flow_line _ _ _ui_cert_detail_flow_domain _ _; do
    [ -n "$_ui_cert_detail_flow_line" ] || continue
    _ui_cert_detail_flow_items+=("${_ui_cert_detail_flow_line}|${_ui_cert_detail_flow_line}")
  done <"${ESB_TMP}/certs.tsv"
  ask_single _ui_cert_detail_flow_pick "请选择证书" "${_ui_cert_detail_flow_items[@]}"
  ui_blank
  cert_detail "$_ui_cert_detail_flow_pick" || log_warn "无法读取证书详情"
  return 0
}

# ---------------------------------------------------------------------------
# 伪装站点
# ---------------------------------------------------------------------------
ui_web_menu() {
  local _ui_web_menu_choice=""
  while :; do
    ui_title "伪装站点"
    web_status 2>/dev/null || log_info "未部署伪装站点"
    ui_blank
    printf '  1) 部署 / 更换模板\n'
    printf '  2) 仅更新证书配置（HTTPS）\n'
    printf '  3) 关闭伪装站点\n'
    printf '  0) 返回\n'
    printf '请选择 [0-3]: '
    IFS= read -r _ui_web_menu_choice || _ui_web_menu_choice="0"
    _ui_web_menu_choice="${_ui_web_menu_choice%$'\r'}"
    case "$_ui_web_menu_choice" in
      1)
        if ! web_installed; then
          ask_yesno "未安装 nginx，现在安装？" y || return 0
          web_install || return 1
        fi
        local _ui_web_menu_line _ui_web_menu_label _ui_web_menu_tpl
        local -a _ui_web_menu_items=()
        web_templates >"${ESB_TMP}/web_templates.tsv" 2>/dev/null || true
        while IFS="$(printf '\t')" read -r _ui_web_menu_line _ui_web_menu_label; do
          [ -n "$_ui_web_menu_line" ] || continue
          _ui_web_menu_items+=("${_ui_web_menu_line}|${_ui_web_menu_label}")
        done <"${ESB_TMP}/web_templates.tsv"
        ask_single _ui_web_menu_tpl "请选择模板" "${_ui_web_menu_items[@]}"
        if [ "$_ui_web_menu_tpl" = "proxy" ]; then
          local _ui_web_menu_target
          ask_input _ui_web_menu_target "请输入反代目标（如 https://www.example.org）" "$(state_get .web.proxy_target)"
          state_set_str ".web.proxy_target" "$_ui_web_menu_target"
        fi
        state_set ".web.enabled" "true"
        state_set_str ".web.template" "$_ui_web_menu_tpl"
        web_deploy "$_ui_web_menu_tpl" || return 1
        if [ "$(state_get .web.tls)" = "true" ]; then web_apply_cert || true; fi
        ;;
      2)
        state_set ".web.tls" "true"
        web_apply_cert || log_warn "启用 HTTPS 失败"
        ;;
      3)
        ask_yesno "确认关闭伪装站点（保留站点根目录文件）？" n || { pause; continue; }
        web_disable || true
        state_set ".web.enabled" "false"
        fw_apply_all >/dev/null 2>&1 || true
        ;;
      0|'') return 0 ;;
      *) log_warn "无效选项" ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# 客户端配置与分享链接
# ---------------------------------------------------------------------------
ui_show_links() {
  local _ui_show_links_link
  if [ -z "$(proto_enabled_list)" ]; then
    log_warn "尚未启用任何协议"
    return 1
  fi
  ui_blank
  printf '%s分享链接（可直接导入客户端）%s\n' "$C_BOLD" "$C_RESET"
  ui_hr
  render_links | while IFS= read -r _ui_show_links_link; do
    [ -n "$_ui_show_links_link" ] || continue
    printf '%s\n\n' "$_ui_show_links_link"
  done
  return 0
}

ui_show_qr() {
  local _ui_show_qr_link="$1"
  if ! cmd_exists qrencode; then
    log_warn "未安装 qrencode（用于生成终端二维码）"
    if ask_yesno "现在安装 qrencode？" y; then
      deps_install qrencode || { log_warn "安装失败"; return 1; }
    else
      return 1
    fi
  fi
  qrencode -t ANSIUTF8 "$_ui_show_qr_link" || return 1
  return 0
}

ui_clients_menu() {
  local _ui_clients_menu_choice=""
  while :; do
    ui_title "客户端配置与分享链接"
    ui_blank
    sub_status 2>/dev/null || true
    ui_blank
    printf '  1) 查看全部节点链接\n'
    printf '  2) 节点二维码\n'
    printf '  3) 订阅链接（生成 / 查看 / 二维码）\n'
    printf '  4) 重新生成客户端配置与订阅文件\n'
    printf '  5) 查看客户端配置文件路径\n'
    printf '  6) 关闭订阅\n'
    printf '  0) 返回\n'
    printf '请选择 [0-6]: '
    IFS= read -r _ui_clients_menu_choice || _ui_clients_menu_choice="0"
    _ui_clients_menu_choice="${_ui_clients_menu_choice%$'\r'}"
    case "$_ui_clients_menu_choice" in
      1) ui_show_links ;;
      2)
        local _ui_clients_menu_p _ui_clients_menu_line
        local -a _ui_clients_menu_items=()
        for _ui_clients_menu_p in $(proto_enabled_list); do
          _ui_clients_menu_items+=("${_ui_clients_menu_p}|$(proto_label "$_ui_clients_menu_p" | tr -d '\n')")
        done
        ask_single _ui_clients_menu_line "请选择协议" "${_ui_clients_menu_items[@]}"
        ui_show_qr "$(client_link_for "$_ui_clients_menu_line")"
        ;;
      3) ui_sub_menu ;;
      4)
        render_clients || log_warn "客户端配置生成失败"
        sub_refresh
        log_ok "已重新生成客户端配置与订阅文件"
        ;;
      5)
        printf '  目录：%s\n' "$ESB_CLIENT_DIR"
        ls -1 "$ESB_CLIENT_DIR" 2>/dev/null | sed 's/^/      /'
        ;;
      6) sub_disable ;;
      0|'') return 0 ;;
      *) log_warn "无效选项" ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# 订阅
# ---------------------------------------------------------------------------
ui_sub_menu() {
  local _ui_sub_menu_choice="" _ui_sub_menu_url
  while :; do
    ui_title "订阅链接"
    sub_status
    ui_blank
    printf '  1) 生成 / 刷新订阅文件\n'
    printf '  2) 显示订阅地址与二维码\n'
    printf '  3) 显示全部格式的订阅地址\n'
    printf '  4) 重新生成订阅 token（旧地址立即失效）\n'
    printf '  5) 启用独立订阅站点（不用伪装站点时）\n'
    printf '  0) 返回\n'
    printf '请选择 [0-5]: '
    IFS= read -r _ui_sub_menu_choice || _ui_sub_menu_choice="0"
    _ui_sub_menu_choice="${_ui_sub_menu_choice%$'\r'}"
    case "$_ui_sub_menu_choice" in
      1) sub_enable ;;
      2)
        state_set ".sub.enabled" "true" >/dev/null 2>&1 || true
        _ui_sub_menu_url="$(sub_url)"
        ui_blank
        printf '%s%s%s\n' "$C_BOLD" "$_ui_sub_menu_url" "$C_RESET"
        ui_blank
        ui_show_qr "$_ui_sub_menu_url"
        ;;
      3) sub_url_list | while IFS="$(printf '\t')" read -r _ui_sub_menu_k _ui_sub_menu_v; do
           printf '  %-9s %s\n' "$_ui_sub_menu_k" "$_ui_sub_menu_v"
         done ;;
      4)
        ask_yesno "重新生成后旧订阅地址会立刻失效，确认继续？" n || { pause; continue; }
        sub_token_regen >/dev/null && sub_enable
        ;;
      5)
        if [ "$(state_get .web.enabled)" = "true" ]; then
          log_info "当前已开启伪装站点，订阅会自动复用它（无需独立站点）"
          ask_yesno "仍然改为使用独立订阅站点？" n || { pause; continue; }
          state_set ".sub.serve_via_site" "false" >/dev/null 2>&1 || true
        fi
        if ! web_installed; then
          ask_yesno "未安装 nginx，现在安装？" y || { pause; continue; }
          web_install || { pause; continue; }
        fi
        sub_site_deploy || log_warn "订阅站点部署失败"
        sub_write_files >/dev/null 2>&1 || true
        state_set ".sub.enabled" "true" >/dev/null 2>&1 || true
        fw_open "$(state_get .sub.port)" tcp >/dev/null 2>&1 || true
        log_ok "订阅站点已启用：$(sub_url)"
        ;;
      0|'') return 0 ;;
      *) log_warn "无效选项" ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# 更新
# ---------------------------------------------------------------------------
ui_update_menu() {
  local _ui_update_menu_choice=""
  while :; do
    ui_title "更新"
    printf '  sing-box 内核：当前 %s　仓库最新 %s\n' \
      "$(sb_version | sed 's/^$/未安装/')" "$(sb_latest_version | sed 's/^$/未知/')"
    printf '  EasySB 脚本　：当前 %s　仓库最新 %s\n' \
      "$ESB_SCRIPT_VERSION" "$(script_latest_version | sed 's/^$/未知/')"
    ui_blank
    printf '  1) 更新 sing-box 内核\n'
    printf '  2) 更新 EasySB 脚本\n'
    printf '  3) 安装 / 切换指定内核版本\n'
    printf '  0) 返回\n'
    printf '请选择 [0-3]: '
    IFS= read -r _ui_update_menu_choice || _ui_update_menu_choice="0"
    _ui_update_menu_choice="${_ui_update_menu_choice%$'\r'}"
    case "$_ui_update_menu_choice" in
      1) sb_update ;;
      2) script_update ;;
      3)
        local _ui_update_menu_ver
        ask_input _ui_update_menu_ver "请输入要安装的版本号（如 1.14.1）" ""
        if [ -n "$_ui_update_menu_ver" ]; then sb_install "$_ui_update_menu_ver"; fi
        ;;
      0|'') return 0 ;;
      *) log_warn "无效选项" ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
ui_uninstall() {
  ui_title "卸载 EasySB"
  log_warn "将停止服务、删除 systemd unit、回收防火墙规则、关闭伪装站点，并删除 sing-box 内核"
  log_info "保留内容：$ESB_DIR（状态与客户端配置）、$ESB_BACKUP_DIR（备份）、$ESB_WEB_ROOT（站点文件）"
  if ! esb_confirm_or_die "确认卸载 EasySB？"; then return 1; fi
  sb_service stop >/dev/null 2>&1 || true
  sb_service disable >/dev/null 2>&1 || true
  if [ "$(state_get .web.enabled)" = "true" ]; then
    web_disable >/dev/null 2>&1 || true
    state_set ".web.enabled" "false" >/dev/null 2>&1 || true
  fi
  fw_revert_all >/dev/null 2>&1 || log_warn "防火墙规则回收失败，请手动检查"
  unit_remove
  rm -f "$ESB_CONFIG" 2>/dev/null || true
  sb_uninstall
  log_ok "卸载完成（备份与状态保留在 $ESB_DIR）"
  if ask_yesno "是否同时删除状态目录 $ESB_DIR（含客户端配置，不可恢复）？" n; then
    rm -rf "$ESB_DIR" 2>/dev/null || log_warn "删除失败，请手动处理"
    log_ok "已删除 $ESB_DIR"
  fi
  pause
  return 0
}


# 路径模型兜底（模块被单独 source 时也能工作；幂等，不覆盖入口已定义的值）
esb_paths_init

# ---------------------------------------------------------------------------
# 初始化
# ---------------------------------------------------------------------------
esb_init() {
  local _esb_init_arg
  for _esb_init_arg in "$@"; do
    case "$_esb_init_arg" in
      --no-color) ESB_NO_COLOR=1 ;;
    esac
  done
  esb_color_init
  esb_tmp_init || die "无法创建临时目录"
  state_init || die "无法初始化状态目录 $ESB_DIR"
  esb_log_open
  esb_log_raw "==== EasySB v${ESB_SCRIPT_VERSION} 启动（参数：$*）===="
  return 0
}

esb_cleanup() {
  esb_tmp_clean
  esb_unlock
  return 0
}

esb_require_root() {
  if [ "$(id -u 2>/dev/null || echo 0)" != "0" ] && [ "${ESB_ROOT}" = "" ]; then
    die "请以 root 身份运行（sudo -i 后再执行）"
  fi
  return 0
}

esb_stdin_from_tty() {
  # curl | bash 场景下 stdin 是管道，交互会失效；有 /dev/tty 就切回去
  if [ ! -t 0 ] && [ -c /dev/tty ]; then
    exec </dev/tty 2>/dev/null || true
  fi
  return 0
}

esb_main() {
  local _esb_main_cmd=""
  case "${1:-}" in
    --version|-V|version)
      printf 'EasySB v%s\n' "$ESB_SCRIPT_VERSION"
      return 0
      ;;
    --help|-h|help)
      usage
      return 0
      ;;
    --dry-run)
      ESB_GATE=1
      export ESB_GATE
      ESB_GATE_LOG="${ESB_GATE_LOG:-${TMPDIR:-/tmp}/easysb-dryrun.log}"
      export ESB_GATE_LOG
      shift
      _esb_main_cmd="${1:-}"
      ;;
    *) _esb_main_cmd="${1:-}" ;;
  esac

  esb_stdin_from_tty
  esb_init "$@"
  esb_log_raw "系统：$(uname -a 2>/dev/null)"
  trap 'esb_cleanup' EXIT

  case "$_esb_main_cmd" in
    install|deploy)
      esb_require_root
      deps_check || exit 1
      esb_lock || exit 1
      detect_all
      ui_deploy_wizard
      return $?
      ;;
    status)
      esb_lock || true
      detect_all
      ui_status_menu
      return 0
      ;;
    uninstall|remove)
      esb_require_root
      esb_lock || exit 1
      detect_all
      ui_uninstall
      return 0
      ;;
    update)
      esb_require_root
      esb_lock || exit 1
      detect_all
      ui_update_menu
      return 0
      ;;
    '')
      esb_require_root
      deps_check || exit 1
      esb_lock || exit 1
      detect_all
      if [ "${ESB_GATE:-0}" = "1" ]; then
        log_warn "预演模式（--dry-run）：所有系统变更只会被记录，不会真正执行"
      fi
      ui_main
      return 0
      ;;
    *)
      log_err "未知参数：$1"
      usage
      return 2
      ;;
  esac
}

# 供测试脚本以 `ESB_NO_MAIN=1 . easysb.sh` 的方式复用"路径模型 + 模块加载"
if [ "${ESB_NO_MAIN:-0}" != "1" ]; then
  esb_main "$@"
fi
