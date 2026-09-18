# 用例：节点链接与订阅（lib/40-render.sh 的链接部分 + lib/80-subscribe.sh）
# 运行： bash tests/run_tests.sh --case links
# shellcheck shell=bash

TESTS="test_1_links_schemes test_2_base64_roundtrip test_3_sub_files test_4_token_stable \
test_5_mihomo_yaml test_6_singbox_subscription test_7_sub_url_mode test_8_hysteria2_port_range_format \
test_9_sub_enable_standalone test_10_boolean_state_reads \
test_11_singbox_tun_template test_12_tun_partial_protocols test_13_mihomo_template_shape \
test_14_insecure_follows_cert_source test_15_per_protocol_cert_mode \
test_16_vmess_tls_toggle test_17_vmess_naming_follows_cert"

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

# ---------------------------------------------------------------------------
# 沙箱里准备仓库自带的 sing-box 模板缓存（订阅生成会优先读缓存，避免联网）
# ---------------------------------------------------------------------------
_links_seed_tun_template() {
  local _lst_cand _lst_src=""
  for _lst_cand in \
    "${ESB_REPO_ROOT}/Templates/tun-fakeip.json" \
    "${ESB_REPO_ROOT}/../Templates/tun-fakeip.json" \
    "${ESB_TESTS_DIR}/../Templates/tun-fakeip.json"; do
    if [ -f "$_lst_cand" ]; then _lst_src="$_lst_cand"; break; fi
  done
  [ -n "$_lst_src" ] || return 1
  mkdir -p "$(dirname "$(_sub_singbox_tpl_file)")" || return 1
  cp -f "$_lst_src" "$(_sub_singbox_tpl_file)" || return 1
  return 0
}

# 11. singbox.json 必须是"按仓库模板生成"的 TUN + FakeIP + 分流配置
test_11_singbox_tun_template() {
  _links_fixture || return 1
  _links_seed_tun_template || { skip_test "仓库里没有 Templates/tun-fakeip.json（无法验证模板生成）"; return 77; }
  local _t11_out
  _t11_out="$(sub_singbox_tun_json 2>/dev/null)" || { _harness_fail "sub_singbox_tun_json 生成失败"; return 1; }
  printf '%s' "$_t11_out" >"${ESB_TMP}/t11.json"
  assert_json "${ESB_TMP}/t11.json" '.inbounds|length' '1' "TUN 模板配置应是合法 JSON" || return 1

  # 入站/路由/实验段沿用模板（TUN + FakeIP + 国内直连分流）
  assert_eq "$(jq -r '.inbounds[0].type' "${ESB_TMP}/t11.json")" "tun" "应使用模板的 TUN 入站" || return 1
  assert_eq "$(jq -r '.inbounds[0].auto_route' "${ESB_TMP}/t11.json")" "true" "应保留模板 auto_route" || return 1
  assert_eq "$(jq -r '.dns.final' "${ESB_TMP}/t11.json")" "dns-proxy" "应保留模板 DNS 兜底服务器" || return 1
  assert_eq "$(jq -r '.route.rules|length' "${ESB_TMP}/t11.json")" "7" "应保留模板的 7 条路由规则" || return 1
  assert_eq "$(jq -r '[.route.rule_set[].tag]|join(",")' "${ESB_TMP}/t11.json")" "geosite-cn,geoip-cn" "应保留模板规则集" || return 1
  assert_eq "$(jq -r '.experimental.clash_api.external_controller' "${ESB_TMP}/t11.json")" "0.0.0.0:9090" "应保留模板 clash_api" || return 1

  # 节点用我们生成的真实参数
  assert_eq "$(jq -r '[.outbounds[]|select(.tag=="vless-vision-reality")|.server]|join("")' "${ESB_TMP}/t11.json")" \
    "$ESB_TEST_FIX_DOMAIN" "VLESS 节点应指向部署域名" || return 1
  local _t11_pbk_state _t11_pbk_cfg _t11_pbk_link
  _t11_pbk_state="$(state_get .reality.public_key)"
  _t11_pbk_cfg="$(jq -r '[.outbounds[]|select(.tag=="vless-vision-reality")|.tls.reality.public_key]|join("")' "${ESB_TMP}/t11.json")"
  assert_eq "$_t11_pbk_cfg" "$_t11_pbk_state" "TUN 配置里的 REALITY 公钥应与 state 一致" || return 1
  _t11_pbk_link="$(sub_links_text 2>/dev/null | grep -o 'pbk=[^&#]*' | head -1 | cut -d= -f2)"
  assert_eq "$_t11_pbk_link" "$_t11_pbk_state" "分享链接里的 REALITY 公钥应与配置一致（防止链接漂移）" || return 1
  assert_eq "$(jq -r '[.outbounds[]|select(.tag=="hysteria2")|(.server_ports//[])|join(",")]|join("")' "${ESB_TMP}/t11.json")" \
    "20000:30000" "hysteria2 端口跳跃应为冒号形式" || return 1
  assert_contains "$(jq -r '[.outbounds[]|select(.tag=="vmess-ws-tls")|.transport.path]|join("")' "${ESB_TMP}/t11.json")" \
    "/vmess" "VMess 节点应带 WS 路径" || return 1

  # 策略组引用必须覆盖全部启用节点
  local _t11_groups
  _t11_groups="$(jq -r '[.outbounds[]|select(.tag=="proxy")|.outbounds[]]|join(",")' "${ESB_TMP}/t11.json")"
  local _t11_p
  for _t11_p in $(esb_proto_keys); do
    assert_contains "$_t11_groups" "$_t11_p" "proxy 策略组应包含 $_t11_p" || return 1
  done
  return 0
}

