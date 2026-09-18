#!/usr/bin/env bash
# =============================================================================
# EasySB 测试断言与沙箱助手（tests/lib/harness.sh）
#   由 tests/run_tests.sh source；本文件不 source 任何其它文件（docs/TESTING.md）。
#   输出约定（runner 先把 ANSI 剥掉再按行聚合）：
#     PASS <case> :: <说明>
#     FAIL <case> :: <说明>       ← 紧跟 4 空格缩进行给出 期望/实际，便于定位
#     SKIP <case> :: <原因>
#   断言失败返回非 0（用例里写 `assert_x … || return 1`）；用例整体返回 77 = SKIP。
#   内部变量一律带 _harness_/_assert_ 前缀，避免 bash 动态作用域的串味
#   （库里的 ask_* 用 `eval "$out=…"` 按名字回填，重名会互相覆盖）。
# =============================================================================

ESB_TESTS_DIR="${ESB_TESTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
export ESB_TESTS_DIR

# ---------------------------------------------------------------------------
# 固定夹具（TESTING.md 硬性要求 3/4：精确值用固定输入，不用随机值/不联网）
#   REALITY 密钥对是真实 X25519 密钥的固定样本；证书是 tests/fixtures/cert.*
# ---------------------------------------------------------------------------
ESB_TEST_FIX_DOMAIN="node.example.com"
ESB_TEST_FIX_EMAIL="me@example.com"
ESB_TEST_FIX_SERVER_IP="203.0.113.10"
ESB_TEST_FIX_SHORT_ID="5b6966df"
ESB_TEST_FIX_REALITY_PRIV="2G-gQX7GtZYF0Sq__q3UCmILfeulOYrD2BNHeX0o-2w"
ESB_TEST_FIX_REALITY_PUB="4BP8NGdz1DWSeCDOzVPpoxDdRPI_y1uSlptUtiqUT2s"
ESB_TEST_FIX_HANDSHAKE="www.microsoft.com"
ESB_TEST_FIX_VLESS_UUID="11111111-2222-4333-8444-555555555555"
ESB_TEST_FIX_VMESS_UUID="aaaaaaa1-bbbb-4ccc-8ddd-eeeeeeeeeeee"
ESB_TEST_FIX_TUIC_UUID="ffffffff-0000-4111-8222-333333333333"
ESB_TEST_FIX_TUIC_PASSWORD="tuic-pass-FIXED"
ESB_TEST_FIX_HY2_PASSWORD="hy2-pass-FIXED"
ESB_TEST_FIX_ANYTLS_PASSWORD="anytls-pass-FIXED"

# ---------------------------------------------------------------------------
# 结果行
# ---------------------------------------------------------------------------
harness_case_name() { printf '%s' "${ESB_TEST_CASE:-?}"; }

_harness_pass() { printf 'PASS %s :: %s\n' "$(harness_case_name)" "${1-}"; return 0; }

_harness_fail() {
  printf 'FAIL %s :: %s\n' "$(harness_case_name)" "${1-}"
  shift || true
  local _harness_fail_line
  for _harness_fail_line in "$@"; do printf '    %s\n' "$_harness_fail_line"; done
  return 1
}

_harness_skip() { printf 'SKIP %s :: %s\n' "$(harness_case_name)" "${1-}"; return 77; }

# 用例里主动跳过：`something_missing && return $(skip_test "原因")` 或 `skip_test "…"; return 77`
skip_test() { _harness_skip "${1-}"; }

# 需要 jq 的用例开头写 `requires_jq || return 77`
requires_jq() {
  cmd_exists jq && return 0
  _harness_skip "jq 未安装，无法断言 JSON 值（Linux 主机装 jq；Windows 开发机把 jq.exe 放进 tools/bin/）"
}

_harness_short() { printf '%s' "${1-}" | tr '\n\t' '  ' | cut -c1-400; }

# ---------------------------------------------------------------------------
# 断言
# ---------------------------------------------------------------------------
assert_eq() {
  local _assert_eq_a="${1-}" _assert_eq_b="${2-}" _assert_eq_m="${3:-assert_eq}"
  if [ "$_assert_eq_a" = "$_assert_eq_b" ]; then _harness_pass "$_assert_eq_m"; return 0; fi
  _harness_fail "$_assert_eq_m" \
    "期望: [$( _harness_short "$_assert_eq_b")]" \
    "实际: [$( _harness_short "$_assert_eq_a")]"
}

