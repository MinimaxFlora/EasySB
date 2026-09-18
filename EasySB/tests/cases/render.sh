#!/usr/bin/env bash
# =============================================================================
# 用例：40-render.sh（配置渲染）—— 全量夹具状态 + 对生成结果逐字段断言
#   全部断言 jq 相关，缺 jq 时整例 SKIP（requires_jq）
#   由 tests/run_tests.sh source（lib/*.sh 与 tests/lib/harness.sh 已加载）
# =============================================================================

TESTS="
  test_render_config_valid_and_order
  test_render_config_ports_match_state
  test_render_config_vless_reality_fields
  test_render_config_vmess_ws_tls_fields
  test_render_config_anytls_padding_on
  test_render_config_anytls_padding_off
  test_render_config_hysteria2_443_alpn_h3
  test_render_config_tuic_fields
  test_render_config_disabled_protocol_absent
  test_render_config_no_protocol_fails
  test_render_config_cert_missing_fails_cleanly
  test_render_client_all_mixed_and_outbounds
  test_render_client_all_hysteria2_hop
  test_render_client_proto_file
  test_render_links_schemes_and_count
  test_render_link_vless_content
  test_render_link_vmess_base64_json
  test_render_link_hysteria2_mport_only_when_hop
  test_render_link_tuic_and_anytls_content
  test_render_link_password_url_encoded
  test_render_summary_lists_protocols
"

# ---------------------------------------------------------------------------
# 本文件私有助手
# ---------------------------------------------------------------------------
# 全量夹具状态：域名 + REALITY 密钥 + 固定密钥 + 证书文件 + 5 个协议全开
_render_full() {
  sandbox_reset || return 1
  sandbox_seed_full || return 1
  return 0
}

_render_tmp_leftovers() { ls -1 "${1:-.}" 2>/dev/null | grep -c '\.tmp\.'; }

# ---------------------------------------------------------------------------
# 服务端配置：整体形状与顺序
# ---------------------------------------------------------------------------
test_render_config_valid_and_order() {
  requires_jq || return 77
  _render_full || return 1
  assert_ok "render_config 应成功" render_config || return 1
  assert_file "$ESB_CONFIG" "必须生成 $ESB_CONFIG" || return 1
  assert_ok "生成的配置必须是合法 JSON" jq -e . "$ESB_CONFIG" || return 1
  assert_json "$ESB_CONFIG" '.inbounds|length' '5' "5 个协议全开时应有 5 个 inbound" || return 1
  assert_json "$ESB_CONFIG" '[.inbounds[].tag]|join(" ")' \
    'vless-vision-reality vmess-ws-tls anytls hysteria2 tuic' \
    "inbound 必须只含已启用协议，且按 esb_proto_keys 顺序" || return 1
  assert_json "$ESB_CONFIG" '[.inbounds[].listen]|unique|join(",")' '::' "inbound 应监听 ::（双栈）" || return 1
  assert_json "$ESB_CONFIG" '[.outbounds[].tag]|join(" ")' 'direct' "服务端只保留 direct outbound" || return 1
  assert_json "$ESB_CONFIG" '.outbounds[0].type' 'direct' "direct outbound 类型必须是 direct" || return 1
  assert_json "$ESB_CONFIG" '.log.level' 'warn' "未设置 log_level 时默认 warn" || return 1
  assert_json "$ESB_CONFIG" '.log.timestamp' 'true' "日志应带时间戳" || return 1
  return 0
}

