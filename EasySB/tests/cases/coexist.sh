# 用例：与其它 sing-box 部署的冲突检测（unit / 配置归属判定、拒绝覆盖、接管开关）
# 运行： bash tests/run_tests.sh --case test_1_foreign_unit_refused
# shellcheck shell=bash

TESTS="test_1_foreign_unit_refused test_2_own_unit_ok test_3_takeover_backs_up_foreign \
test_4_apply_change_refused_on_foreign test_5_render_marks_owned test_6_unit_remove_skips_foreign \
test_7_report_detects"

_coexist_unit_file() { printf '%s\n' "${ESB_UNIT_DIR}/sing-box.service"; }

# 伪造一个"别的脚本装好的" unit（没有 EasySB 标记）
_coexist_seed_foreign_unit() {
  mkdir -p "$ESB_UNIT_DIR" || return 1
  cat >"$(_coexist_unit_file)" <<'EOF'
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  return 0
}

# 伪造一份"别的脚本写的"配置
_coexist_seed_foreign_config() {
  mkdir -p "$ESB_CONF_DIR" || return 1
  printf '{"log":{"level":"warn"},"inbounds":[],"outbounds":[]}\n' >"$ESB_CONFIG" || return 1
  rm -f "${ESB_CONF_DIR}/.easysb-managed" 2>/dev/null || true
  return 0
}

# env 只能跑外部命令，接管开关这样包一层才能在用例里调用
_coexist_takeover_unit_install() { ESB_TAKEOVER=1 ESB_ASSUME_YES=1 unit_install; }
_coexist_takeover_apply_change() { local _c_tac_desc="$1"; ESB_TAKEOVER=1 ESB_ASSUME_YES=1 apply_change "$_c_tac_desc"; }

_coexist_seed_ours() {
  state_init >/dev/null 2>&1 || return 1
  sandbox_seed_state >/dev/null 2>&1 || true
  sandbox_seed_cert "$ESB_TEST_FIX_DOMAIN" >/dev/null 2>&1 || true
  sandbox_proto_on anytls >/dev/null 2>&1 || true
  return 0
}

# 1. 别人的 unit：必须拒绝覆盖，且文件内容原样保留
test_1_foreign_unit_refused() {
  _coexist_seed_ours || return 1
  _coexist_seed_foreign_unit || return 1
  local _t1_before _t1_after
  _t1_before="$(cat "$(_coexist_unit_file)")"
  assert_fail "外部 unit 存在时应拒绝安装 EasySB 的 unit" unit_install || return 1
  _t1_after="$(cat "$(_coexist_unit_file)")"
  assert_eq "$_t1_after" "$_t1_before" "拒绝后外部 unit 必须原样保留" || return 1
  assert_not_contains "$_t1_after" "$ESB_UNIT_MARKER" "外部 unit 不应被打上 EasySB 标记" || return 1
  assert_eq "$(unit_is_easysb "$(_coexist_unit_file)" && echo yes || echo no)" "no" \
    "unit_is_easysb 应判定为非本工具所有" || return 1
  return 0
}

# 2. 没有 unit 时正常安装，并写入标记；再次安装幂等
test_2_own_unit_ok() {
  _coexist_seed_ours || return 1
  rm -f "$(_coexist_unit_file)" 2>/dev/null || true
  assert_ok "空环境下应能安装 EasySB 的 unit" unit_install || return 1
  assert_ok "unit_is_easysb 应认出自己的 unit" unit_is_easysb "$(_coexist_unit_file)" || return 1
  assert_contains "$(cat "$(_coexist_unit_file)")" "$ESB_UNIT_MARKER" "unit 里应含 EasySB 标记" || return 1
  assert_contains "$(cat "$(_coexist_unit_file)")" "$ESB_BIN" "unit 的 ExecStart 应指向 EasySB 的内核路径" || return 1
  assert_ok "再次安装应幂等成功" unit_install || return 1
  return 0
}