# 12. 只启用部分协议时：未启用节点必须从 outbounds 与策略组摘干净，且 stdout 必须是纯 JSON
#     （真机缺陷回归：日志混入 stdout 会把 singbox.json 写坏）
test_12_tun_partial_protocols() {
  _links_fixture || return 1
  _links_seed_tun_template || { skip_test "仓库里没有 Templates/tun-fakeip.json"; return 77; }
  local _t12_p
  for _t12_p in $(esb_proto_keys); do
    case "$_t12_p" in
      anytls) state_proto_set_field "$_t12_p" .enabled true ;;
      *)      state_proto_set_field "$_t12_p" .enabled false ;;
    esac
  done

  # 打开调试输出（日志最多的情形），确保它们全部走 stderr
  local _t12_out
  _t12_out="$(ESB_DEBUG=1 sub_singbox_tun_json 2>"${ESB_TMP}/t12.err")" || { _harness_fail "生成失败"; return 1; }
  printf '%s' "$_t12_out" >"${ESB_TMP}/t12.json"
  assert_json "${ESB_TMP}/t12.json" '.outbounds|length' '4' "stdout 应是合法 JSON（日志不得污染数据通道）" || return 1

  assert_eq "$(jq -r '[.outbounds[]|.tag]|join(",")' "${ESB_TMP}/t12.json")" \
    "anytls,proxy,auto,direct" "只启用 anytls 时应只保留该节点与策略组" || return 1
  local _t12_groups _t12_offp
  _t12_groups="$(jq -r '[.outbounds[]|select(.tag=="proxy" or .tag=="auto")|.outbounds[]]|unique|join(",")' "${ESB_TMP}/t12.json")"
  assert_contains "$_t12_groups" "anytls" "策略组应包含已启用的 anytls" || return 1
  for _t12_offp in vless-vision-reality vmess-ws-tls hysteria2 tuic; do
    assert_not_contains "$_t12_groups" "$_t12_offp" "策略组不应残留未启用节点 $_t12_offp" || return 1
    assert_not_contains "$(jq -r '[.outbounds[]|.tag]|join(",")' "${ESB_TMP}/t12.json")" "$_t12_offp" \
      "outbounds 不应残留未启用节点 $_t12_offp" || return 1
  done
  assert_eq "$(jq -r '.route.final' "${ESB_TMP}/t12.json")" "proxy" "兜底出站仍应是 proxy 组" || return 1
  return 0
}