test_render_config_ports_match_state() {
  requires_jq || return 77
  _render_full || return 1
  render_config || return 1
  # 逐个协议：端口必须来自 state（允许 UI 改端口后仍然一致）
  state_proto_set_field anytls .port 20000 || return 1
  state_proto_set_field hysteria2 .port 40000 || return 1
  render_config || return 1
  local _t_p
  for _t_p in $(esb_proto_keys); do
    assert_json "$ESB_CONFIG" ".inbounds[]|select(.tag==\"$_t_p\")|.listen_port" "$(proto_port "$_t_p")" \
      "$_t_p 的 listen_port 必须等于 state 里的端口" || return 1
  done
  assert_json "$ESB_CONFIG" '.inbounds[]|select(.tag=="anytls")|.listen_port' '20000' \
    "改过的端口必须生效（anytls 20000）" || return 1
  assert_json "$ESB_CONFIG" '.inbounds[]|select(.tag=="hysteria2")|.listen_port' '40000' \
    "改过的端口必须生效（hysteria2 40000）" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 服务端配置：逐协议字段
# ---------------------------------------------------------------------------
test_render_config_vless_reality_fields() {
  requires_jq || return 77
  _render_full || return 1
  render_config || return 1
  local _t_q='.inbounds[]|select(.tag=="vless-vision-reality")'
  assert_json "$ESB_CONFIG" "$_t_q|.type" 'vless' "inbound 类型" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.users[0].uuid" "$ESB_TEST_FIX_VLESS_UUID" "uuid 必须来自 state.secrets" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.users[0].flow" 'xtls-rprx-vision' "必须带 Vision 流控" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.tls.enabled" 'true' "REALITY 走 TLS 段" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.tls.server_name" "$ESB_TEST_FIX_HANDSHAKE" "SNI 用 reality.server_name" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.tls.reality.enabled" 'true' "必须启用 reality" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.tls.reality.private_key" "$ESB_TEST_FIX_REALITY_PRIV" \
    "private_key 必须来自 state.reality.private_key" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.tls.reality.short_id[0]" "$ESB_TEST_FIX_SHORT_ID" \
    "short_id 必须是数组且含 state 里的值" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.tls.reality.handshake.server" "$ESB_TEST_FIX_HANDSHAKE" \
    "handshake 借用站点必须来自 state" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.tls.reality.handshake.server_port" '443' "handshake 端口 443" || return 1
  # 服务端不得出现敏感字段泄漏以外的东西：公钥不该出现在服务端配置里
  assert_json "$ESB_CONFIG" "$_t_q|.tls.reality|has(\"public_key\")" 'false' \
    "服务端 inbound 不应带 public_key（那是客户端用的）" || return 1
  return 0
}

test_render_config_vmess_ws_tls_fields() {
  requires_jq || return 77
  _render_full || return 1
  render_config || return 1
  local _t_q='.inbounds[]|select(.tag=="vmess-ws-tls")'
  assert_json "$ESB_CONFIG" "$_t_q|.type" 'vmess' "inbound 类型" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.users[0].uuid" "$ESB_TEST_FIX_VMESS_UUID" "uuid 来自 state.secrets" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.transport.type" 'ws' "传输必须是 websocket" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.transport.path" '/vmess' "ws path 必须来自 state" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.transport.max_early_data" '2048' "early_data=true 时应带 max_early_data" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.tls.enabled" 'true' "必须启用 TLS" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.tls.certificate_path" "$(state_get .cert.crt)" \
    "certificate_path 必须是 state.cert.crt" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.tls.key_path" "$(state_get .cert.key)" "key_path 必须是 state.cert.key" || return 1
  # 改 path → 生效
  state_proto_set_field vmess-ws-tls .path '"/ws2"' || return 1
  render_config || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.transport.path" '/ws2' "改过的 path 必须生效" || return 1
  return 0
}

test_render_config_anytls_padding_on() {
  requires_jq || return 77
  _render_full || return 1
  render_config || return 1
  local _t_q='.inbounds[]|select(.tag=="anytls")'
  assert_json "$ESB_CONFIG" "$_t_q|.type" 'anytls' "inbound 类型" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.users[0].password" "$ESB_TEST_FIX_ANYTLS_PASSWORD" "密码来自 state.secrets" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.tls.alpn|join(\",\")" 'h3,h2,http/1.1' "AnyTLS 需要 h3/h2/http1.1" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|has(\"padding_scheme\")" 'true' "padding=true 时必须输出 padding_scheme" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.padding_scheme|length" '9' "默认填充方案是 9 条规则" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.padding_scheme[0]" 'stop=8' "填充方案第 1 条应为 stop=8" || return 1
  return 0
}

test_render_config_anytls_padding_off() {
  requires_jq || return 77
  _render_full || return 1
  state_proto_set_field anytls .padding false || return 1
  render_config || return 1
  local _t_q='.inbounds[]|select(.tag=="anytls")'
  # INTERFACES §0.9：不用的可选键必须整个不输出（空数组也不行）
  assert_json "$ESB_CONFIG" "$_t_q|has(\"padding_scheme\")" 'false' \
    "padding=false 时 padding_scheme 键必须整个不输出" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.users[0].password" "$ESB_TEST_FIX_ANYTLS_PASSWORD" \
    "关掉填充不影响其它字段" || return 1
  return 0
}

test_render_config_hysteria2_443_alpn_h3() {
  requires_jq || return 77
  _render_full || return 1
  render_config || return 1
  local _t_q='.inbounds[]|select(.tag=="hysteria2")'
  # hysteria2 是 QUIC/UDP 协议：靠类型决定，端口必须与 state 一致（默认 443）
  assert_json "$ESB_CONFIG" "$_t_q|.type" 'hysteria2' "inbound 类型（QUIC/UDP）" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.listen_port" '443' "hysteria2 默认 UDP 443" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.tls.alpn|join(\",\")" 'h3' "hysteria2 的 ALPN 必须是 h3" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.users[0].password" "$ESB_TEST_FIX_HY2_PASSWORD" "密码来自 state.secrets" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.up_mbps" '100' "上行取自 state" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.down_mbps" '100' "下行取自 state" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.tls.certificate_path" "$(state_get .cert.crt)" "证书路径来自 state" || return 1
  return 0
}

test_render_config_tuic_fields() {
  requires_jq || return 77
  _render_full || return 1
  render_config || return 1
  local _t_q='.inbounds[]|select(.tag=="tuic")'
  assert_json "$ESB_CONFIG" "$_t_q|.type" 'tuic' "inbound 类型（QUIC/UDP）" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.listen_port" '8443' "tuic 默认 UDP 8443" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.congestion_control" 'bbr' "拥塞控制必须是 bbr" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.users[0].uuid" "$ESB_TEST_FIX_TUIC_UUID" "uuid + 密码都要带上（uuid）" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.users[0].password" "$ESB_TEST_FIX_TUIC_PASSWORD" "uuid + 密码都要带上（密码）" || return 1
  assert_json "$ESB_CONFIG" "$_t_q|.tls.alpn|join(\",\")" 'h3' "TUIC 的 ALPN 必须是 h3" || return 1
  return 0
}

test_render_config_disabled_protocol_absent() {
  requires_jq || return 77
  _render_full || return 1
  sandbox_proto_off anytls || return 1
  sandbox_proto_off tuic || return 1
  render_config || return 1
  assert_json "$ESB_CONFIG" '.inbounds|length' '3' "只应剩 3 个 inbound" || return 1
  assert_json "$ESB_CONFIG" '[.inbounds[].tag]|join(" ")' 'vless-vision-reality vmess-ws-tls hysteria2' \
    "禁用后剩余 inbound 仍须按 esb_proto_keys 顺序" || return 1
  assert_json "$ESB_CONFIG" '[.inbounds[].tag]|index("anytls")|tostring' 'null' "禁用的 anytls 不得出现" || return 1
  assert_json "$ESB_CONFIG" '[.inbounds[].tag]|index("tuic")|tostring' 'null' "禁用的 tuic 不得出现" || return 1
  return 0
}

test_render_config_no_protocol_fails() {
  requires_jq || return 77
  sandbox_reset || return 1
  sandbox_seed_state || return 1
  assert_fail "没有任何启用协议时 render_config 必须返回非 0" render_config || return 1
  assert_eq "$([ -e "$ESB_CONFIG" ] && printf 'yes' || printf 'no')" "no" \
    "失败时不得生成配置文件" || return 1
  return 0
}

test_render_config_cert_missing_fails_cleanly() {
  requires_jq || return 77
  sandbox_reset || return 1
  sandbox_seed_state || return 1
  sandbox_proto_on anytls || return 1
  mkdir -p "$ESB_CONF_DIR" || return 1
  printf '{"log":{"level":"warn"},"inbounds":[],"outbounds":[]}\n' >"$ESB_CONFIG" || return 1
  cp -f "$ESB_CONFIG" "$ESB_TEST_WORK/render_prev_config.json" || return 1
  assert_fail "启用 TLS 协议但未应用证书时 render_config 必须返回非 0" render_config || return 1
  assert_ok "失败时必须原样保留旧配置（不得写半成品）" cmp -s "$ESB_CONFIG" "$ESB_TEST_WORK/render_prev_config.json" || return 1
  assert_eq "$(_render_tmp_leftovers "$ESB_CONF_DIR")" "0" "失败时不得残留 .tmp.$$ 半成品" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 客户端配置
# ---------------------------------------------------------------------------
test_render_client_all_mixed_and_outbounds() {
  requires_jq || return 77
  _render_full || return 1
  assert_ok "render_client_all 应成功" render_client_all || return 1
  local _t_f="$ESB_CLIENT_DIR/all.json"
  assert_file "$_t_f" "必须生成 $ESB_CLIENT_DIR/all.json" || return 1
  assert_ok "all.json 必须是合法 JSON" jq -e . "$_t_f" || return 1
  assert_json "$_t_f" '.inbounds|length' '1' "客户端只应有一个本地 inbound" || return 1
  assert_json "$_t_f" '.inbounds[0].type' 'mixed' "本地 inbound 必须是 mixed（http+socks）" || return 1
  assert_json "$_t_f" '.inbounds[0].listen_port' '10000' "mixed inbound 端口必须是 10000" || return 1
  assert_json "$_t_f" '[.outbounds[].tag]|join(" ")' \
    'vless-vision-reality vmess-ws-tls anytls hysteria2 tuic direct' \
    "每个已启用协议一个 outbound，最后追加 direct" || return 1
  assert_json "$_t_f" '.outbounds[-1].type' 'direct' "最后一个 outbound 必须是 direct" || return 1
  assert_json "$_t_f" '.outbounds[]|select(.tag=="vmess-ws-tls")|.transport.path' '/vmess' \
    "客户端 ws path 必须与 state 一致" || return 1
  assert_json "$_t_f" '.outbounds[]|select(.tag=="vless-vision-reality")|.tls.reality.public_key' \
    "$ESB_TEST_FIX_REALITY_PUB" "客户端必须用公钥（不是私钥）" || return 1
  assert_json "$_t_f" '.outbounds[]|select(.tag=="tuic")|.uuid' \
    "$ESB_TEST_FIX_TUIC_UUID" "客户端 tuic 必须带 uuid" || return 1
  assert_json "$_t_f" '.outbounds[]|select(.tag=="tuic")|.password' \
    "$ESB_TEST_FIX_TUIC_PASSWORD" "客户端 tuic 必须带密码" || return 1
  assert_json "$_t_f" '.outbounds[]|select(.tag=="hysteria2")|has("server_ports")' 'false' \
    "端口跳跃未启用时不得输出 server_ports（INTERFACES §0.9）" || return 1
  # 客户端配置里不得出现 REALITY 私钥
  assert_not_contains "$(<"$_t_f")" "$ESB_TEST_FIX_REALITY_PRIV" "客户端配置绝不能包含 REALITY 私钥" || return 1
  return 0
}

test_render_client_all_hysteria2_hop() {
  requires_jq || return 77
  _render_full || return 1
  state_proto_set_field hysteria2 .hop.enabled true || return 1
  state_proto_set_field hysteria2 .hop.range '"20000-30000"' || return 1
  render_client_all || return 1
  local _t_f="$ESB_CLIENT_DIR/all.json"
  # state 里统一保存 "a-b"，客户端要写成 sing-box 认的 "a:b"（连字符会被 sing-box check 拒绝）
  assert_json "$_t_f" '.outbounds[]|select(.tag=="hysteria2")|.server_ports[0]' '20000:30000' \
    "开启端口跳跃后客户端必须带 server_ports（冒号形式）" || return 1
  assert_json "$_t_f" '.outbounds[]|select(.tag=="hysteria2")|.hop_interval' '30s' \
    "跳跃间隔取自 state" || return 1
  return 0
}

test_render_client_proto_file() {
  requires_jq || return 77
  _render_full || return 1
  assert_ok "render_client_proto vmess-ws-tls 应成功" render_client_proto vmess-ws-tls || return 1
  local _t_f="$ESB_CLIENT_DIR/vmess-ws-tls.json"
  assert_file "$_t_f" "必须生成单协议客户端配置" || return 1
  # 单协议文件当前是「可直接使用的客户端配置」（本地 mixed 入站 + 单条 outbound）；
  # 用 (.outbounds // [.])[0] 取值，兼容"完整配置"与"裸 outbound"两种形状。
  assert_json "$_t_f" '(.outbounds // [.])[0]|.type' 'vmess' "单协议配置的 outbound 类型" || return 1
  assert_json "$_t_f" '(.outbounds // [.])[0]|.server' "$ESB_TEST_FIX_DOMAIN" "server 必须是部署域名" || return 1
  assert_json "$_t_f" '(.outbounds // [.])[0]|.server_port' '8443' "端口必须来自 state" || return 1
  assert_json "$_t_f" '(.outbounds // [.])[0]|.transport.path' '/vmess' "ws path 与 state 一致" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 分享链接
# ---------------------------------------------------------------------------
test_render_links_schemes_and_count() {
  requires_jq || return 77
  _render_full || return 1
  local _t_links
  _t_links="$(render_links)"
  assert_eq "$(printf '%s\n' "$_t_links" | grep -c .)" "5" "5 个协议全开时应有 5 条链接" || return 1
  assert_eq "$(printf '%s\n' "$_t_links" | grep -c '^vless://')" "1" "应有 1 条 vless:// 链接" || return 1
  assert_eq "$(printf '%s\n' "$_t_links" | grep -c '^vmess://')" "1" "应有 1 条 vmess:// 链接" || return 1
  assert_eq "$(printf '%s\n' "$_t_links" | grep -c '^anytls://')" "1" "应有 1 条 anytls:// 链接" || return 1
  assert_eq "$(printf '%s\n' "$_t_links" | grep -c '^hysteria2://')" "1" "应有 1 条 hysteria2:// 链接" || return 1
  assert_eq "$(printf '%s\n' "$_t_links" | grep -c '^tuic://')" "1" "应有 1 条 tuic:// 链接" || return 1
  # 关掉一个协议 → 链接必须消失
  sandbox_proto_off anytls || return 1
  _t_links="$(render_links)"
  assert_eq "$(printf '%s\n' "$_t_links" | grep -c .)" "4" "禁用 anytls 后应只剩 4 条链接" || return 1
  assert_eq "$(printf '%s\n' "$_t_links" | grep -c '^anytls://')" "0" "禁用的协议不得输出链接" || return 1
  return 0
}

test_render_link_vless_content() {
  requires_jq || return 77
  _render_full || return 1
  local _t_l
  _t_l="$(link_vless)"
  assert_contains "$_t_l" "vless://$ESB_TEST_FIX_VLESS_UUID@$ESB_TEST_FIX_DOMAIN:443" \
    "vless 链接前缀必须是 vless://<uuid>@<域名>:<端口>" || return 1
  assert_contains "$_t_l" "flow=xtls-rprx-vision" "必须带 Vision 流控" || return 1
  assert_contains "$_t_l" "security=reality" "必须是 reality 安全模式" || return 1
  assert_contains "$_t_l" "sni=$ESB_TEST_FIX_HANDSHAKE" "SNI 必须来自 state" || return 1
  assert_contains "$_t_l" "pbk=$ESB_TEST_FIX_REALITY_PUB" "必须带 REALITY 公钥" || return 1
  assert_contains "$_t_l" "sid=$ESB_TEST_FIX_SHORT_ID" "必须带 short_id" || return 1
  assert_contains "$_t_l" "type=tcp" "REALITY 走 TCP" || return 1
  assert_contains "$_t_l" "$ESB_TEST_FIX_DOMAIN" "备注名里应含域名便于识别" || return 1
  assert_not_contains "$_t_l" "$ESB_TEST_FIX_REALITY_PRIV" "链接里绝不能出现 REALITY 私钥" || return 1
  return 0
}

test_render_link_vmess_base64_json() {
  requires_jq || return 77
  _render_full || return 1
  local _t_l _t_b64 _t_json
  _t_l="$(link_vmess)"
  assert_eq "${_t_l%%://*}" "vmess" "vmess 链接的 scheme 必须是 vmess" || return 1
  _t_b64="${_t_l#vmess://}"
  assert_ok "vmess 链接体必须是合法 base64" sh -c 'printf "%s" "$1" | base64 -d >/dev/null 2>&1' sh "$_t_b64" || return 1
  _t_json="$(printf '%s' "$_t_b64" | base64 -d 2>/dev/null)"
  assert_ok "vmess 链接体解码后必须是合法 JSON" sh -c 'printf "%s" "$1" | jq -e . >/dev/null' sh "$_t_json" || return 1
  # Windows 版 jq 输出 CRLF：读值时去掉 \r（Linux 上无影响）
  assert_eq "$(printf '%s' "$_t_json" | jq -r '.add' | tr -d '\r')" "$ESB_TEST_FIX_DOMAIN" "解码后的 add 必须等于部署域名" || return 1
  assert_eq "$(printf '%s' "$_t_json" | jq -r '.path' | tr -d '\r')" "/vmess" "解码后的 path 必须等于 state 里的 ws path" || return 1
  assert_eq "$(printf '%s' "$_t_json" | jq -r '.port' | tr -d '\r')" "8443" "解码后的 port 必须等于 state 端口" || return 1
  assert_eq "$(printf '%s' "$_t_json" | jq -r '.id' | tr -d '\r')" "$ESB_TEST_FIX_VMESS_UUID" "解码后的 id 必须等于 vmess uuid" || return 1
  assert_eq "$(printf '%s' "$_t_json" | jq -r '.net' | tr -d '\r')" "ws" "net 必须是 ws" || return 1
  assert_eq "$(printf '%s' "$_t_json" | jq -r '.tls' | tr -d '\r')" "tls" "tls 必须是 tls" || return 1
  assert_eq "$(printf '%s' "$_t_json" | jq -r '.host' | tr -d '\r')" "$ESB_TEST_FIX_DOMAIN" "host 必须等于域名（SNI/Host 头）" || return 1
  return 0
}

test_render_link_hysteria2_mport_only_when_hop() {
  requires_jq || return 77
  _render_full || return 1
  local _t_l
  _t_l="$(link_hysteria2)"
  assert_eq "${_t_l%%://*}" "hysteria2" "scheme 必须是 hysteria2" || return 1
  assert_contains "$_t_l" "@$ESB_TEST_FIX_DOMAIN:443" "必须指向域名与端口" || return 1
  assert_contains "$_t_l" "alpn=h3" "必须带 alpn=h3" || return 1
  assert_not_contains "$_t_l" "mport=" "端口跳跃未启用时不得带 mport=" || return 1
  # 开启端口跳跃 → 必须带 mport=<范围>
  state_proto_set_field hysteria2 .hop.enabled true || return 1
  state_proto_set_field hysteria2 .hop.range '"20000-30000"' || return 1
  _t_l="$(link_hysteria2)"
  assert_contains "$_t_l" "mport=20000-30000" "启用跳跃后必须带 mport=<范围>" || return 1
  assert_contains "$_t_l" "hop_interval=30s" "启用跳跃后必须带 hop_interval" || return 1
  assert_eq "${_t_l%%://*}" "hysteria2" "带 mport 时 scheme 仍是 hysteria2" || return 1
  return 0
}

test_render_link_tuic_and_anytls_content() {
  requires_jq || return 77
  _render_full || return 1
  local _t_t _t_a
  _t_t="$(link_tuic)"
  assert_eq "${_t_t%%://*}" "tuic" "tuic 链接 scheme 必须是 tuic" || return 1
  assert_contains "$_t_t" "$ESB_TEST_FIX_TUIC_UUID" "必须带 uuid" || return 1
  assert_contains "$_t_t" "$ESB_TEST_FIX_TUIC_PASSWORD" "必须带密码" || return 1
  assert_contains "$_t_t" "congestion_control=bbr" "必须带拥塞控制" || return 1
  assert_contains "$_t_t" ":8443" "必须指向 state 里的端口" || return 1
  _t_a="$(link_anytls)"
  assert_eq "${_t_a%%://*}" "anytls" "anytls 链接 scheme 必须是 anytls" || return 1
  assert_contains "$_t_a" "$ESB_TEST_FIX_ANYTLS_PASSWORD" "必须带密码" || return 1
  assert_contains "$_t_a" "sni=$ESB_TEST_FIX_DOMAIN" "必须带 SNI" || return 1
  assert_contains "$_t_a" ":2096" "必须指向 state 里的端口" || return 1
  return 0
}

test_render_link_password_url_encoded() {
  requires_jq || return 77
  _render_full || return 1
  # 含 @ / + 的密码必须 URL 编码（否则链接会被解析成另一个 host）
  secret_set hysteria2_password 'p@ss/w+1' || return 1
  local _t_l
  _t_l="$(link_hysteria2)"
  assert_not_contains "$_t_l" "p@ss/w+1" "密码不得原样出现在链接里" || return 1
  assert_contains "$_t_l" "p%40ss%2Fw%2B1" "密码必须按 RFC3986 百分号编码（@→%40 /→%2F +→%2B）" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 摘要
# ---------------------------------------------------------------------------
test_render_summary_lists_protocols() {
  requires_jq || return 77
  _render_full || return 1
  local _t_s
  _t_s="$(render_summary 2>/dev/null)"
  assert_contains "$_t_s" "$ESB_TEST_FIX_DOMAIN" "摘要必须显示部署域名" || return 1
  assert_contains "$_t_s" "vless-vision-reality" "摘要必须列出启用的协议" || return 1
  assert_contains "$_t_s" "hysteria2" "摘要必须列出 hysteria2" || return 1
  assert_contains "$_t_s" "UDP" "QUIC 协议必须标注 UDP" || return 1
  assert_contains "$_t_s" "TCP" "REALITY 必须标注 TCP" || return 1
  return 0
}
