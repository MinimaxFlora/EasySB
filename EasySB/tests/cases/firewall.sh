#!/usr/bin/env bash
# =============================================================================
# tests/cases/firewall.sh — 60-firewall.sh 的用例
# 契约见 docs/TESTING.md：本文件被 runner source，TESTS 里的 test_* 返回 0=通过。
#
# 约定（由 docs/TESTING.md 给定）：ESB_GATE=1 时所有系统变更命令不执行、
# 只追加到 $ESB_GATE_LOG；断言助手来自 tests/lib/harness.sh，实际签名为：
#   assert_eq   <actual> <expected> [msg]
#   assert_contains / assert_not_contains <haystack> <needle> [msg]
#   assert_file <path> [msg]
#   assert_json <file> <jq-filter> <expected> [msg]   # jq -cr 取值
#   assert_ok   <msg> <cmd...>      # 期望返回 0
#   assert_fail <msg> <cmd...>      # 期望返回非 0
# test_20_helper_contract 锁定这组签名；其余用例都是对“返回值 / state 值 /
# gate 日志文本”的值断言，改助手的实现不会让它们假绿。
#
# 三个外部命令（ufw / firewall-cmd / nft / iptables）由本用例自带的 stub 提供
# （写在 $ESB_TEST_WORK 下并放到 PATH 最前面），因为探测顺序、端口范围写法、
# “只删自己标签的规则”这些断言都必须精确控制这些命令的输出。
# =============================================================================
# shellcheck shell=bash

TESTS="test_1_detect_ufw test_2_detect_firewalld test_3_detect_nftables \
test_4_detect_iptables test_5_detect_none test_6_backend_override \
test_7_open_records_once test_8_open_sort_unique test_9_close_only_recorded \
test_10_apply_all_diff test_11_apply_all_idempotent test_12_hop_nft_range \
test_13_hop_iptables_range test_14_hop_clear_iptables test_15_revert_inert \
test_16_revert_full_nft test_17_status_no_tools test_18_status_readonly \
test_19_validators_no_exit test_20_helper_contract"

# ---------------------------------------------------------------------------
# 用例基础设施
# ---------------------------------------------------------------------------
_FW_T_PATH0="$PATH"          # runner 给的原始 PATH（含 tests/bin 与 tools/bin）
_FW_T_STUB_DIR=""            # 本用例的 stub 目录（PATH 形式）
_FW_T_GATE_N=0               # gate 日志的行数水位

