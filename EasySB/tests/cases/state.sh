#!/usr/bin/env bash
# =============================================================================
# 用例：20-state.sh（状态模型 / 备份回滚 / 变更路径）
#   由 tests/run_tests.sh source（lib/*.sh 与 tests/lib/harness.sh 已加载）
# =============================================================================

TESTS="
  test_state_init_idempotent
  test_state_init_schema_and_proto_keys
  test_state_file_mode_600
  test_state_set_roundtrip
  test_state_set_rejects_invalid_json
  test_state_get_missing_and_has
  test_proto_enabled_list_default_empty
  test_proto_enabled_list_order
  test_state_proto_set_field_isolated
  test_secret_roundtrip
  test_state_backup_restore_byte_identical
  test_apply_change_rollback_on_render_failure
"

# ---------------------------------------------------------------------------
# 用例：state_init 幂等，且不覆盖已有内容
# ---------------------------------------------------------------------------
test_state_init_idempotent() {
  requires_jq || return 77
  sandbox_reset || return 1
  state_init || return 1
  local _t_first _t_again
  _t_first="$(sha256_of "$ESB_STATE")"
  assert_ne "$_t_first" "" "state_init 必须写出 state.json（sha256 不应为空）" || return 1
  state_init || return 1
  _t_again="$(sha256_of "$ESB_STATE")"
  assert_eq "$_t_again" "$_t_first" "state_init 必须幂等（重复执行不得改写内容）" || return 1
  state_set_str .domain keep.example.com || return 1
  state_init || return 1
  assert_eq "$(state_get .domain)" "keep.example.com" "state_init 不得覆盖已有状态" || return 1
  assert_ok "state_load 应能读回刚写出的状态" state_load
  return 0
}