assert_ne() {
  local _assert_ne_a="${1-}" _assert_ne_b="${2-}" _assert_ne_m="${3:-assert_ne}"
  if [ "$_assert_ne_a" != "$_assert_ne_b" ]; then _harness_pass "$_assert_ne_m"; return 0; fi
  _harness_fail "$_assert_ne_m" \
    "期望: 不等于 [$( _harness_short "$_assert_ne_b")]" \
    "实际: [$( _harness_short "$_assert_ne_a")]"
}

assert_contains() {
  local _assert_contains_h="${1-}" _assert_contains_n="${2-}" _assert_contains_m="${3:-assert_contains}"
  case "$_assert_contains_h" in
    *"$_assert_contains_n"*) _harness_pass "$_assert_contains_m"; return 0 ;;
  esac
  _harness_fail "$_assert_contains_m" \
    "期望包含: [$( _harness_short "$_assert_contains_n")]" \
    "实际内容: [$( _harness_short "$_assert_contains_h")]"
}

assert_not_contains() {
  local _assert_not_contains_h="${1-}" _assert_not_contains_n="${2-}" _assert_not_contains_m="${3:-assert_not_contains}"
  case "$_assert_not_contains_h" in
    *"$_assert_not_contains_n"*)
      _harness_fail "$_assert_not_contains_m" \
        "期望不含: [$( _harness_short "$_assert_not_contains_n")]" \
        "实际内容: [$( _harness_short "$_assert_not_contains_h")]"
      return 1
      ;;
  esac
  _harness_pass "$_assert_not_contains_m"
}

# 断言命令成功（0）：assert_ok <msg> <cmd...>
assert_ok() {
  local _assert_ok_m="${1-}"; shift
  local _assert_ok_rc=0 _assert_ok_out=""
  _assert_ok_out="$("$@" 2>&1)" || _assert_ok_rc=$?
  if [ "$_assert_ok_rc" = "0" ]; then _harness_pass "$_assert_ok_m"; return 0; fi
  _harness_fail "$_assert_ok_m" \
    "命令: $*" \
    "期望退出 0，实际 $_assert_ok_rc" \
    "输出: [$( _harness_short "$_assert_ok_out")]"
}

# 断言命令失败（非 0）：assert_fail <msg> <cmd...>
assert_fail() {
  local _assert_fail_m="${1-}"; shift
  local _assert_fail_rc=0 _assert_fail_out=""
  _assert_fail_out="$("$@" 2>&1)" || _assert_fail_rc=$?
  if [ "$_assert_fail_rc" != "0" ]; then _harness_pass "$_assert_fail_m"; return 0; fi
  _harness_fail "$_assert_fail_m" \
    "命令: $*" \
    "期望非 0 退出，实际 0" \
    "输出: [$( _harness_short "$_assert_fail_out")]"
}

assert_file() {
  local _assert_file_p="${1-}" _assert_file_m="${2:-assert_file}"
  if [ -f "$_assert_file_p" ]; then _harness_pass "$_assert_file_m"; return 0; fi
  if [ -e "$_assert_file_p" ]; then
    _harness_fail "$_assert_file_m" "期望文件: $_assert_file_p" "实际: 存在但不是普通文件"
    return 1
  fi
  _harness_fail "$_assert_file_m" "期望文件: $_assert_file_p" "实际: 不存在"
}

# assert_json <file> <jq表达式> <期望值> <msg>
#   用 `jq -cr` 取值：字符串不带引号，对象/数组压缩成一行，null 表示键不存在/为 null
assert_json() {
  local _assert_json_f="${1-}" _assert_json_q="${2-}" _assert_json_e="${3-}" _assert_json_m="${4:-assert_json}"
  if ! cmd_exists jq; then
    _harness_fail "$_assert_json_m" "jq 未安装，无法求值: $_assert_json_q"
    return 1
  fi
  if [ ! -f "$_assert_json_f" ]; then
    _harness_fail "$_assert_json_m" "期望文件: $_assert_json_f" "实际: 不存在"
    return 1
  fi
  local _assert_json_raw="" _assert_json_v="" _assert_json_rc=0
  _assert_json_raw="$(jq -cr "$_assert_json_q" "$_assert_json_f" 2>/dev/null)" || _assert_json_rc=$?
  # Windows 版 jq.exe 输出 CRLF，command substitution 只吃 \n，所以这里统一去掉 \r
  # （用两步赋值是为了保住 jq 自己的退出码，管道会把状态换成 tr 的）
  _assert_json_v="$(printf '%s' "$_assert_json_raw" | tr -d '\r')"
  if [ "$_assert_json_rc" != "0" ]; then
    _harness_fail "$_assert_json_m" \
      "jq 表达式求值失败: $_assert_json_q" \
      "文件: $_assert_json_f" \
      "期望值: [$( _harness_short "$_assert_json_e")]"
    return 1
  fi
  if [ "$_assert_json_v" = "$_assert_json_e" ]; then _harness_pass "$_assert_json_m"; return 0; fi
  _harness_fail "$_assert_json_m" \
    "jq: $_assert_json_q （文件 $(basename "$_assert_json_f")）" \
    "期望: [$( _harness_short "$_assert_json_e")]" \
    "实际: [$( _harness_short "$_assert_json_v")]"
}

