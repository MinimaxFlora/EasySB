# 用例：节点链接与订阅（lib/40-render.sh 的链接部分 + lib/80-subscribe.sh）
# 运行： bash tests/run_tests.sh --case links
# shellcheck shell=bash

TESTS="test_1_links_schemes test_2_base64_roundtrip test_3_sub_files test_4_token_stable \
test_5_mihomo_yaml test_6_singbox_subscription test_7_sub_url_mode test_8_hysteria2_port_range_format \
test_9_sub_enable_standalone test_10_boolean_state_reads"

# ---------------------------------------------------------------------------
# fixture：五协议全开、域名/密钥/证书齐备的状态
# ---------------------------------------------------------------------------
_links_fixture() {
  state_init || return 1
  state_set_str ".domain" "node.example.com" || return 1
  state_set_str ".sub.name" "EasySB" || return 1
  state_set_str ".secrets.vless_uuid" "11111111-2222-4333-8444-555555555555" || return 1
  state_set_str ".secrets.vmess_uuid" "66666666-7777-4888-8999-000000000000" || return 1
  state_set_str ".secrets.tuic_uuid" "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" || return 1
  state_set_str ".secrets.tuic_password" "tuic-pass" || return 1
  state_set_str ".secrets.hysteria2_password" "hy2-pass" || return 1
  state_set_str ".secrets.anytls_password" "anytls-pass" || return 1
  state_set_str ".reality.private_key" "SCytw0AxhrG8S2HNArRWsXXM6xZup0HdSOa2OExE9Gc" || return 1
  state_set_str ".reality.public_key" "jgcVPebui9A55ultlIF0VuESK8eMi9A0v24-wrYBpzU" || return 1
  state_set_str ".reality.short_id" "5b6966df" || return 1
  local _lf_p
  for _lf_p in $(esb_proto_keys); do
    state_proto_set_field "$_lf_p" ".enabled" "true" || return 1
  done
  state_proto_set_field hysteria2 ".hop.enabled" "true" || return 1
  # 证书（TLS 类协议的配置渲染需要真实存在的文件）
  mkdir -p "$ESB_CERT_DIR" || return 1
  if command -v openssl >/dev/null 2>&1; then
    openssl ecparam -genkey -name prime256v1 -out "${ESB_CERT_DIR}/test.key" >/dev/null 2>&1
    openssl req -new -x509 -key "${ESB_CERT_DIR}/test.key" -out "${ESB_CERT_DIR}/test.crt" \
      -days 30 -subj "/CN=node.example.com" >/dev/null 2>&1
  fi
  [ -f "${ESB_CERT_DIR}/test.crt" ] || return 1
  state_set_str ".cert.domain" "node.example.com" || return 1
  state_set_str ".cert.crt" "${ESB_CERT_DIR}/test.crt" || return 1
  state_set_str ".cert.key" "${ESB_CERT_DIR}/test.key" || return 1
  render_clients >/dev/null 2>&1 || return 1
  return 0
}

# ---------------------------------------------------------------------------
test_1_links_schemes() {
  _links_fixture || return 1
  local _t1_lines _t1_n _t1_link
  _t1_lines="$(sub_links_text)"
  _t1_n="$(printf '%s\n' "$_t1_lines" | grep -c .)"
  assert_eq "$_t1_n" "5" "启用五个协议时应生成五条节点链接" || return 1
  for _t1_link in vless:// vmess:// anytls:// hysteria2:// tuic://; do
    assert_contains "$_t1_lines" "$_t1_link" "链接应包含 ${_t1_link} 方案" || return 1
  done
  assert_contains "$_t1_lines" "pbk=jgcVPebui9A55ultlIF0VuESK8eMi9A0v24-wrYBpzU" "VLESS 链接应带 REALITY 公钥" || return 1
  assert_contains "$_t1_lines" "sid=5b6966df" "VLESS 链接应带 short_id" || return 1
  assert_contains "$_t1_lines" "mport=20000-30000" "开启端口跳跃时 hysteria2 链接应带 mport" || return 1
  assert_contains "$_t1_lines" "@node.example.com:443" "链接应使用部署域名与端口" || return 1
  return 0
}