# ---------------------------------------------------------------------------
# 用例：state.json 权限 600（docs/STATE.md）
# ---------------------------------------------------------------------------
test_state_file_mode_600() {
  requires_jq || return 77
  sandbox_reset || return 1
  assert_file_mode "$ESB_STATE" "600" "state.json 必须是 600（含密钥，不能让同机其它用户读到）" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 用例：默认 state.json 的结构（schema=1，5 个固定协议键）
# ---------------------------------------------------------------------------
test_state_init_schema_and_proto_keys() {
  requires_jq || return 77
  sandbox_reset || return 1
  assert_file "$ESB_STATE" "state_init 必须创建 $ESB_STATE" || return 1
  assert_json "$ESB_STATE" '.schema' '1' "schema 必须是 1（docs/STATE.md）" || return 1
  assert_json "$ESB_STATE" '.domain' '' "默认 domain 应为空" || return 1
  assert_json "$ESB_STATE" '.protocols|keys|length' '5' "必须恰好 5 个协议键" || return 1
  assert_json "$ESB_STATE" '.protocols|keys|join(",")' 'anytls,hysteria2,tuic,vless-vision-reality,vmess-ws-tls' \
    "协议键必须与 INTERFACES §4 的固定常量一致" || return 1
  # 协议键集合必须与 esb_proto_keys 完全一致（不能只在一边改）
  assert_eq "$(esb_proto_keys | tr ' ' '\n' | sort | tr '\n' ',')" \
            "anytls,hysteria2,tuic,vless-vision-reality,vmess-ws-tls," \
    "esb_proto_keys 与 state.json 的协议键集合必须一致" || return 1
  # 默认端口（docs/STATE.md 端口表）
  assert_json "$ESB_STATE" '.protocols["vless-vision-reality"].port' '443' "vless 默认端口 443" || return 1
  assert_json "$ESB_STATE" '.protocols["vmess-ws-tls"].port' '8443' "vmess 默认端口 8443" || return 1
  assert_json "$ESB_STATE" '.protocols.anytls.port' '2096' "anytls 默认端口 2096" || return 1
  assert_json "$ESB_STATE" '.protocols.hysteria2.port' '443' "hysteria2 默认端口 443" || return 1
  assert_json "$ESB_STATE" '.protocols.tuic.port' '8443' "tuic 默认端口 8443" || return 1
  assert_json "$ESB_STATE" '.protocols["vmess-ws-tls"].path' '/vmess' "vmess 默认 path /vmess" || return 1
  assert_json "$ESB_STATE" '.protocols.tuic.congestion_control' 'bbr' "tuic 默认拥塞控制 bbr" || return 1
  assert_json "$ESB_STATE" '[.protocols[].enabled]|unique|join(",")' 'false' "默认不启用任何协议" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 用例：state_set / state_set_str 往返（含 JSON 类型与特殊字符）
# ---------------------------------------------------------------------------
test_state_set_roundtrip() {
  requires_jq || return 77
  sandbox_reset || return 1
  state_set_str .domain node.example.com || return 1
  assert_eq "$(state_get .domain)" "node.example.com" "state_set_str / state_get 往返" || return 1
  state_set .web.http_port 8080 || return 1
  assert_eq "$(state_get .web.http_port)" "8080" "数字字段往返" || return 1
  assert_json "$ESB_STATE" '.web.http_port|type' 'number' "state_set 必须按 JSON 解析（数字保持 number）" || return 1
  state_set .web.enabled true || return 1
  assert_json "$ESB_STATE" '.web.enabled|type' 'boolean' "state_set 应写入布尔值" || return 1
  # false 不能被 state_get 当成“空值”吞掉（协议开关全是布尔值）
  state_set .web.tls false || return 1
  assert_eq "$(state_get .web.tls)" "false" "state_get 必须能读出 false（不得被 // empty 吞掉）" || return 1
  # 引号/反斜杠/$ 必须逐字节保留（state_set_str 用 --arg 传值）
  state_set_str .email 'a"b\c$d@example.com' || return 1
  assert_eq "$(state_get .email)" 'a"b\c$d@example.com' "state_set_str 必须安全处理引号/反斜杠/\$" || return 1
  assert_json "$ESB_STATE" '.email' 'a"b\c$d@example.com' "JSON 里的值也必须一致（转义正确）" || return 1
  return 0
}

test_state_set_rejects_invalid_json() {
  requires_jq || return 77
  sandbox_reset || return 1
  state_set_str .domain "keep.example.com" || return 1
  assert_fail "state_set 必须拒绝非法 JSON 值" state_set .domain 'not-json' || return 1
  assert_eq "$(state_get .domain)" "keep.example.com" "非法输入不得改动状态文件" || return 1
  assert_ok "state_load 应能解析写入后的状态文件" state_load
  return 0
}

test_state_get_missing_and_has() {
  requires_jq || return 77
  sandbox_reset || return 1
  assert_eq "$(state_get .nope)" "" "不存在的路径应输出空" || return 1
  assert_eq "$(state_get .nope.deeper)" "" "不存在的深层路径应输出空（不得报错）" || return 1
  assert_fail "state_has 对不存在的路径应返回非 0" state_has .nope
  state_set_str .domain node.example.com || return 1
  assert_ok "state_has 对存在的路径应返回 0" state_has .domain
  return 0
}

# ---------------------------------------------------------------------------
# 用例：启用列表
# ---------------------------------------------------------------------------
test_proto_enabled_list_default_empty() {
  requires_jq || return 77
  sandbox_reset || return 1
  assert_eq "$(proto_enabled_list)" "" "默认没有任何启用协议" || return 1
  local _t_p
  for _t_p in $(esb_proto_keys); do
    assert_fail "proto_enabled $_t_p 默认应为未启用" proto_enabled "$_t_p" || return 1
  done
  assert_eq "$(proto_port anytls)" "2096" "proto_port 应输出 state 里的端口" || return 1
  return 0
}

test_proto_enabled_list_order() {
  requires_jq || return 77
  sandbox_reset || return 1
  # 故意乱序启用：输出必须仍按 esb_proto_keys 的固定顺序
  sandbox_proto_on tuic || return 1
  sandbox_proto_on vless-vision-reality || return 1
  sandbox_proto_on anytls || return 1
  assert_eq "$(proto_enabled_list)" "vless-vision-reality anytls tuic" \
    "启用列表必须按 esb_proto_keys 顺序输出（与勾选顺序无关）" || return 1
  assert_ok "proto_enabled 对已启用协议应返回 0" proto_enabled tuic
  assert_fail "proto_enabled 对未启用协议应返回非 0" proto_enabled vmess-ws-tls
  # 关闭后必须立刻从列表消失
  sandbox_proto_off anytls || return 1
  assert_eq "$(proto_enabled_list)" "vless-vision-reality tuic" "关闭后应从列表移除" || return 1
  return 0
}

test_state_proto_set_field_isolated() {
  requires_jq || return 77
  sandbox_reset || return 1
  local _t_other_before _t_early_before
  _t_other_before="$(state_get_raw '.protocols["vless-vision-reality"]|tojson')"
  _t_early_before="$(state_get '.protocols["vmess-ws-tls"].early_data')"
  assert_eq "$_t_early_before" "true" "默认 early_data 应为 true" || return 1
  state_proto_set_field vmess-ws-tls .path '"/custom-ws"' || return 1
  assert_eq "$(state_get '.protocols["vmess-ws-tls"].path')" "/custom-ws" "path 应被更新" || return 1
  assert_eq "$(state_get '.protocols["vmess-ws-tls"].early_data')" "$_t_early_before" \
    "同协议的其它字段（early_data）不得被顺手改掉" || return 1
  assert_eq "$(state_get '.protocols["vmess-ws-tls"].port')" "8443" "同协议的端口不得被改掉" || return 1
  assert_eq "$(state_get_raw '.protocols["vless-vision-reality"]|tojson')" "$_t_other_before" \
    "其它协议不得被改动" || return 1
  assert_fail "state_proto_set_field 必须拒绝非 JSON 值" state_proto_set_field vmess-ws-tls .path 'plain-string'
  return 0
}

# ---------------------------------------------------------------------------
# 用例：密钥
# ---------------------------------------------------------------------------
test_secret_roundtrip() {
  requires_jq || return 77
  sandbox_reset || return 1
  assert_eq "$(secret_get tuic_password)" "" "默认密钥为空" || return 1
  secret_set tuic_password 'p@ss/w+1 "x"\y' || return 1
  assert_eq "$(secret_get tuic_password)" 'p@ss/w+1 "x"\y' "密钥往返必须逐字节一致（含引号/反斜杠）" || return 1
  assert_json "$ESB_STATE" '.secrets.tuic_password|type' 'string' "密钥必须以字符串存储" || return 1
  secret_set vless_uuid '11111111-2222-4333-8444-555555555555' || return 1
  assert_eq "$(secret_get vless_uuid)" '11111111-2222-4333-8444-555555555555' "uuid 往返" || return 1
  # 不得把别的密钥覆盖掉
  assert_eq "$(secret_get tuic_password)" 'p@ss/w+1 "x"\y' "写一个密钥不得影响另一个" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 用例：备份 / 回滚必须逐字节还原
# ---------------------------------------------------------------------------
test_state_backup_restore_byte_identical() {
  requires_jq || return 77
  sandbox_reset || return 1
  mkdir -p "$ESB_CONF_DIR" || return 1
  printf '{\n  "log": {"level": "warn"},\n  "inbounds": []\n}\n' >"$ESB_CONFIG" || return 1
  state_set_str .domain backup.example.com || return 1
  cp -f "$ESB_CONFIG" "$ESB_TEST_WORK/expected_config.json" || return 1
  cp -f "$ESB_STATE" "$ESB_TEST_WORK/expected_state.json" || return 1

  local _t_bdir
  _t_bdir="$(esb_backup "unit-test")" || return 1
  assert_contains "$_t_bdir" "unit-test" "esb_backup 应输出含变更名的备份目录（实得 [$_t_bdir]）" || return 1
  assert_contains "$(esb_backup_list)" "unit-test" "esb_backup_list 应列出该备份" || return 1

  # 破坏现场：改动配置与状态
  printf 'garbage\n' >"$ESB_CONFIG" || return 1
  state_set_str .domain changed.example.com || return 1

  assert_ok "esb_restore_latest 应成功" esb_restore_latest || return 1
  assert_ok "config.json 必须与备份前逐字节一致" cmp -s "$ESB_CONFIG" "$ESB_TEST_WORK/expected_config.json" || return 1
  assert_ok "state.json 必须与备份前逐字节一致" cmp -s "$ESB_STATE" "$ESB_TEST_WORK/expected_state.json" || return 1
  assert_eq "$(state_get .domain)" "backup.example.com" "回滚后域名必须回到备份时的值" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 用例：变更路径失败必须回滚（渲染失败时旧配置原样保留）
# ---------------------------------------------------------------------------
test_apply_change_rollback_on_render_failure() {
  requires_jq || return 77
  sandbox_reset || return 1
  sandbox_seed_state || return 1
  # 启用需要证书的协议，但故意不申请证书 → render_config 必然失败
  sandbox_proto_on vmess-ws-tls || return 1
  mkdir -p "$ESB_CONF_DIR" || return 1
  printf '{"log":{"level":"warn"},"inbounds":[],"outbounds":[]}\n' >"$ESB_CONFIG" || return 1
  cp -f "$ESB_CONFIG" "$ESB_TEST_WORK/prev_config.json" || return 1

  assert_fail "apply_change 在渲染失败时必须返回非 0" apply_change "enable-vmess-without-cert" || return 1
  assert_ok "渲染失败后旧配置必须原样保留（逐字节）" cmp -s "$ESB_CONFIG" "$ESB_TEST_WORK/prev_config.json" || return 1
  assert_eq "$(ls -1 "$ESB_CONF_DIR" | grep -c '\.tmp\.')" "0" "失败时不得残留 .tmp.$$ 半成品" || return 1
  assert_contains "$(esb_backup_list)" "enable-vmess-without-cert" "变更前必须先备份（回滚的前提）" || return 1
  assert_eq "$(state_get .last_change)" "" "变更失败时不得写入 .last_change（没有生效）" || return 1
  return 0
}