# 文件系统是否真的支持 POSIX 权限位（MSYS/git-bash 的 chmod 常被忽略）
_harness_stat_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

modes_supported() {
  local _harness_ms_probe_dir="${ESB_TEST_WORK:-${TMPDIR:-/tmp}}"
  if [ -z "${_HARNESS_MODES_OK:-}" ]; then
    local _harness_ms_f="$_harness_ms_probe_dir/.mode-probe.$$"
    rm -f "$_harness_ms_f" 2>/dev/null
    : >"$_harness_ms_f" 2>/dev/null
    chmod 600 "$_harness_ms_f" 2>/dev/null
    if [ "$(_harness_stat_mode "$_harness_ms_f")" = "600" ]; then _HARNESS_MODES_OK=yes
    else _HARNESS_MODES_OK=no
    fi
    rm -f "$_harness_ms_f" 2>/dev/null
  fi
  [ "$_HARNESS_MODES_OK" = "yes" ]
}

# assert_file_mode <path> <期望八进制> <msg>
assert_file_mode() {
  local _assert_file_mode_p="${1-}" _assert_file_mode_e="${2-}" _assert_file_mode_m="${3:-assert_file_mode}"
  if ! modes_supported; then
    skip_test "文件系统不支持 POSIX 权限位（chmod 被忽略），无法断言 $_assert_file_mode_p 的模式"
    return 0
  fi
  assert_eq "$(_harness_stat_mode "$_assert_file_mode_p")" "$_assert_file_mode_e" "$_assert_file_mode_m"
}

# ---------------------------------------------------------------------------
# 沙箱
# ---------------------------------------------------------------------------
# 复刻 easysb.sh 的路径模型（INTERFACES §1）：全部挂在 ESB_ROOT 之下。
# 注意：lib/*.sh 自身不初始化这些变量（只有入口 easysb.sh 会），所以 runner 必须在这里补上。
harness_paths_init() {
  export ESB_ROOT="${ESB_ROOT:-}"
  export ESB_DIR="${ESB_ROOT}/etc/easysb"
  export ESB_STATE="${ESB_DIR}/state.json"
  export ESB_LOG="${ESB_DIR}/easysb.log"
  export ESB_SECRET_DIR="${ESB_DIR}/secrets"
  export ESB_CLIENT_DIR="${ESB_DIR}/client"
  export ESB_CONF_DIR="${ESB_ROOT}/etc/sing-box"
  export ESB_CONFIG="${ESB_CONF_DIR}/config.json"
  export ESB_CERT_DIR="${ESB_CONF_DIR}/certs"
  export ESB_BIN="${ESB_ROOT}/usr/bin/sing-box"
  export ESB_UNIT_DIR="${ESB_ROOT}/usr/lib/systemd/system"
  export ESB_STATE_DIR="${ESB_ROOT}/var/lib/sing-box"
  export ESB_BACKUP_DIR="${ESB_ROOT}/var/backups/easysb"
  export ESB_WEB_ROOT="${ESB_ROOT}/var/www/easysb"
  export ESB_NGINX_CONF="${ESB_ROOT}/etc/nginx/conf.d/easysb.conf"
  export ESB_TMP="${ESB_ROOT}/tmp/easysb.$$"
  export TMPDIR="${ESB_ROOT}/tmp"
  mkdir -p "$ESB_TMP" 2>/dev/null || true
  return 0
}

# 把真实绝对路径映射到沙箱里：sandbox_path /etc/sing-box/config.json
sandbox_path() { printf '%s%s\n' "${ESB_ROOT:-}" "${1-}"; }

# 清空并重建当前沙箱（含默认 state.json）
sandbox_reset() {
  [ -n "${ESB_ROOT:-}" ] || { _harness_fail "sandbox_reset: ESB_ROOT 为空，拒绝操作"; return 1; }
  rm -rf "${ESB_ROOT:?}" 2>/dev/null || true
  harness_paths_init
  mkdir -p "$ESB_ROOT" || { _harness_fail "sandbox_reset: 无法创建 $ESB_ROOT"; return 1; }
  if ! state_init >/dev/null 2>&1; then
    _harness_fail "sandbox_reset: state_init 失败" "ESB_STATE=$ESB_STATE"
    return 1
  fi
  return 0
}