# 把任意写法（D:/x 或 /d/x）转成 PATH 里能被 MSYS bash 搜索到的形式
_fw_t_path_entry() {
  local _fw_tpe_p="$1"
  if cmd_exists cygpath; then
    _fw_tpe_p="$(cygpath -u "$_fw_tpe_p" 2>/dev/null | tr -d '\r\n')"
  fi
  case "$_fw_tpe_p" in
    [A-Za-z]:/*) _fw_tpe_p="/$(printf '%s' "${_fw_tpe_p:0:1}" | tr 'A-Z' 'a-z')${_fw_tpe_p:2}" ;;
  esac
  printf '%s\n' "$_fw_tpe_p"
}

_fw_t_work() { printf '%s\n' "${ESB_TEST_WORK:-${TMPDIR:-/tmp}}"; }

# 状态重置 + gate 水位复位：每个用例都从干净状态开始
_fw_t_state_fresh() {
  rm -f "$ESB_STATE" 2>/dev/null || true
  state_init >/dev/null 2>&1 || return 1
  _fw_t_gate_mark
  return 0
}

_fw_t_gate_mark() {
  _FW_T_GATE_N="$(wc -l <"${ESB_GATE_LOG:-/dev/null}" 2>/dev/null | tr -d '[:space:]' || true)"
  case "$_FW_T_GATE_N" in
    ''|*[!0-9]*) _FW_T_GATE_N=0 ;;
  esac
  return 0
}

# 本次水位之后新增的 gate 记录（即“本步骤真实下发的系统变更”）
_fw_t_gate_new() {
  tail -n "+$((_FW_T_GATE_N + 1))" "${ESB_GATE_LOG:-/dev/null}" 2>/dev/null | tr -d '\r' || true
}

# 从 PATH 里剔除所有含 ufw/firewall-cmd/nft/iptables 可执行文件的目录（模拟“本机没有防火墙工具”）。
# 注意：不能只用 command -v —— 它只能看到第一个同名命令，PATH 里同时存在
# tests/bin 与本用例自带的 stub 目录时会漏掉一个目录，于是"没有防火墙"就模拟不出来。
_fw_t_no_fw_path() {
  local _fw_tnf_out=""
  local _fw_tnf_d=""
  local _fw_tnf_c=""
  local _fw_tnf_hit=0
  while IFS= read -r _fw_tnf_d; do
    [ -n "$_fw_tnf_d" ] || continue
    _fw_tnf_hit=0
    for _fw_tnf_c in ufw firewall-cmd nft iptables; do
      if [ -x "${_fw_tnf_d}/${_fw_tnf_c}" ] || [ -x "${_fw_tnf_d}/${_fw_tnf_c}.exe" ]; then
        _fw_tnf_hit=1
        break
      fi
    done
    [ "$_fw_tnf_hit" = "1" ] && continue
    _fw_tnf_out="${_fw_tnf_out}${_fw_tnf_d}:"
  done <<EOF
$(printf '%s' "$PATH" | tr ':' '\n')
EOF
  printf '%s' "${_fw_tnf_out%:}"
  return 0
}

# --- stub 脚本（行为由 FWSTUB_* 环境变量控制，默认值贴近真实系统） -----------
_fw_t_stub_write_ufw() {
  cat >"$_FW_T_STUB_DIR/ufw" <<'STUB'
#!/usr/bin/env bash
[ -n "${FWSTUB_LOG:-}" ] && printf 'ufw %s\n' "$*" >>"$FWSTUB_LOG"
case "$1" in
  status)
    if [ "${2:-}" = "numbered" ]; then
      [ -n "${FWSTUB_UFW_NUMBERED:-}" ] && printf '%s\n' "$FWSTUB_UFW_NUMBERED"
    elif [ "${FWSTUB_UFW_STATE:-active}" = "active" ]; then
      printf 'Status: active\n'
    else
      printf 'Status: inactive\n'
    fi
    ;;
esac
exit 0
STUB
  chmod +x "$_FW_T_STUB_DIR/ufw" 2>/dev/null || true
}

_fw_t_stub_write_firewalld() {
  cat >"$_FW_T_STUB_DIR/firewall-cmd" <<'STUB'
#!/usr/bin/env bash
[ -n "${FWSTUB_LOG:-}" ] && printf 'firewall-cmd %s\n' "$*" >>"$FWSTUB_LOG"
case "$*" in
  *--state*)
    if [ "${FWSTUB_FIREWALLD_STATE:-not running}" = "running" ]; then
      printf 'running\n'
      exit 0
    fi
    printf 'not running\n'
    exit 1
    ;;
  *--get-default-zone*)
    printf 'public\n'
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$_FW_T_STUB_DIR/firewall-cmd" 2>/dev/null || true
}

_fw_t_stub_write_nft() {
  cat >"$_FW_T_STUB_DIR/nft" <<'STUB'
#!/usr/bin/env bash
[ -n "${FWSTUB_LOG:-}" ] && printf 'nft %s\n' "$*" >>"$FWSTUB_LOG"
case "$*" in
  "list ruleset")
    [ "${FWSTUB_NFT_STATE:-ok}" = "ok" ] && exit 0
    exit 1
    ;;
  *"list chain"*)
    if [ "${FWSTUB_NFT_CHAIN:-absent}" = "present" ]; then
      case "${6:-}" in
        prerouting)
          printf 'table inet easysb {\n\tchain prerouting {\n\t\tudp dport 20000-30000 redirect to :443 # handle 9\n\t}\n}\n'
          ;;
        *)
          printf 'table inet easysb {\n\tchain input {\n\t\ttcp dport 443 accept comment "EasySB" # handle 7\n\t}\n}\n'
          ;;
      esac
      exit 0
    fi
    exit 1
    ;;
esac
exit 0
STUB
  chmod +x "$_FW_T_STUB_DIR/nft" 2>/dev/null || true
}

_fw_t_stub_write_iptables() {
  cat >"$_FW_T_STUB_DIR/iptables" <<'STUB'
#!/usr/bin/env bash
[ -n "${FWSTUB_LOG:-}" ] && printf 'iptables %s\n' "$*" >>"$FWSTUB_LOG"
case "$*" in
  *" -n -L "*)
    [ "${FWSTUB_IPT_CHAIN:-absent}" = "present" ] && exit 0
    exit 1
    ;;
  *" -C "*)
    [ "${FWSTUB_IPT_JUMP:-absent}" = "present" ] && exit 0
    exit 1
    ;;
esac
exit 0
STUB
  chmod +x "$_FW_T_STUB_DIR/iptables" 2>/dev/null || true
}

# 建立本用例的 stub 目录并放到 PATH 最前（覆盖 tests/bin 里的同名 stub）
_fw_t_stub_init() {
  local _fw_tsi_dir=""
  PATH="$_FW_T_PATH0"
  export PATH
  _fw_tsi_dir="$(_fw_t_work)/fwstubs.$$.$RANDOM"
  rm -rf "$_fw_tsi_dir" 2>/dev/null || true
  mkdir -p "$_fw_tsi_dir" || return 1
  _FW_T_STUB_DIR="$(_fw_t_path_entry "$_fw_tsi_dir")"
  export PATH="${_FW_T_STUB_DIR}:${PATH}"
  export FWSTUB_LOG="$(_fw_t_work)/fwstub.$$.$RANDOM.log"
  : >"$FWSTUB_LOG" 2>/dev/null || true
  _fw_t_stub_write_ufw
  _fw_t_stub_write_firewalld
  _fw_t_stub_write_nft
  _fw_t_stub_write_iptables
  return 0
}

# 按模式布置 4 个 stub：ufw|firewalld|nftables|iptables|none
_fw_t_stub_env() {
  local _fw_tse_mode="$1"
  _fw_t_stub_init || return 1
  case "$_fw_tse_mode" in
    ufw)
      export FWSTUB_UFW_STATE="active"
      export FWSTUB_FIREWALLD_STATE="not running"
      export FWSTUB_NFT_STATE="fail"
      ;;
    firewalld)
      export FWSTUB_UFW_STATE="inactive"
      export FWSTUB_FIREWALLD_STATE="running"
      export FWSTUB_NFT_STATE="fail"
      ;;
    nftables)
      export FWSTUB_UFW_STATE="inactive"
      export FWSTUB_FIREWALLD_STATE="not running"
      export FWSTUB_NFT_STATE="ok"
      ;;
    iptables|none)
      export FWSTUB_UFW_STATE="inactive"
      export FWSTUB_FIREWALLD_STATE="not running"
      export FWSTUB_NFT_STATE="fail"
      ;;
    *)
      printf '[用例环境] 未知 stub 模式：%s\n' "$_fw_tse_mode" >&2
      return 1
      ;;
  esac
  export FWSTUB_NFT_CHAIN="absent"
  export FWSTUB_IPT_CHAIN="absent"
  unset FWSTUB_UFW_NUMBERED
  # 自检：确认 stub 真的生效（否则后面所有断言都会因 PATH 不对而假失败）
  case "$(ufw status 2>/dev/null | tr -d '\r' || true)" in
    *"Status: ${FWSTUB_UFW_STATE:-active}"*) return 0 ;;
  esac
  printf '[用例环境] 自带 stub 未生效：stub 目录=%s\nPATH=%s\n' "$_FW_T_STUB_DIR" "$PATH" >&2
  return 1
}

_fw_t_bad_backend() { ESB_FW_BACKEND=bogus fw_backend >/dev/null 2>&1; }
_fw_t_noop_true()   { return 0; }
_fw_t_noop_false()  { return 1; }

# ---------------------------------------------------------------------------
# 1~6 后端探测
# ---------------------------------------------------------------------------
test_1_detect_ufw() {
  _fw_t_state_fresh || return 1
  _fw_t_stub_env ufw || return 1
  assert_eq "$(fw_backend)" "ufw" "ufw 处于 active 时应选 ufw（顺序优先，即使 firewalld 也在跑）" || return 1
  assert_json "$ESB_STATE" '.firewall.backend' "ufw" || return 1
  assert_file "$ESB_STATE" || return 1
}

test_2_detect_firewalld() {
  _fw_t_state_fresh || return 1
  _fw_t_stub_env firewalld || return 1
  assert_eq "$(fw_backend)" "firewalld" "ufw 未启用且 firewalld 运行时选 firewalld" || return 1
  assert_json "$ESB_STATE" '.firewall.backend' "firewalld" || return 1
}

test_3_detect_nftables() {
  _fw_t_state_fresh || return 1
  _fw_t_stub_env nftables || return 1
  assert_eq "$(fw_backend)" "nftables" "ufw/firewalld 都不可用且 nft 能读规则集时选 nftables" || return 1
  assert_json "$ESB_STATE" '.firewall.backend' "nftables" || return 1
}

test_4_detect_iptables() {
  _fw_t_state_fresh || return 1
  _fw_t_stub_env iptables || return 1
  assert_eq "$(fw_backend)" "iptables" "nft 读不到规则集但 iptables 存在时选 iptables" || return 1
}

test_5_detect_none() {
  local _fw_t5_path=""
  _fw_t_state_fresh || return 1
  _fw_t_stub_env none || return 1
  _fw_t5_path="$(_fw_t_no_fw_path)"
  assert_eq "$( export PATH="$_fw_t5_path"; fw_backend )" "none" "本机没有任何防火墙工具时输出 none" || return 1
}

test_6_backend_override() {
  _fw_t_state_fresh || return 1
  _fw_t_stub_env ufw || return 1
  assert_eq "$( ESB_FW_BACKEND=nftables fw_backend )" "nftables" "ESB_FW_BACKEND 覆盖探测结果" || return 1
  assert_eq "$(state_get .firewall.backend)" "nftables" "覆盖值同样要写入 state" || return 1
  assert_fail "非法 ESB_FW_BACKEND 必须返回非 0" _fw_t_bad_backend || return 1
  assert_eq "$(state_get .firewall.backend)" "nftables" "非法覆盖值不得污染 state" || return 1
}

# ---------------------------------------------------------------------------
# 7~9 单条规则
# ---------------------------------------------------------------------------
test_7_open_records_once() {
  local _fw_t7_gate=""
  _fw_t_state_fresh || return 1
  _fw_t_stub_env ufw || return 1
  _fw_t_gate_mark
  assert_ok "首次放行 443/tcp 成功" fw_open 443 tcp || return 1
  assert_ok "重复放行 443/tcp 仍返回成功（幂等）" fw_open 443 tcp || return 1
  assert_json "$ESB_STATE" '.firewall.rules' '["443/tcp"]' "重复放行只登记一条 443/tcp" || return 1
  _fw_t7_gate="$(_fw_t_gate_new)"
  assert_contains "$_fw_t7_gate" "ufw allow 443/tcp comment EasySB" "ufw 规则必须带 EasySB 标签" || return 1
  assert_eq "$(printf '%s\n' "$_fw_t7_gate" | grep -c 'ufw allow 443/tcp')" "1" \
    "第二次 fw_open 不得重复下发规则（幂等）" || return 1
}

test_8_open_sort_unique() {
  _fw_t_state_fresh || return 1
  _fw_t_stub_env ufw || return 1
  fw_open 8443 udp >/dev/null 2>&1
  fw_open 80 tcp >/dev/null 2>&1
  fw_open 443 tcp >/dev/null 2>&1
  fw_open 443 tcp >/dev/null 2>&1
  assert_json "$ESB_STATE" '.firewall.rules' '["443/tcp","80/tcp","8443/udp"]' \
    ".firewall.rules 必须去重且有序" || return 1
  assert_json "$ESB_STATE" '.firewall.rules | length' "3" || return 1
}

test_9_close_only_recorded() {
  local _fw_t9_gate=""
  _fw_t_state_fresh || return 1
  _fw_t_stub_env ufw || return 1
  assert_ok "放行 443/tcp" fw_open 443 tcp || return 1
  _fw_t_gate_mark
  assert_ok "关闭未登记过的 2096/tcp 不应失败" fw_close 2096 tcp || return 1
  assert_eq "$(_fw_t_gate_new)" "" "关闭从未登记过的端口不得下发任何命令" || return 1
  assert_ok "关闭已登记的 443/tcp" fw_close 443 tcp || return 1
  _fw_t9_gate="$(_fw_t_gate_new)"
  assert_contains "$_fw_t9_gate" "ufw delete allow 443/tcp" "关闭已登记端口要真的删除规则" || return 1
  assert_json "$ESB_STATE" '.firewall.rules | length' "0" || return 1
}

# ---------------------------------------------------------------------------
# 10~11 fw_apply_all
# ---------------------------------------------------------------------------
_fw_t_proto_set() { # <proto> <enabled> <port> <transport 由模块决定>
  local _fw_tps_proto="$1"
  local _fw_tps_enabled="$2"
  local _fw_tps_port="$3"
  state_set ".protocols[\"$_fw_tps_proto\"].enabled" "$_fw_tps_enabled" || return 1
  state_set ".protocols[\"$_fw_tps_proto\"].port" "$_fw_tps_port" || return 1
  return 0
}

test_10_apply_all_diff() {
  local _fw_t10_gate=""
  _fw_t_state_fresh || return 1
  _fw_t_stub_env ufw || return 1
  _fw_t_proto_set vless-vision-reality true 443 || return 1
  _fw_t_proto_set vmess-ws-tls false 8443 || return 1
  _fw_t_proto_set anytls false 2096 || return 1
  _fw_t_proto_set hysteria2 true 443 || return 1
  _fw_t_proto_set tuic false 8443 || return 1
  state_set '.web.enabled' true || return 1
  state_set '.web.http_port' 80 || return 1
  state_set '.web.tls' false || return 1
  # 先放两条“过期”规则（对应未启用的协议）
  fw_open 2096 tcp >/dev/null 2>&1
  fw_open 8443 tcp >/dev/null 2>&1
  _fw_t_gate_mark
  assert_ok "apply_all 成功" fw_apply_all || return 1
  _fw_t10_gate="$(_fw_t_gate_new)"
  assert_json "$ESB_STATE" '.firewall.rules' '["443/tcp","443/udp","80/tcp"]' \
    "apply_all 后只应剩已启用协议与伪装站点的端口（tcp 443 / udp 443 / tcp 80）" || return 1
  assert_contains "$_fw_t10_gate" "ufw allow 443/tcp" "vless 的 TCP 端口要放行" || return 1
  assert_contains "$_fw_t10_gate" "ufw allow 443/udp" "hysteria2 的 UDP 端口要放行" || return 1
  assert_contains "$_fw_t10_gate" "ufw allow 80/tcp" "伪装站点 80 要放行" || return 1
  assert_contains "$_fw_t10_gate" "ufw delete allow 2096/tcp" "未启用协议（anytls）的过期规则要回收" || return 1
  assert_contains "$_fw_t10_gate" "ufw delete allow 8443/tcp" "未启用协议（vmess/tuic）的过期规则要回收" || return 1
}

test_11_apply_all_idempotent() {
  _fw_t_state_fresh || return 1
  _fw_t_stub_env ufw || return 1
  _fw_t_proto_set vless-vision-reality true 443 || return 1
  state_set '.web.enabled' false || return 1
  assert_ok "首次 apply_all" fw_apply_all || return 1
  _fw_t_gate_mark
  assert_ok "重复 apply_all 仍成功" fw_apply_all || return 1
  assert_eq "$(_fw_t_gate_new)" "" "状态没变的第二次 apply_all 不应再产生任何系统变更" || return 1
  assert_json "$ESB_STATE" '.firewall.rules' '["443/tcp"]' "规则集合保持稳定" || return 1
}

# ---------------------------------------------------------------------------
# 12~14 端口跳跃
# ---------------------------------------------------------------------------
test_12_hop_nft_range() {
  local _fw_t12_gate=""
  _fw_t_state_fresh || return 1
  _fw_t_stub_env nftables || return 1
  _fw_t_gate_mark
  assert_ok "启用端口跳跃（nft）" fw_hop_apply 20000-30000 443 || return 1
  _fw_t12_gate="$(_fw_t_gate_new)"
  assert_contains "$_fw_t12_gate" "udp dport 20000-30000 redirect to :443" \
    "nft 的端口范围必须写成 20000-30000" || return 1
  assert_contains "$_fw_t12_gate" "nft add table inet easysb" \
    "端口跳跃要落在本工具的专用表 inet easysb 里" || return 1
  assert_not_contains "$_fw_t12_gate" "20000:30000" "nft 不得使用 iptables 的冒号写法" || return 1
  assert_json "$ESB_STATE" '.firewall.hop.enabled' "true" || return 1
  assert_json "$ESB_STATE" '.firewall.hop.range' "20000-30000" || return 1
  assert_json "$ESB_STATE" '.firewall.hop.to_port' "443" || return 1
  _fw_t_gate_mark
  assert_ok "参数不变的重复 hop_apply 必须成功" fw_hop_apply 20000-30000 443 || return 1
  assert_eq "$(_fw_t_gate_new)" "" "参数不变的重复 hop_apply 必须幂等" || return 1
}

test_13_hop_iptables_range() {
  local _fw_t13_gate=""
  _fw_t_state_fresh || return 1
  _fw_t_stub_env iptables || return 1
  _fw_t_gate_mark
  assert_ok "启用端口跳跃（iptables）" fw_hop_apply 20000-30000 443 || return 1
  _fw_t13_gate="$(_fw_t_gate_new)"
  assert_contains "$_fw_t13_gate" \
    "iptables -w -t nat -A EASYSB_HOP -p udp --dport 20000:30000 -j REDIRECT --to-ports 443" \
    "iptables 的端口范围必须写成 20000:30000，并落在自有 nat 链" || return 1
  assert_contains "$_fw_t13_gate" "iptables -w -t nat -I PREROUTING 1 -j EASYSB_HOP" \
    "PREROUTING 只插入本工具的一条跳转" || return 1
  assert_not_contains "$_fw_t13_gate" "20000-30000" "iptables 不得使用 nft 的连字符写法" || return 1
  assert_json "$ESB_STATE" '.firewall.hop.range' "20000-30000" \
    "state 里的范围统一存连字符写法（客户端 server_ports 用）" || return 1
}

test_14_hop_clear_iptables() {
  local _fw_t14_gate=""
  _fw_t_state_fresh || return 1
  _fw_t_stub_env iptables || return 1
  fw_hop_apply 20000-30000 443 >/dev/null 2>&1
  assert_json "$ESB_STATE" '.firewall.hop.enabled' "true" || return 1
  _fw_t_gate_mark
  assert_ok "clear 端口跳跃" fw_hop_clear || return 1
  _fw_t14_gate="$(_fw_t_gate_new)"
  assert_contains "$_fw_t14_gate" \
    "iptables -w -t nat -D EASYSB_HOP -p udp --dport 20000:30000 -j REDIRECT --to-ports 443" \
    "clear 要删掉重定向规则本身" || return 1
  assert_contains "$_fw_t14_gate" "iptables -w -t nat -D PREROUTING -j EASYSB_HOP" \
    "clear 要摘掉 PREROUTING 上那条跳转" || return 1
  assert_contains "$_fw_t14_gate" "iptables -w -t nat -X EASYSB_HOP" \
    "clear 要回收自有链" || return 1
  assert_json "$ESB_STATE" '.firewall.hop.enabled' "false" || return 1
  _fw_t_gate_mark
  assert_ok "没有端口跳跃时的 clear 也必须成功" fw_hop_clear || return 1
  assert_eq "$(_fw_t_gate_new)" "" "没有端口跳跃时重复 clear 不得下发任何命令" || return 1
}

# ---------------------------------------------------------------------------
# 15~16 fw_revert_all
# ---------------------------------------------------------------------------
test_15_revert_inert() {
  _fw_t_state_fresh || return 1
  # 用 nftables 的 live 后端：这样“无条件回收”的实现会露出 nft delete table
  _fw_t_stub_env nftables || return 1
  _fw_t_gate_mark
  assert_ok "revert（无规则）成功" fw_revert_all || return 1
  assert_eq "$(_fw_t_gate_new)" "" \
    "从未添加过规则时，revert 不得删除任何规则/表/链" || return 1
  assert_json "$ESB_STATE" '.firewall.rules | length' "0" || return 1
  assert_json "$ESB_STATE" '.firewall.hop.enabled' "false" || return 1
  # 只留下“后端记录”（例如刚探测过一次）但什么都没加过：同样不得删除任何东西
  state_set_str .firewall.backend "nftables" || return 1
  _fw_t_gate_mark
  assert_ok "revert（只有后端记录）成功" fw_revert_all || return 1
  assert_eq "$(_fw_t_gate_new)" "" \
    "只有后端记录、没有任何规则时也不得删除规则/表/链" || return 1
}

test_16_revert_full_nft() {
  local _fw_t16_gate=""
  _fw_t_state_fresh || return 1
  _fw_t_stub_env nftables || return 1
  assert_ok "放行 443/tcp（nft）" fw_open 443 tcp || return 1
  assert_ok "启用端口跳跃（nft）" fw_hop_apply 20000-30000 443 || return 1
  _fw_t_gate_mark
  assert_ok "revert_all（有规则+端口跳跃）成功" fw_revert_all || return 1
  _fw_t16_gate="$(_fw_t_gate_new)"
  assert_contains "$_fw_t16_gate" \
    "nft delete rule inet easysb input tcp dport 443 accept comment EasySB" \
    "登记过的放行规则要逐条回收" || return 1
  assert_contains "$_fw_t16_gate" \
    "nft delete rule inet easysb prerouting udp dport 20000-30000 redirect to :443" \
    "端口跳跃重定向也要回收（卸载后不得留重定向）" || return 1
  assert_contains "$_fw_t16_gate" "nft delete table inet easysb" \
    "本工具的专用表要整表回收（不需要 flush ruleset）" || return 1
  assert_json "$ESB_STATE" '.firewall.rules | length' "0" || return 1
  assert_json "$ESB_STATE" '.firewall.hop.enabled' "false" || return 1
}

# ---------------------------------------------------------------------------
# 17~18 fw_status
# ---------------------------------------------------------------------------
test_17_status_no_tools() {
  local _fw_t17_path=""
  local _fw_t17_out=""
  local _fw_t17_rc=0
  _fw_t_state_fresh || return 1
  _fw_t_stub_env none || return 1
  _fw_t17_path="$(_fw_t_no_fw_path)"
  _fw_t17_out="$( export PATH="$_fw_t17_path"; fw_status 2>&1 )"
  _fw_t17_rc=$?
  assert_eq "$_fw_t17_rc" "0" "没有任何防火墙工具（连 ss/nft 都没有）时 fw_status 必须返回 0" || return 1
  assert_contains "$_fw_t17_out" "none" "摘要应显示后端为 none" || return 1
  assert_contains "$_fw_t17_out" "防火墙后端" "摘要要有人类可读的字段名" || return 1
}

test_18_status_readonly() {
  local _fw_t18_out=""
  _fw_t_state_fresh || return 1
  _fw_t_stub_env ufw || return 1
  assert_ok "放行 443/tcp" fw_open 443 tcp || return 1
  # 故意把记录的后端改成与实时探测不同的值：status 是只读的，不得把它改回去
  state_set_str .firewall.backend "none" || return 1
  _fw_t_gate_mark
  _fw_t18_out="$(fw_status 2>&1)"
  assert_ok "fw_status 成功" fw_status || return 1
  assert_contains "$_fw_t18_out" "ufw" "摘要应显示实时探测到的后端" || return 1
  assert_contains "$_fw_t18_out" "443/tcp" "摘要应列出本工具自己的规则" || return 1
  assert_eq "$(_fw_t_gate_new)" "" "fw_status 是只读的，不得产生任何系统变更" || return 1
  assert_json "$ESB_STATE" '.firewall.backend' "none" \
    "fw_status 不得把探测结果写回 state（要跟 fw_backend 区分开）" || return 1
  assert_json "$ESB_STATE" '.firewall.rules' '["443/tcp"]' "fw_status 不得改动规则记录" || return 1
}

# ---------------------------------------------------------------------------
# 19~20 硬性规则与 harness 契约
# ---------------------------------------------------------------------------
test_19_validators_no_exit() {
  _fw_t_state_fresh || return 1
  _fw_t_stub_env ufw || return 1
  _fw_t_gate_mark
  assert_eq "$( fw_open "" "" >/dev/null 2>&1; printf 'RC=%s' "$?" )" "RC=1" \
    "fw_open 空参数必须 return 1，不能 exit（子 shell 仍能继续执行）" || return 1
  assert_eq "$( fw_open 0 tcp >/dev/null 2>&1; printf 'RC=%s' "$?" )" "RC=1" \
    "fw_open 非法端口返回 1" || return 1
  assert_eq "$( fw_open 70000 tcp >/dev/null 2>&1; printf 'RC=%s' "$?" )" "RC=1" \
    "fw_open 越界端口返回 1" || return 1
  assert_eq "$( fw_open 443 sctp >/dev/null 2>&1; printf 'RC=%s' "$?" )" "RC=1" \
    "fw_open 非法传输协议返回 1" || return 1
  assert_eq "$( fw_close abc tcp >/dev/null 2>&1; printf 'RC=%s' "$?" )" "RC=1" \
    "fw_close 非法端口返回 1" || return 1
  assert_eq "$( fw_hop_apply abc 443 >/dev/null 2>&1; printf 'RC=%s' "$?" )" "RC=1" \
    "fw_hop_apply 非法范围返回 1" || return 1
  assert_eq "$( fw_hop_apply 30000-20000 443 >/dev/null 2>&1; printf 'RC=%s' "$?" )" "RC=1" \
    "fw_hop_apply 范围倒置返回 1" || return 1
  assert_eq "$( fw_hop_apply 20000-30000 99999 >/dev/null 2>&1; printf 'RC=%s' "$?" )" "RC=1" \
    "fw_hop_apply 非法 to_port 返回 1" || return 1
  assert_eq "$(state_get_raw '.firewall.rules | length')" "0" "非法输入不得写入任何规则记录" || return 1
  assert_eq "$(_fw_t_gate_new)" "" "非法输入不得下发任何系统变更" || return 1
}

test_20_helper_contract() {
  _fw_t_state_fresh || return 1
  assert_ok "assert_ok 自检（期望成功）" _fw_t_noop_true || return 1
  assert_fail "assert_fail 自检（期望失败）" _fw_t_noop_false || return 1
  assert_eq "a" "a" "assert_eq 自检" || return 1
  assert_contains "abc" "b" "assert_contains 自检" || return 1
  assert_file "$ESB_STATE" || return 1
  assert_json "$ESB_STATE" '.firewall.rules | length' "0" || return 1
}