# 13. mihomo.yaml / singbox-mixed.json 与 mihomo 模板同构
test_13_mihomo_template_shape() {
  _links_fixture || return 1
  local _t13_yaml
  _t13_yaml="$(ESB_DEBUG=1 sub_mihomo_yaml 2>"${ESB_TMP}/t13.err")" || { _harness_fail "生成 mihomo 配置失败"; return 1; }
  printf '%s\n' "$_t13_yaml" >"${ESB_TMP}/t13.yaml"
  local _t13_domain="$ESB_TEST_FIX_DOMAIN"

  assert_contains "$_t13_yaml" "enhanced-mode: fake-ip" "应使用模板的 fake-ip 模式" || return 1
  assert_contains "$_t13_yaml" "fake-ip-range: 198.18.0.1/16" "应保留模板 fake-ip 网段" || return 1
  assert_contains "$_t13_yaml" "unified-delay: true" "应保留模板 unified-delay" || return 1
  assert_contains "$_t13_yaml" "sniffer:" "应保留模板 sniffer 段" || return 1
  assert_contains "$_t13_yaml" "proxy-server-nameserver:" "应保留模板 proxy-server-nameserver" || return 1
  assert_contains "$_t13_yaml" "name: 负载均衡" "应有模板的负载均衡组" || return 1
  assert_contains "$_t13_yaml" "name: 自动选择" "应有模板的自动选择组" || return 1
  assert_contains "$_t13_yaml" "🌍选择代理节点" "应有模板的手动选择组" || return 1
  assert_contains "$_t13_yaml" "strategy: round-robin" "负载均衡应使用 round-robin" || return 1
  assert_contains "$_t13_yaml" "tolerance: 50" "自动选择应使用模板的 tolerance 50" || return 1
  assert_contains "$_t13_yaml" "- GEOSITE,CN,DIRECT" "应保留模板 GEOSITE 规则" || return 1
  assert_contains "$_t13_yaml" "- MATCH,🌍选择代理节点" "应保留模板兜底规则" || return 1
  assert_contains "$_t13_yaml" "- DIRECT" "手动选择组应含 DIRECT" || return 1

  # 节点命名与关键字段
  assert_contains "$_t13_yaml" "name: vless-reality-vision-${_t13_domain}" "VLESS 节点命名应follow模板" || return 1
  assert_contains "$_t13_yaml" "reality-opts:" "VLESS 应带 reality-opts" || return 1
  assert_contains "$_t13_yaml" "client-fingerprint: chrome" "应带 chrome 指纹" || return 1
  assert_contains "$_t13_yaml" "name: vmess-ws-tls-${_t13_domain}" "VMess 节点命名应为 vmess-ws-tls（带 TLS）" || return 1
  assert_contains "$_t13_yaml" "name: hysteria2-${_t13_domain}" "Hysteria2 节点命名应follow模板" || return 1
  assert_contains "$_t13_yaml" "ports: 20000-30000" "开启跳跃时 hysteria2 应写 ports 区间（mihomo 用连字符）" || return 1
  assert_contains "$_t13_yaml" "name: tuic5-${_t13_domain}" "TUIC 节点命名应follow模板" || return 1

  # 精简配置与模板配置必须是两份不同的产物
  local _t13_mixed
  _t13_mixed="$(sub_singbox_json)"
  printf '%s' "$_t13_mixed" >"${ESB_TMP}/t13-mixed.json"
  assert_json "${ESB_TMP}/t13-mixed.json" '.inbounds[0].type' 'mixed' "精简配置应是合法 JSON" || return 1
  assert_eq "$(jq -r '.inbounds[0].type' "${ESB_TMP}/t13-mixed.json")" "mixed" "精简配置应使用 mixed 入站" || return 1
  assert_eq "$(jq -r '.route' "${ESB_TMP}/t13-mixed.json")" "null" "精简配置不应含分流规则" || return 1
  return 0
}