# 固定夹具：域名/邮箱/REALITY/密钥（不启用任何协议）
sandbox_seed_state() {
  state_set_str .domain "$ESB_TEST_FIX_DOMAIN" || return 1
  state_set_str .email "$ESB_TEST_FIX_EMAIL" || return 1
  state_set_str .server_ip "$ESB_TEST_FIX_SERVER_IP" || return 1
  state_set_str .reality.private_key "$ESB_TEST_FIX_REALITY_PRIV" || return 1
  state_set_str .reality.public_key "$ESB_TEST_FIX_REALITY_PUB" || return 1
  state_set_str .reality.short_id "$ESB_TEST_FIX_SHORT_ID" || return 1
  state_set_str .reality.handshake_server "$ESB_TEST_FIX_HANDSHAKE" || return 1
  state_set_str .reality.server_name "$ESB_TEST_FIX_HANDSHAKE" || return 1
  state_set .reality.handshake_port 443 || return 1
  secret_set vless_uuid "$ESB_TEST_FIX_VLESS_UUID" || return 1
  secret_set vmess_uuid "$ESB_TEST_FIX_VMESS_UUID" || return 1
  secret_set tuic_uuid "$ESB_TEST_FIX_TUIC_UUID" || return 1
  secret_set tuic_password "$ESB_TEST_FIX_TUIC_PASSWORD" || return 1
  secret_set hysteria2_password "$ESB_TEST_FIX_HY2_PASSWORD" || return 1
  secret_set anytls_password "$ESB_TEST_FIX_ANYTLS_PASSWORD" || return 1
  return 0
}

# 在沙箱证书目录生成一对自签证书（EC P-256）并写进 state（render_config 会检查文件存在）。
# 证书在运行时生成：仓库里不放任何私钥文件（哪怕是一次性的），
# tests/fixtures/cert.* 若存在仅作为没有 openssl 时的兜底。
sandbox_seed_cert() {
  local _sandbox_seed_cert_d="${1:-$ESB_TEST_FIX_DOMAIN}"
  local _sandbox_seed_crt _sandbox_seed_key
  mkdir -p "$ESB_CERT_DIR" || return 1
  _sandbox_seed_crt="$ESB_CERT_DIR/${_sandbox_seed_cert_d}.crt"
  _sandbox_seed_key="$ESB_CERT_DIR/${_sandbox_seed_cert_d}.key"
  if command -v openssl >/dev/null 2>&1; then
    openssl ecparam -genkey -name prime256v1 -out "$_sandbox_seed_key" >/dev/null 2>&1 || return 1
    openssl req -new -x509 -key "$_sandbox_seed_key" -out "$_sandbox_seed_crt" -days 30 \
      -subj "/CN=${_sandbox_seed_cert_d}" \
      -addext "subjectAltName=DNS:${_sandbox_seed_cert_d}" >/dev/null 2>&1 || return 1
  elif [ -f "$ESB_TESTS_DIR/fixtures/cert.crt" ] && [ -f "$ESB_TESTS_DIR/fixtures/cert.key" ]; then
    cp -f "$ESB_TESTS_DIR/fixtures/cert.crt" "$_sandbox_seed_crt" || return 1
    cp -f "$ESB_TESTS_DIR/fixtures/cert.key" "$_sandbox_seed_key" || return 1
  else
    return 1
  fi
  state_set_str .cert.domain "$_sandbox_seed_cert_d" || return 1
  state_set_str .cert.crt "$_sandbox_seed_crt" || return 1
  state_set_str .cert.key "$_sandbox_seed_key" || return 1
  state_set_str .cert.source "fixture" || return 1
  return 0
}

sandbox_proto_on()  { state_proto_set_field "${1}" .enabled true; }
sandbox_proto_off() { state_proto_set_field "${1}" .enabled false; }

# 全量夹具状态：域名 + REALITY + 密钥 + 证书 + 5 个协议全开
sandbox_seed_full() {
  sandbox_seed_state || return 1
  sandbox_seed_cert "$ESB_TEST_FIX_DOMAIN" || return 1
  local _sandbox_seed_full_p
  for _sandbox_seed_full_p in $(esb_proto_keys); do
    sandbox_proto_on "$_sandbox_seed_full_p" || return 1
  done
  return 0
}
