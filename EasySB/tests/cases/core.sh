#!/usr/bin/env bash
# =============================================================================
# 用例：00-core.sh（基础层）
#   校验 / 掩码 / 密钥生成 / 原子写 / 交互（管道驱动）/ 变更门禁
#   由 tests/run_tests.sh source（lib/*.sh 与 tests/lib/harness.sh 已加载）
#   临时文件一律放 $ESB_TMP（沙箱内，由 harness_paths_init 建好）
# =============================================================================

TESTS="
  test_core_validate_domain
  test_core_validate_domain_rejects
  test_core_validate_port
  test_core_validate_port_range
  test_core_validators_return_status
  test_core_mask_secret
  test_core_gen_uuid_v4
  test_core_reality_keypair
  test_core_json_write_atomic_replace
  test_core_json_write_mode
  test_core_sha256_of
  test_core_cmd_exists_and_trim
  test_core_run_gate_records_only
  test_core_ask_yesno_piped
  test_core_ask_yesno_assume_yes
  test_core_ask_multi_forms
  test_core_ask_multi_no_leading_space
"

# ---------------------------------------------------------------------------
# 本文件私有助手（前缀 _core_，避免与其它用例文件/库的内部名字撞车）
# ---------------------------------------------------------------------------
# 在子 shell 里调用函数并把退出码打印成 RC=<n>：
#   函数内部若调用 exit（违反 INTERFACES §0.5），子 shell 会提前结束，RC 行不会出现。
_core_call_rc() {
  ( "$@" ; printf 'RC=%s\n' "$?" ) 2>/dev/null
}

# 只取退出码；拿不到 RC 行时返回 NO-RC（说明函数调用了 exit）
_core_rc_of() {
  local _core_rc_of_out
  _core_rc_of_out="$(_core_call_rc "$@")"
  case "$_core_rc_of_out" in
    *RC=*) printf '%s' "${_core_rc_of_out##*RC=}" ;;
    *)     printf '%s' "NO-RC" ;;
  esac
}

# validate_port_range 的 “规范化值|退出码”
_core_range_out() {
  local _core_range_out_raw _core_range_out_rc _core_range_out_val
  _core_range_out_raw="$(_core_call_rc validate_port_range "${1-}")"
  case "$_core_range_out_raw" in
    *RC=*) _core_range_out_rc="${_core_range_out_raw##*RC=}" ;;
    *)     printf '%s\n' "NO-RC|NO-RC"; return 0 ;;
  esac
  _core_range_out_val="${_core_range_out_raw%$'\n'RC=*}"
  [ "$_core_range_out_val" = "$_core_range_out_raw" ] && _core_range_out_val=""
  printf '%s|%s\n' "$_core_range_out_val" "$_core_range_out_rc"
}

# 正则匹配（给 assert_ok 用：assert_ok msg _core_match '^…$' "$值"）
_core_match() { printf '%s\n' "${2-}" | grep -qE "${1-}"; }

# 子 shell 里跑命令，确认它还能打印 RC（INTERFACES §0.5：只能 return，不能 exit）
_core_has_rc() {
  local _core_has_rc_out
  _core_has_rc_out="$( ( "$@"; printf 'RC=%s\n' "$?" ) 2>/dev/null )"
  case "$_core_has_rc_out" in
    *RC=*) return 0 ;;
    *) printf '子 shell 没有打印 RC（函数内部调用了 exit）：%s\n' "$*"; return 1 ;;
  esac
}

# 管道喂一行给 ask_multi，回显 outvar（用 [[…]] 包住，失败信息里能看出首尾空格）
_core_multi_pipe() {
  local _core_multi_pipe_v=""
  ask_multi _core_multi_pipe_v "$@" >/dev/null 2>&1
  printf '[[%s]]\n' "$_core_multi_pipe_v"
}

# 同上，但回显 trim 后的值（用于断言“选中了哪些项”的语义）
_core_multi_trim() {
  local _core_multi_trim_v=""
  ask_multi _core_multi_trim_v "$@" >/dev/null 2>&1
  trim "$_core_multi_trim_v"
}

# 管道喂一行给 ask_yesno，回显退出码
_core_yesno_pipe() {
  local _core_yesno_pipe_rc=0
  ( unset ESB_ASSUME_YES; printf '%s\n' "${1-}" | ask_yesno "确认" "${2:-n}" ) >/dev/null 2>&1 \
    || _core_yesno_pipe_rc=$?
  printf '%s' "$_core_yesno_pipe_rc"
}

