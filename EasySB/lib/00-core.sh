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
  return 0
}

esb_log_raw "==== EasySB 启动 ===="