# 14. 证书来源决定客户端是否跳过校验：自签=跳过，域名证书=不跳过
test_14_insecure_follows_cert_source() {
  _links_fixture || return 1

  # (a) 域名证书（acme）：不得出现 insecure=1 / skip-cert-verify: true
  state_set_str ".cert.source" "acme:webroot" || return 1
  local _t14_links _t14_yaml _t14_p
  _t14_links="$(sub_links_text 2>/dev/null)"
  assert_contains "$_t14_links" "hysteria2://" "应生成 hysteria2 链接" || return 1
  assert_contains "$_t14_links" "insecure=0" "域名证书时链接不应要求跳过校验" || return 1
  assert_not_contains "$_t14_links" "insecure=1" "域名证书时不应出现 insecure=1" || return 1
  _t14_yaml="$(sub_mihomo_yaml 2>/dev/null)"
  assert_contains "$_t14_yaml" "skip-cert-verify: false" "域名证书时 mihomo 不应跳过校验" || return 1
  for _t14_p in vmess-ws-tls anytls hysteria2 tuic; do
    assert_eq "$(render_outbound "$_t14_p" | jq -r '.tls.insecure')" "false" \
      "$_t14_p 在域名证书下 tls.insecure 应为 false" || return 1
  done

  # (b) 自签证书：三处产物都必须要求跳过校验
  state_set_str ".cert.source" "self-signed" || return 1
  _t14_links="$(sub_links_text 2>/dev/null)"
  assert_contains "$_t14_links" "insecure=1" "自签证书时 hysteria2/anytls 链接应 insecure=1" || return 1
  assert_contains "$_t14_links" "allow_insecure=1" "自签证书时 TUIC 链接应 allow_insecure=1" || return 1
  _t14_yaml="$(sub_mihomo_yaml 2>/dev/null)"
  assert_contains "$_t14_yaml" "skip-cert-verify: true" "自签证书时 mihomo 应跳过校验" || return 1
  for _t14_p in vmess-ws-tls anytls hysteria2 tuic; do
    assert_eq "$(render_outbound "$_t14_p" | jq -r '.tls.insecure')" "true" \
      "$_t14_p 在自签证书下 tls.insecure 应为 true" || return 1
  done
  # REALITY 免证书，永远不应该带 insecure
  assert_eq "$(render_outbound vless-vision-reality | jq -r '.tls.insecure')" "null" \
    "REALITY 节点不应带 insecure（它不使用证书）" || return 1

  # (c) cert_is_self_signed 判定本身
  assert_ok "自签来源应判定为自签" cert_is_self_signed || return 1
  state_set_str ".cert.source" "acme:webroot" || return 1
  assert_fail "acme 来源不应判定为自签" cert_is_self_signed || return 1
  return 0
}