test_2_base64_roundtrip() {
  _links_fixture || return 1
  local _t2_b64 _t2_decoded _t2_plain
  _t2_b64="$(sub_links_base64)"
  assert_ne "$_t2_b64" "" "Base64 订阅内容不应为空" || return 1
  assert_not_contains "$_t2_b64" " " "Base64 订阅内容不应包含空格" || return 1
  _t2_decoded="$(printf '%s' "$_t2_b64" | base64 -d 2>/dev/null)"
  _t2_plain="$(sub_links_text)"
  assert_eq "$(printf '%s' "$_t2_decoded" | grep -c .)" "$(printf '%s' "$_t2_plain" | grep -c .)" \
    "Base64 解码后应还原出同样多的链接" || return 1
  assert_contains "$_t2_decoded" "vless://" "解码内容应包含节点链接" || return 1
  return 0
}

test_3_sub_files() {
  _links_fixture || return 1
  sub_write_files >/dev/null 2>&1 || return 1
  local _t3_dir
  _t3_dir="$(sub_dir)"
  assert_file "${_t3_dir}/sub" "应生成 Base64 通用订阅文件" || return 1
  assert_file "${_t3_dir}/links.txt" "应生成纯文本链接文件" || return 1
  assert_file "${_t3_dir}/singbox.json" "应生成 sing-box JSON 订阅" || return 1
  assert_file "${_t3_dir}/mihomo.yaml" "应生成 Mihomo YAML 订阅" || return 1
  assert_eq "$(grep -c . "${_t3_dir}/links.txt")" "5" "links.txt 应有五条链接" || return 1
  assert_json "${_t3_dir}/singbox.json" '.inbounds[0].listen_port' '10000' \
    "sing-box 订阅应带 mixed 入站 10000" || return 1
  return 0
}

test_4_token_stable() {
  _links_fixture || return 1
  local _t4_a _t4_b _t4_c
  _t4_a="$(sub_token)"
  _t4_b="$(sub_token)"
  assert_eq "$_t4_a" "$_t4_b" "token 应保持稳定（重复读取不变）" || return 1
  assert_eq "${#_t4_a}" "32" "token 应为 32 位十六进制" || return 1
  _t4_c="$(sub_token_regen)"
  assert_ne "$_t4_a" "$_t4_c" "重置后 token 应变化" || return 1
  assert_eq "$(state_get .sub.token)" "$_t4_c" "重置后的 token 应写入 state" || return 1
  assert_contains "$(sub_url)" "$_t4_c" "订阅地址应包含 token" || return 1
  return 0
}

test_5_mihomo_yaml() {
  _links_fixture || return 1
  local _t5_yaml
  _t5_yaml="$(sub_mihomo_yaml)"
  assert_contains "$_t5_yaml" "type: vless" "Mihomo 应包含 vless 节点" || return 1
  assert_contains "$_t5_yaml" "type: vmess" "Mihomo 应包含 vmess 节点" || return 1
  assert_contains "$_t5_yaml" "type: hysteria2" "Mihomo 应包含 hysteria2 节点" || return 1
  assert_contains "$_t5_yaml" "type: tuic" "Mihomo 应包含 tuic 节点" || return 1
  assert_contains "$_t5_yaml" "type: anytls" "Mihomo 应包含 anytls 节点" || return 1
  assert_contains "$_t5_yaml" "reality-opts:" "vless 节点应带 reality-opts" || return 1
  assert_contains "$_t5_yaml" "proxy-groups:" "应包含策略组" || return 1
  assert_eq "$(printf '%s' "$_t5_yaml" | grep -c '  - name: \"')" "5" "应恰好有五条 proxies 条目" || return 1
  # 关闭一个协议后，该节点应从 YAML 中消失
  state_proto_set_field tuic ".enabled" "false" || return 1
  _t5_yaml="$(sub_mihomo_yaml)"
  assert_not_contains "$_t5_yaml" "type: tuic" "关闭 tuic 后不应再出现在 Mihomo 配置里" || return 1
  return 0
}

test_6_singbox_subscription() {
  _links_fixture || return 1
  local _t6_sub _t6_all
  _t6_sub="$(sub_singbox_json)"
  _t6_all="$(cat "${ESB_CLIENT_DIR}/all.json")"
  assert_eq "$_t6_sub" "$_t6_all" "sing-box 订阅内容应与 all.json 一致" || return 1
  assert_json "${ESB_CLIENT_DIR}/all.json" '.outbounds | length' '6' \
    "五个协议 + direct 共六条 outbound" || return 1
  return 0
}

