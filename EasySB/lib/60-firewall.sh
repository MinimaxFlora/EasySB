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