# 15. 按协议证书模式：每个协议独立解析自己的证书，互不影响
test_15_per_protocol_cert_mode() {
  _links_fixture || return 1
  # 全局用域名证书（acme），只把 anytls 单独切到自签
  state_set_str ".cert.source" "acme:webroot" || return 1
  proto_cert_mode_set anytls self-signed || return 1
  proto_cert_mode_set hysteria2 auto || return 1

  assert_eq "$(proto_cert_mode anytls)" "self-signed" "anytls 应解析为自签" || return 1
  assert_eq "$(proto_cert_mode hysteria2)" "acme" "hysteria2 跟随全局应为域名证书" || return 1
  assert_eq "$(proto_insecure_flag anytls)" "1" "anytls 链接应跳过校验" || return 1
  assert_eq "$(proto_insecure_flag hysteria2)" "0" "hysteria2 链接不应跳过校验" || return 1

  # 客户端 outbound
  assert_eq "$(render_outbound anytls | jq -r '.tls.insecure')" "true" "anytls outbound tls.insecure=true" || return 1
  assert_eq "$(render_outbound hysteria2 | jq -r '.tls.insecure')" "false" "hysteria2 outbound tls.insecure=false" || return 1

  # mihomo 也必须逐协议
  local _t15_yaml
  _t15_yaml="$(sub_mihomo_yaml 2>/dev/null)"
  assert_contains "$_t15_yaml" "skip-cert-verify: true" "anytls 在 mihomo 里应跳过校验" || return 1

  # 服务端：anytls 指向独立的自签文件，hysteria2 指向已应用证书
  render_config >/dev/null 2>&1 || { _harness_fail "服务端配置渲染失败"; return 1; }
  local _t15_anytls_crt _t15_hy2_crt _t15_self_crt
  _t15_anytls_crt="$(jq -r '.inbounds[]|select(.tag=="anytls")|.tls.certificate_path' "$ESB_CONFIG")"
  _t15_hy2_crt="$(jq -r '.inbounds[]|select(.tag=="hysteria2")|.tls.certificate_path' "$ESB_CONFIG")"
  _t15_self_crt="$(cert_selfsigned_paths "$ESB_TEST_FIX_DOMAIN" | cut -f1)"
  assert_eq "$_t15_anytls_crt" "$_t15_self_crt" "anytls 服务端应使用自签证书文件" || return 1
  assert_ne "$_t15_hy2_crt" "$_t15_self_crt" "hysteria2 服务端不应使用自签证书文件" || return 1
  assert_ok "自签证书文件确实存在" test -f "$_t15_self_crt" || return 1
  assert_ok "自签证书与域名证书文件不同名（互不覆盖）" test "$_t15_self_crt" != "${ESB_CERT_DIR}/${ESB_TEST_FIX_DOMAIN}.crt" || return 1
  return 0
}

# 16. VMess 的 TLS 开关：关闭后服务端/客户端/链接/订阅都不带 TLS
test_16_vmess_tls_toggle() {
  _links_fixture || return 1
  state_set_str ".cert.source" "acme:webroot" || return 1
  proto_tls_set vmess-ws-tls false || return 1

  assert_eq "$(proto_tls_enabled vmess-ws-tls)" "false" "应读取到 TLS 已关闭" || return 1
  assert_eq "$(render_outbound vmess-ws-tls | jq -r '.tls')" "null" "关闭 TLS 客户端不应带 tls 段" || return 1
  assert_eq "$(render_outbound vmess-ws-tls | jq -r '.transport.max_early_data')" "null" \
    "关闭 TLS 不应带 WS early data" || return 1

  render_config >/dev/null 2>&1 || return 1
  assert_eq "$(jq -r '.inbounds[]|select(.tag=="vmess-ws-tls")|has("tls")' "$ESB_CONFIG")" "false" \
    "关闭 TLS 服务端 inbound 不应带 tls 段" || return 1

  local _t16_link
  _t16_link="$(link_vmess)"
  printf '%s' "${_t16_link#vmess://}" | base64 -d >"${ESB_TMP}/t16.json" 2>/dev/null
  assert_json "${ESB_TMP}/t16.json" '.tls' '' "VMess 链接关闭 TLS 后 tls 字段应为空" || return 1
  local _t16_ps
  _t16_ps="$(sub_links_text 2>/dev/null | grep -o 'vmess://[A-Za-z0-9+/=]*' | head -1 | sed 's|^vmess://||' | base64 -d 2>/dev/null | jq -r '.ps')"
  assert_contains "$_t16_ps" "EasySB-VMess-WS-" "关闭 TLS 后节点名不应再带 TLS" || return 1
  assert_not_contains "$_t16_ps" "WS-TLS" "关闭 TLS 后节点名里不应出现 TLS" || return 1

  local _t16_yaml
  _t16_yaml="$(sub_mihomo_yaml 2>/dev/null)"
  assert_contains "$_t16_yaml" "tls: false" "mihomo 关闭 TLS 后应写 tls: false" || return 1

  # 再切回来（域名证书）
  proto_tls_set vmess-ws-tls true || return 1
  proto_cert_mode_set vmess-ws-tls auto || return 1
  assert_eq "$(render_outbound vmess-ws-tls | jq -r '.tls.enabled')" "true" "重新开启 TLS 后应有 tls 段" || return 1
  render_config >/dev/null 2>&1 || return 1
  assert_eq "$(jq -r '.inbounds[]|select(.tag=="vmess-ws-tls")|.tls.enabled' "$ESB_CONFIG")" "true" \
    "服务端重新开启 TLS" || return 1
  return 0
}

