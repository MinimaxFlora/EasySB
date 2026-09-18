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

# acme.sh 产出的证书文件（优先 ECC 目录）→ 安装到目标路径
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
    error "申请证书失败：$_cert_apply_domain（方式：$_cert_apply_mode）"
    log_info "常见原因：域名未解析到本机 / 80 端口被占用 / DNS 凭据错误或未生效 / 申请频率超限"
    return 1
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
  if ! _cert_acme_exec "-" "-" "续期证书 $_cert_renew_domain" "$_cert_renew_acme" \
        --home "$_cert_renew_home" --renew -d "$_cert_renew_domain" --force; then
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
