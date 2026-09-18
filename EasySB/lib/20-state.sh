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
    "vmess-ws-tls":         {"enabled": false, "port": 8443, "tag": "vmess-ws-tls", "path": "/vmess", "early_data": true,
                             "tls": true, "cert_mode": "auto"},
    "anytls":               {"enabled": false, "port": 2096, "tag": "anytls", "padding": true,
                             "cert_mode": "auto"},
    "hysteria2":            {"enabled": false, "port": 443,  "tag": "hysteria2",
                             "up_mbps": 100, "down_mbps": 100, "cert_mode": "auto",
                             "hop": {"enabled": false, "range": "20000-30000", "interval": "30s"}},
    "tuic":                 {"enabled": false, "port": 8443, "tag": "tuic",
                             "congestion_control": "bbr", "zero_rtt": false, "cert_mode": "auto"}
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

# 该协议是否启用 TLS（只有 VMess-WS-TLS 可以关 TLS，其余 TLS 协议恒为开）
proto_tls_enabled() {
  local _pte_p="$1" _pte_v
  case "$_pte_p" in
    vmess-ws-tls) _pte_v="$(state_get '.protocols["vmess-ws-tls"].tls')" ;;
    vless-vision-reality) printf 'false'; return 0 ;;
    *) printf 'true'; return 0 ;;
  esac
  if [ "$_pte_v" = "false" ]; then printf 'false'; else printf 'true'; fi
  return 0
}

# 该协议请求的证书模式：auto=跟随当前已应用证书的来源
proto_cert_mode_req() { state_get ".protocols[\"$1\"].cert_mode"; }

# 写入某协议的证书模式（字符串字段，走 --arg 避免手动加引号）
proto_cert_mode_set() {
  local _pcms_p="$1" _pcms_v="$2"
  case "$_pcms_v" in
    acme|self-signed|auto) ;;
    *) error "证书模式只能是 acme / self-signed / auto，收到：$_pcms_v"; return 1 ;;
  esac
  _state_mutate '.protocols[$k].cert_mode = $v' --arg k "$_pcms_p" --arg v "$_pcms_v"
}

# 写入某协议是否启用 TLS（布尔字段）
proto_tls_set() {
  local _pts_p="$1" _pts_v="$2"
  case "$_pts_v" in
    true|false) ;;
    *) error "TLS 开关只能是 true / false，收到：$_pts_v"; return 1 ;;
  esac
  _state_mutate '.protocols[$k].tls = $v' --arg k "$_pts_p" --argjson v "$_pts_v"
}

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
  # 冲突检测：unit 或配置不是 EasySB 写的（例如机器上还装着别的一键脚本）就先停手，
  # 不要覆盖别人的部署、更不要去重启别人的服务
  if command -v foreign_singbox_detected >/dev/null 2>&1 && foreign_singbox_detected; then
    if ! command -v unit_takeover_allowed >/dev/null 2>&1 || ! unit_takeover_allowed; then
      error "检测到非 EasySB 管理的 sing-box 部署，已中止变更（未改动任何文件）"
      return 1
    fi
  fi
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