# 3. ESB_TAKEOVER=1：允许接管，但必须先备份外部 unit
test_3_takeover_backs_up_foreign() {
  _coexist_seed_ours || return 1
  _coexist_seed_foreign_unit || return 1
  mkdir -p "$ESB_BACKUP_DIR" || return 1
  assert_ok "ESB_TAKEOVER=1 时应允许接管" _coexist_takeover_unit_install || return 1
  assert_ok "接管后 unit 应是我们自己的" unit_is_easysb "$(_coexist_unit_file)" || return 1
  local _t3_bak
  _t3_bak="$(find "$ESB_BACKUP_DIR" -name 'sing-box.service.foreign.*' 2>/dev/null | head -1)"
  assert_file "$_t3_bak" "接管前必须把外部 unit 备份到备份目录" || return 1
  assert_contains "$(cat "$_t3_bak")" "/etc/s-box/sing-box" "备份内容应是外部 unit 原文" || return 1
  return 0
}

# 4. 外部部署存在时，apply_change 必须直接停手（不改文件、不重启服务）
test_4_apply_change_refused_on_foreign() {
  _coexist_seed_ours || return 1
  _coexist_seed_foreign_unit || return 1
  _coexist_seed_foreign_config || return 1
  local _t4_before _t4_after
  _t4_before="$(cat "$ESB_CONFIG")"
  assert_fail "外部部署存在时 apply_change 应中止" apply_change "测试变更" || return 1
  _t4_after="$(cat "$ESB_CONFIG")"
  assert_eq "$_t4_after" "$_t4_before" "中止后不应改动对方的配置" || return 1
  assert_ok "ESB_TAKEOVER=1 时才允许继续" _coexist_takeover_apply_change "接管测试" || return 1
  return 0
}

# 5. EasySB 自己写配置时会留下归属标记，之后不再被判为外部部署
test_5_render_marks_owned() {
  _coexist_seed_ours || return 1
  rm -f "${ESB_CONF_DIR}/.easysb-managed" 2>/dev/null || true
  assert_ok "渲染配置应成功" render_config || return 1
  assert_file "${ESB_CONF_DIR}/.easysb-managed" "渲染后应写入归属标记文件" || return 1
  assert_not_contains "$(cat "${ESB_CONF_DIR}/.easysb-managed")" "foreign" "标记内容应是 EasySB-MANAGED" || return 1
  assert_contains "$(cat "${ESB_CONF_DIR}/.easysb-managed")" "EasySB-MANAGED" "标记内容应是 EasySB-MANAGED" || return 1
  assert_fail "自己写的配置不应被判为外部部署" foreign_singbox_detected_quiet || return 1
  return 0
}

# 6. 卸载只删自己的 unit，别人的 unit 不碰
test_6_unit_remove_skips_foreign() {
  _coexist_seed_ours || return 1
  _coexist_seed_foreign_unit || return 1
  unit_remove >/dev/null 2>&1 || true
  assert_file "$(_coexist_unit_file)" "卸载时不应删除别人的 unit" || return 1
  # 自己的 unit 则应被删除
  _coexist_takeover_unit_install >/dev/null 2>&1 || return 1
  unit_remove >/dev/null 2>&1 || true
  assert_fail "自己的 unit 应被卸载删除" test -f "$(_coexist_unit_file)" || return 1
  return 0
}

# 7. 报告函数能指出对方的 ExecStart，便于用户判断
test_7_report_detects() {
  _coexist_seed_ours || return 1
  _coexist_seed_foreign_unit || return 1
  _coexist_seed_foreign_config || return 1
  assert_ok "应检测到外部部署" foreign_singbox_detected_quiet || return 1
  local _t7_out
  _t7_out="$(foreign_singbox_report 2>&1)"
  assert_contains "$_t7_out" "/etc/s-box/sing-box" "报告应指出对方的 ExecStart" || return 1
  assert_contains "$_t7_out" "ESB_TAKEOVER" "报告应给出接管办法" || return 1
  # 清掉外部痕迹后不应再误报
  rm -f "$(_coexist_unit_file)" "$ESB_CONFIG" 2>/dev/null || true
  assert_fail "无外部部署时不应误报" foreign_singbox_detected_quiet || return 1
  return 0
}