# ---------------------------------------------------------------------------
# 校验函数
# ---------------------------------------------------------------------------
test_core_validate_domain() {
  local _t_d
  for _t_d in node.example.com sub.node.example.com a-b.example.com xn--abc.example.com; do
    assert_eq "$(_core_rc_of validate_domain "$_t_d")" "0" "validate_domain 应接受合法域名 $_t_d" || return 1
  done
  return 0
}

test_core_validate_domain_rejects() {
  local _t_d
  local -a _t_bad=( "" "node" "node..example.com" ".example.com" "example.com." \
                    "-node.example.com" "node-.example.com" "node_example.com" \
                    "node.example.c" "node example.com" "node.example.com/" "@example.com" )
  for _t_d in "${_t_bad[@]}"; do
    assert_ne "$(_core_rc_of validate_domain "$_t_d")" "0" "validate_domain 应拒绝非法域名 [$_t_d]" || return 1
  done
  return 0
}

test_core_validate_port() {
  local _t_p
  for _t_p in 1 443 8443 65535; do
    assert_eq "$(_core_rc_of validate_port "$_t_p")" "0" "validate_port 应接受 $_t_p" || return 1
  done
  for _t_p in 0 65536 655360 abc "" "443a" "-1" " 443" "443 " "44 3"; do
    assert_ne "$(_core_rc_of validate_port "$_t_p")" "0" "validate_port 应拒绝 [$_t_p]" || return 1
  done
  return 0
}

test_core_validate_port_range() {
  # 冒号写法必须规范化成连字符写法（客户端 mport / fw_hop_apply 都用这个形式）
  assert_eq "$(_core_range_out "2080:3000")" "2080-3000|0" "2080:3000 应规范化为 2080-3000" || return 1
  assert_eq "$(_core_range_out "2080-3000")" "2080-3000|0" "2080-3000 应原样通过" || return 1
  assert_eq "$(_core_range_out "1-2")" "1-2|0" "1-2 应通过" || return 1
  # 反向/非法范围必须拒绝，且不输出任何“规范化”结果
  local _t_bad _t_out
  for _t_bad in "3000-2080" "2080" "abc-def" "0-100" "2080-2080" "65536-65537" "-3000" ""; do
    _t_out="$(_core_range_out "$_t_bad")"
    assert_eq "${_t_out%%|*}" "" "非法范围不得输出规范化值：[$_t_bad]（实得 [$_t_out]）" || return 1
    assert_ne "${_t_out##*|}" "0" "validate_port_range 应拒绝 [$_t_bad]（实得 [$_t_out]）" || return 1
  done
  return 0
}