# 17. 命名规则：VMess 用域名证书才叫 vmess-ws-tls，自签证书 / 关闭 TLS 都叫 vmess-ws
test_17_vmess_naming_follows_cert() {
  _links_fixture || return 1

  # (a) 域名证书 -> VMess-WS-TLS
  proto_tls_set vmess-ws-tls true || return 1
  proto_cert_mode_set vmess-ws-tls acme || return 1
  assert_eq "$(vmess_display_name)" "VMess-WS-TLS" "域名证书应显示 VMess-WS-TLS" || return 1
  assert_contains "$(link_vmess | sed 's|^vmess://||' | base64 -d 2>/dev/null | jq -r '.ps' 2>/dev/null)" \
    "EasySB-VMess-WS-TLS-" "域名证书时链接节点名应带 TLS" || return 1
  assert_contains "$(sub_mihomo_yaml 2>/dev/null)" "name: vmess-ws-tls-${ESB_TEST_FIX_DOMAIN}" \
    "域名证书时 mihomo 节点名应为 vmess-ws-tls-<域名>" || return 1

  # (b) 自签证书 -> VMess-WS（TLS 依然开启，但客户端跳过校验）
  proto_cert_mode_set vmess-ws-tls self-signed || return 1
  assert_eq "$(vmess_display_name)" "VMess-WS" "自签证书应显示 VMess-WS" || return 1
  assert_eq "$(render_outbound vmess-ws-tls | jq -r '.tls.enabled')" "true" "自签时仍然启用 TLS" || return 1
  assert_eq "$(render_outbound vmess-ws-tls | jq -r '.tls.insecure')" "true" "自签时客户端跳过校验" || return 1
  assert_contains "$(link_vmess | sed 's|^vmess://||' | base64 -d 2>/dev/null | jq -r '.ps' 2>/dev/null)" \
    "EasySB-VMess-WS-" "自签时链接节点名为 VMess-WS" || return 1
  assert_not_contains "$(link_vmess | sed 's|^vmess://||' | base64 -d 2>/dev/null | jq -r '.ps' 2>/dev/null)" \
    "WS-TLS" "自签时节点名不应出现 TLS" || return 1
  assert_contains "$(sub_mihomo_yaml 2>/dev/null)" "name: vmess-ws-${ESB_TEST_FIX_DOMAIN}" \
    "自签时 mihomo 节点名应为 vmess-ws-<域名>" || return 1
  assert_contains "$(sub_mihomo_yaml 2>/dev/null)" "tls: true" "自签时依然写 tls: true" || return 1

  # (c) 关闭 TLS -> VMess-WS，且没有 tls 段
  proto_tls_set vmess-ws-tls false || return 1
  assert_eq "$(vmess_display_name)" "VMess-WS" "关闭 TLS 应显示 VMess-WS" || return 1
  assert_eq "$(render_outbound vmess-ws-tls | jq -r '.tls')" "null" "关闭 TLS 不应有 tls 段" || return 1
  assert_contains "$(sub_mihomo_yaml 2>/dev/null)" "name: vmess-ws-${ESB_TEST_FIX_DOMAIN}" \
    "关闭 TLS 时 mihomo 节点名为 vmess-ws-<域名>" || return 1
  return 0
}