test_7_sub_url_mode() {
  _links_fixture || return 1
  # 伪装站点 + TLS + 证书 → https 订阅地址
  state_set ".web.enabled" "true" || return 1
  state_set ".web.tls" "true" || return 1
  assert_contains "$(sub_url)" "https://node.example.com/sub/" "复用伪装站点时应是 HTTPS 地址" || return 1
  # 独立订阅站点 → http://域名:8080/sub/<token>
  state_set ".sub.serve_via_site" "false" || return 1
  assert_contains "$(sub_url)" "http://node.example.com:8080/sub/" "独立站点时应带订阅端口" || return 1
  assert_contains "$(sub_url_list)" "mihomo" "订阅地址列表应包含 mihomo 格式" || return 1
  return 0
}

test_8_hysteria2_port_range_format() {
  _links_fixture || return 1
  local _t8_range _t8_client
  _t8_range="$(state_get '.protocols.hysteria2.hop.range')"
  assert_eq "$_t8_range" "20000-30000" "state 里端口范围用 '-' 形式保存（供 UI 与 nft 使用）" || return 1
  assert_json "${ESB_CLIENT_DIR}/hysteria2.json" '.outbounds[0].server_ports[0]' '20000:30000' \
    "sing-box 客户端 server_ports 必须用 ':' 形式（'-' 会被内核判为 bad port range）" || return 1
  assert_contains "$(sub_links_text)" "mport=20000-30000" "hysteria2 分享链接用 '-' 形式（hysteria URI 规范）" || return 1
  return 0
}

test_9_sub_enable_standalone() {
  _links_fixture || return 1
  state_set ".web.enabled" "false" || return 1
  state_set ".sub.serve_via_site" "false" || return 1
  sub_enable >/dev/null 2>&1 || return 1
  assert_eq "$(state_get .sub.enabled)" "true" "启用成功后 state 应记录订阅已启用" || return 1
  assert_contains "$(cat "${ESB_GATE_LOG:-/dev/null}" 2>/dev/null)" "nginx -t" \
    "部署独立订阅站点前必须执行 nginx -t" || return 1
  assert_contains "$(cat "${ESB_GATE_LOG:-/dev/null}" 2>/dev/null)" "$(state_get .sub.port)" \
    "应放行订阅站点端口" || return 1
  sub_disable >/dev/null 2>&1 || return 1
  assert_eq "$(state_get .sub.enabled)" "false" "关闭后应记录为未启用" || return 1
  return 0
}

# 直接锁定"布尔状态读回来必须是 false 而不是空"这一类缺陷
# （jq 的 `//` 与 `-e` 都会把 false 当空：前者让读取结果变空，后者让写入被误判成非法 JSON）
test_10_boolean_state_reads() {
  state_init || return 1
  state_set_str ".domain" "node.example.com" || return 1
  # 未启用的协议：读取必须得到字面量 false
  assert_eq "$(state_get '.protocols.tuic.enabled')" "false" \
    "未启用协议的 enabled 必须读回 false（不能被 // empty 吞成空）" || return 1
  assert_eq "$(state_get '.sub.enabled')" "false" "默认关闭的 sub.enabled 必须读回 false" || return 1
  assert_eq "$(state_get '.protocols.hysteria2.hop.enabled')" "false" \
    "默认关闭的 hop.enabled 必须读回 false" || return 1
  # 写入 false 必须成功（jq -e 会把 false 判成"非法 JSON"）
  assert_ok "写入 .sub.enabled=false 必须成功" state_set ".sub.enabled" "false" || return 1
  assert_ok "写入协议 enabled=false 必须成功" state_proto_set_field tuic ".enabled" "false" || return 1
  assert_eq "$(state_get '.protocols.tuic.enabled')" "false" "写入后读回仍应是 false" || return 1
  # 启用一个协议后，列表与端口必须跟着变
  state_proto_set_field vless-vision-reality ".enabled" "true" || return 1
  proto_enabled tuic && { _harness_fail "tuic 未启用却被 proto_enabled 判为启用"; return 1; }
  assert_ok "vless 启用后 proto_enabled 必须为真" proto_enabled vless-vision-reality || return 1
  assert_eq "$(proto_enabled_list)" "vless-vision-reality" "已启用协议列表必须只含启用项" || return 1
  assert_eq "$(proto_port vless-vision-reality)" "443" "端口必须读自 state" || return 1
  return 0
}