test_core_validators_return_status() {
  # INTERFACES §0.5：UI 能调用的校验函数只能 return，绝不能 exit
  assert_ok "validate_domain 空串必须返回状态而不是 exit" _core_has_rc validate_domain "" || return 1
  assert_ok "validate_domain 连续点必须返回状态而不是 exit" _core_has_rc validate_domain "a..b" || return 1
  assert_ok "validate_domain 合法域名必须返回状态而不是 exit" _core_has_rc validate_domain node.example.com || return 1
  assert_ok "validate_port 非数字必须返回状态而不是 exit" _core_has_rc validate_port abc || return 1
  assert_ok "validate_port 越界必须返回状态而不是 exit" _core_has_rc validate_port 70000 || return 1
  assert_ok "validate_email 非法邮箱必须返回状态而不是 exit" _core_has_rc validate_email not-an-email || return 1
  assert_ok "validate_port_range 反向范围必须返回状态而不是 exit" _core_has_rc validate_port_range 3000-2080 || return 1
  # error() 必须是 return 1，不是 exit
  assert_eq "$( ( error "测试错误" >/dev/null 2>&1; printf 'RC=%s' "$?" ) )" "RC=1" \
    "error 应打印错误并 return 1（不得 exit）" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 掩码 / 密钥
# ---------------------------------------------------------------------------
test_core_mask_secret() {
  local _t_s="abcdWXYZsecret99wxyz" _t_out
  _t_out="$(mask_secret "$_t_s")"
  assert_eq "$_t_out" "abcd********wxyz" "mask_secret 应只留首 4 末 4" || return 1
  assert_not_contains "$_t_out" "WXYZ" "mask_secret 不得泄露密钥中间部分（WXYZ）" || return 1
  assert_not_contains "$_t_out" "secret" "mask_secret 不得泄露密钥中间部分（secret）" || return 1
  assert_eq "${#_t_out}" "16" "掩码长度应为 4+8+4" || return 1
  # 边界：≤8 字符一律全掩码；9 字符开始才是 4+4
  assert_eq "$(mask_secret abc12345)" "********" "8 字符密钥必须完全掩码" || return 1
  assert_not_contains "$(mask_secret abc12345)" "abc1" "≤8 字符密钥不得泄露任何字符" || return 1
  assert_eq "$(mask_secret abcdefghi)" "abcd********fghi" "9 字符密钥按 4+4 掩码" || return 1
  assert_eq "$(mask_secret '')" "********" "空值输出全掩码，不得报错" || return 1
  return 0
}

test_core_gen_uuid_v4() {
  local _t_u1 _t_u2
  _t_u1="$(gen_uuid)"; _t_u2="$(gen_uuid)"
  assert_eq "${#_t_u1}" "36" "gen_uuid 长度应为 36（实得 [$_t_u1]）" || return 1
  assert_ok "gen_uuid 必须是 v4 形状的小写 uuid（实得 [$_t_u1]）" _core_match \
    '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' "$_t_u1" || return 1
  assert_ok "第二次 gen_uuid 也必须是 v4 形状（实得 [$_t_u2]）" _core_match \
    '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' "$_t_u2" || return 1
  assert_ne "$_t_u1" "$_t_u2" "两次 gen_uuid 必须不同" || return 1
  return 0
}

test_core_reality_keypair() {
  local _t_kp1 _t_kp2 _t_p1 _t_q1 _t_p2 _t_q2
  _t_kp1="$(reality_keypair)" || return 1
  assert_eq "$(printf '%s' "$_t_kp1" | awk '{print NF}')" "2" \
    "reality_keypair 必须输出“私钥 公钥”两个字段（实得 [$_t_kp1]）" || return 1
  _t_p1="${_t_kp1%% *}"; _t_q1="${_t_kp1##* }"
  assert_ne "$_t_p1" "$_t_q1" "私钥与公钥必须不同" || return 1
  assert_ok "私钥必须是 base64url（无填充、无换行）（实得 [$_t_p1]）" _core_match '^[A-Za-z0-9_-]{42,44}$' "$_t_p1" || return 1
  assert_ok "公钥必须是 base64url（无填充、无换行）（实得 [$_t_q1]）" _core_match '^[A-Za-z0-9_-]{42,44}$' "$_t_q1" || return 1
  assert_not_contains "$_t_kp1" "=" "REALITY 密钥必须是 RawURLEncoding（不得带 base64 填充）" || return 1
  _t_kp2="$(reality_keypair)" || return 1
  _t_p2="${_t_kp2%% *}"; _t_q2="${_t_kp2##* }"
  assert_ne "$_t_p1" "$_t_p2" "两次调用必须生成不同的私钥（不得复用缓存）" || return 1
  assert_ne "$_t_q1" "$_t_q2" "两次调用必须生成不同的公钥" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 原子写
# ---------------------------------------------------------------------------
test_core_json_write_atomic_replace() {
  local _t_dir="$ESB_TMP/json" _t_f
  mkdir -p "$_t_dir" || return 1
  _t_f="$_t_dir/config.json"
  assert_ok "json_write 应成功写入" json_write "$_t_f" 600 <<<'{"k":"v1"}' || return 1
  assert_file "$_t_f" "json_write 应创建目标文件" || return 1
  assert_eq "$(<"$_t_f")" '{"k":"v1"}' "内容应逐字节写入" || return 1
  # 先写长内容再写短内容：必须整体替换，不得残留旧内容
  printf '{"longer":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' | json_write "$_t_f" 600 || return 1
  printf '{"s":"x"}\n' | json_write "$_t_f" 600 || return 1
  assert_eq "$(<"$_t_f")" '{"s":"x"}' "二次写入必须整体替换（不得残留旧内容）" || return 1
  assert_eq "$(ls -1 "$_t_dir" | grep -c '\.tmp\.')" "0" "不得残留 .tmp.$$ 临时文件" || return 1
  # 目标目录无法创建（父路径是普通文件）时必须是干净的失败
  printf 'blocker\n' >"$_t_dir/blocker" || return 1
  assert_fail "父路径不是目录时 json_write 必须返回非 0" json_write "$_t_dir/blocker/sub.json" 600 <<<'{}' || return 1
  assert_eq "$(<"$_t_dir/blocker")" 'blocker' "失败时不得破坏占用路径的文件" || return 1
  return 0
}

test_core_json_write_mode() {
  local _t_f="$ESB_TMP/json/mode.json"
  mkdir -p "$(dirname "$_t_f")" || return 1
  printf '{}\n' | json_write "$_t_f" 640 || return 1
  assert_file_mode "$_t_f" "640" "json_write 必须按第 2 个参数设置权限（640）" || return 1
  printf '{}\n' | json_write "$_t_f" 600 || return 1
  assert_file_mode "$_t_f" "600" "json_write 必须能改回 600（state.json 用）" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 哈希 / 小工具
# ---------------------------------------------------------------------------
test_core_sha256_of() {
  local _t_f="$ESB_TMP/sha/known.txt"
  mkdir -p "$(dirname "$_t_f")" || return 1
  printf 'EasySB\n' >"$_t_f" || return 1
  # 固定输入 → 固定摘要（sha256("EasySB\n")）；可发现输出被文件名/换行污染
  assert_eq "$(sha256_of "$_t_f")" "69be465e4668eb84f7f8745455aa5c8b887f4df8af79fda9d5ad983b30ce7661" \
    "sha256_of 必须输出纯小写 64 位摘要（内容为 EasySB+LF）" || return 1
  assert_eq "$(sha256_of "$_t_f" | wc -l | tr -d ' ')" "1" "sha256_of 只能输出一行（不得带文件名）" || return 1
  assert_fail "文件不存在时 sha256_of 必须返回非 0" sha256_of "$ESB_TMP/sha/nope.txt" || return 1
  return 0
}

test_core_cmd_exists_and_trim() {
  assert_ok "cmd_exists 对存在的命令应返回 0" cmd_exists bash
  assert_fail "cmd_exists 对不存在的命令应返回非 0" cmd_exists easysb-definitely-not-a-command
  assert_fail "cmd_exists 多个参数里有一个缺失就必须返回非 0" cmd_exists bash easysb-definitely-not-a-command
  assert_eq "$(trim '  a b  ')" "a b" "trim 应去掉首尾空白" || return 1
  assert_eq "$(trim "$(printf 'x\r')")" "x" "trim 应去掉 CR（Windows 换行/剪贴板）" || return 1
  assert_eq "$(trim '')" "" "trim 空串应输出空" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 变更门禁
# ---------------------------------------------------------------------------
test_core_run_gate_records_only() {
  local _t_sentinel="$ESB_TMP/gate/sentinel.txt"
  mkdir -p "$(dirname "$_t_sentinel")" || return 1
  printf 'keep\n' >"$_t_sentinel" || return 1
  assert_ok "ESB_GATE=1 时 run_gate 应返回 0" run_gate "删除哨兵文件" rm -f "$_t_sentinel" || return 1
  assert_file "$_t_sentinel" "ESB_GATE=1 时变更命令绝不能真正执行（哨兵文件必须还在）" || return 1
  assert_contains "$(<"$ESB_GATE_LOG")" "删除哨兵文件" "变更命令必须记录到 ESB_GATE_LOG（含描述）" || return 1
  assert_contains "$(<"$ESB_GATE_LOG")" "rm -f" "门禁日志必须记录完整 argv" || return 1
  assert_ok "systemctl 变更命令也应被门禁吞掉" run_gate "重启服务" systemctl restart sing-box || return 1
  assert_contains "$(<"$ESB_GATE_LOG")" "systemctl restart sing-box" "systemctl 变更命令必须记入门禁日志" || return 1
  assert_not_contains "$(<"$ESB_TEST_WORK/stubs.log")" "systemctl" \
    "ESB_GATE=1 时不得真正调用 systemctl（stub 日志里不应出现）" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 交互（管道驱动；用例的 stdin 已被 runner 固定为 /dev/null，见 run_tests.sh）
# ---------------------------------------------------------------------------
test_core_ask_yesno_piped() {
  # ESB_ASSUME_YES=1 且 stdin 非 TTY 时 ask_yesno 走“自动取默认值”的短路分支，
  # 所以这里显式 unset 才能测到真正的管道解析（INTERFACES §0.10）。
  assert_eq "$(_core_yesno_pipe y n)" "0" "输入 y 应判定为 yes" || return 1
  assert_eq "$(_core_yesno_pipe Y n)" "0" "输入 Y 应判定为 yes" || return 1
  assert_eq "$(_core_yesno_pipe yes n)" "0" "输入 yes 应判定为 yes" || return 1
  assert_eq "$(_core_yesno_pipe 是 n)" "0" "输入 是 应判定为 yes" || return 1
  assert_ne "$(_core_yesno_pipe n y)" "0" "输入 n 应判定为 no（即使默认是 y）" || return 1
  assert_eq "$(_core_yesno_pipe '' y)" "0" "空输入应取默认值 y" || return 1
  assert_ne "$(_core_yesno_pipe '' n)" "0" "空输入应取默认值 n" || return 1
  assert_ne "$(_core_yesno_pipe maybe y)" "0" "无法识别的输入必须判为 no（即使默认是 y）" || return 1
  return 0
}

test_core_ask_yesno_assume_yes() {
  # 非交互 + ESB_ASSUME_YES=1：按默认值自动通过（默认 n 时不能无脑 yes）
  local _t_rc=0
  ESB_ASSUME_YES=1 ask_yesno "继续？" y >/dev/null 2>&1 || _t_rc=$?
  assert_eq "$_t_rc" "0" "ESB_ASSUME_YES=1 且默认 y 时应自动 yes" || return 1
  _t_rc=0
  ESB_ASSUME_YES=1 ask_yesno "继续？" n >/dev/null 2>&1 || _t_rc=$?
  assert_ne "$_t_rc" "0" "ESB_ASSUME_YES=1 且默认 n 时必须返回 no（不得无脑 yes）" || return 1
  assert_ok "esb_confirm_or_die 在 ESB_ASSUME_YES=1 下应自动确认" esb_confirm_or_die "危险操作"
  return 0
}

test_core_ask_multi_forms() {
  local _t_a
  _t_a="$(printf '\n' | _core_multi_trim "选择协议" "vless|V|on" "vmess|M|off" "tuic|T|on")"
  assert_eq "$_t_a" "vless tuic" "回车应取默认选中(on)的项（实得 [$_t_a]）" || return 1
  _t_a="$(printf 'all\n' | _core_multi_trim "选择协议" "vless|V|on" "vmess|M|off" "tuic|T|on")"
  assert_eq "$_t_a" "vless vmess tuic" "all 应全选（实得 [$_t_a]）" || return 1
  _t_a="$(printf 'a\n' | _core_multi_trim "选择协议" "vless|V|on" "vmess|M|off" "tuic|T|on")"
  assert_eq "$_t_a" "vless vmess tuic" "a 等同 all（实得 [$_t_a]）" || return 1
  _t_a="$(printf 'none\n' | _core_multi_trim "选择协议" "vless|V|on" "vmess|M|off" "tuic|T|on")"
  assert_eq "$_t_a" "" "none 应全不选（实得 [$_t_a]）" || return 1
  _t_a="$(printf '0\n' | _core_multi_trim "选择协议" "vless|V|on" "vmess|M|off" "tuic|T|on")"
  assert_eq "$_t_a" "" "0 应全不选（实得 [$_t_a]）" || return 1
  _t_a="$(printf '1,3\n' | _core_multi_trim "选择协议" "vless|V|on" "vmess|M|off" "tuic|T|on")"
  assert_eq "$_t_a" "vless tuic" "1,3 应选中第 1、3 项（实得 [$_t_a]）" || return 1
  _t_a="$(printf '2\n' | _core_multi_trim "选择协议" "vless|V|on" "vmess|M|off" "tuic|T|on")"
  assert_eq "$_t_a" "vmess" "2 应只选中第 2 项（实得 [$_t_a]）" || return 1
  _t_a="$(printf '9\n' | _core_multi_trim "选择协议" "vless|V|on" "vmess|M|off" "tuic|T|on")"
  assert_eq "$_t_a" "" "越界序号应被忽略（实得 [$_t_a]）" || return 1
  # 省略 on/off 段（只写 key|label）时默认 off
  _t_a="$(printf '\n' | _core_multi_trim "选择协议" "vless|V|on" "plain-label")"
  assert_eq "$_t_a" "vless" "省略 on/off 段时应视为 off（实得 [$_t_a]）" || return 1
  return 0
}

test_core_ask_multi_no_leading_space() {
  # INTERFACES §2 的契约是 outvar="k1 k2"（空格分隔，无前导/尾随空格）；
  # 消费方会直接拿它做字符串比较，前导空格会静默破坏相等判断。
  local _t_a
  _t_a="$(printf 'all\n' | _core_multi_pipe "选择协议" "vless|V|on" "vmess|M|off" "tuic|T|on")"
  assert_eq "$_t_a" "[[vless vmess tuic]]" \
    "ask_multi 的 outvar 必须严格为 k1 k2（无前导/尾随空格）：实得 $_t_a" || return 1
  _t_a="$(printf '\n' | _core_multi_pipe "选择协议" "vless|V|on" "vmess|M|off")"
  assert_eq "$_t_a" "[[vless]]" "默认选中项也必须无前导空格：实得 $_t_a" || return 1
  return 0
}
