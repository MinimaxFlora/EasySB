#!/usr/bin/env bash
# =============================================================================
# EasySB — tests/cases/certs.sh
# 证书模块（lib/30-certs.sh）沙箱用例：
#   自签证书落地与注册表 / cert_list TSV 形状与取值 / 剩余天数 / 删除保护与 --force /
#   注册表权限 600 / 损坏注册表干净报错（不退出 shell）/ 申请方式校验 /
#   dns_provider_list 形状 / 续期后自动重载 / cert_use 安装文件与写状态 / cert_detail /
#   cert_tool_install 幂等与离线失败
#
# 约定：命令状态断言统一写成 `cmd …; rc=$?; assert_eq "$rc" …`。
#       TESTING.md 只固定了 assert_eq / assert_contains / assert_file / assert_json
#       的参数顺序，assert_ok / assert_fail 的顺序未定义，故此处不用它们以免歧义。
# =============================================================================
# shellcheck shell=bash

TESTS="test_1_self_signed_registers_cert \
       test_2_cert_list_tsv \
       test_3_expiring_days \
       test_4_delete_guard_and_force \
       test_5_registry_mode_600 \
       test_6_corrupt_registry_clean_error \
       test_7_apply_mode_validation \
       test_8_dns_provider_list_format \
       test_9_reloadcmd_setup \
       test_10_cert_use_installs_files \
       test_11_cert_detail \
       test_12_tool_install_idempotent \
       test_13_dns_env_not_on_cmdline \
       test_14_acme_no_output_clean_error \
       test_15_renew_args_and_all test_16_selfsigned_paths_do_not_clash"

# ---------------------------------------------------------------------------
# 用例内部工具（前缀 _cert_case_，属于测试代码，不参与契约审计）
# ---------------------------------------------------------------------------
# TSV 取字段：<文本> <行号> <列号>
_cert_case_field() { printf '%s\n' "$1" | awk -F'\t' -v r="$2" -v c="$3" 'NR == r { print $c; exit }'; }
# TSV 某行的列数
_cert_case_cols() { printf '%s\n' "$1" | awk -F'\t' -v r="$2" 'NR == r { print NF; exit }'; }
# TSV 非空行数
_cert_case_rows() { printf '%s\n' "$1" | grep -c . ; }
# 断言 TSV 文本里没有 CR
_cert_case_assert_no_cr() { # <文本> <说明>
  case "$1" in
    *$'\r'*) echo "$2：输出中不应包含 CR" >&2; return 1 ;;
  esac
  return 0
}
# 断言整数落在闭区间内（证书剩余天数这类"约等于"断言）
_cert_case_assert_int_range() { # <值> <最小值> <最大值> <说明>
  local _cert_case_assert_int_range_v="$1"
  case "$_cert_case_assert_int_range_v" in
    ''|*[!0-9-]*) echo "$4：不是整数（$_cert_case_assert_int_range_v）" >&2; return 1 ;;
  esac
  if [ "$_cert_case_assert_int_range_v" -lt "$2" ] || [ "$_cert_case_assert_int_range_v" -gt "$3" ]; then
    echo "$4：$_cert_case_assert_int_range_v 不在 $2-$3 区间" >&2
    return 1
  fi
  return 0
}
# 文件权限（GNU stat / BSD stat 双兼容）
_cert_case_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
# 本机文件系统是否真的实现 POSIX 权限位（MSYS/git-bash 上 chmod 是空操作）
_cert_case_posix_modes_ok() {
  local _cert_case_posix_modes_ok_f="${ESB_TMP:-${TMPDIR:-/tmp}}/.easysb-modeprobe.$$"
  mkdir -p "$(dirname "$_cert_case_posix_modes_ok_f")" 2>/dev/null || return 1
  : >"$_cert_case_posix_modes_ok_f" || return 1
  chmod 600 "$_cert_case_posix_modes_ok_f" 2>/dev/null || true
  local _cert_case_posix_modes_ok_m=""
  _cert_case_posix_modes_ok_m="$(_cert_case_mode "$_cert_case_posix_modes_ok_f")"
  rm -f "$_cert_case_posix_modes_ok_f" 2>/dev/null || true
  [ "$_cert_case_posix_modes_ok_m" = "600" ]
}
# 伪造 acme.sh（让 cert_tool_installed 为真，且不会真的联外网）
_cert_case_fake_acme() {
  local _cert_case_fake_acme_home
  _cert_case_fake_acme_home="$(cert_acme_home)"
  mkdir -p "$_cert_case_fake_acme_home" || return 1
  printf '#!/bin/sh\nexit 0\n' >"${_cert_case_fake_acme_home}/acme.sh" || return 1
  chmod 755 "${_cert_case_fake_acme_home}/acme.sh" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 1. 自签证书：crt/key 可读 + 注册表记录正确
# ---------------------------------------------------------------------------
test_1_self_signed_registers_cert() {
  state_init || return 1
  local _cert_case_rc=0
  cert_self_signed "t1.example.com" || return 1

  # 自签证书独立存放：self-signed-<域名>.crt|key（与 acme 证书分开，允许同一域名两种模式并存）
  assert_file "$ESB_CERT_DIR/self-signed-t1.example.com.crt" "自签证书 crt 应存在" || return 1
  assert_file "$ESB_CERT_DIR/self-signed-t1.example.com.key" "自签证书 key 应存在" || return 1

  # crt 必须能被 openssl 解析（形状 + 值：CN）
  local _cert_case_subj=""
  _cert_case_subj="$(openssl x509 -in "$ESB_CERT_DIR/self-signed-t1.example.com.crt" -noout -subject 2>/dev/null)"
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "自签 crt 应能被 openssl 解析" || return 1
  assert_contains "$_cert_case_subj" "t1.example.com" "自签证书主体应为域名" || return 1
  # key 必须是 EC 私钥
  openssl ec -in "$ESB_CERT_DIR/self-signed-t1.example.com.key" -noout >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "自签私钥应为 EC 私钥（prime256v1）" || return 1

  # 注册表
  assert_json "$ESB_DIR/certs.json" 'length' '1' || return 1
  assert_json "$ESB_DIR/certs.json" '.[0].domain' 't1.example.com' || return 1
  assert_json "$ESB_DIR/certs.json" '.[0].source' 'self-signed' || return 1
  assert_json "$ESB_DIR/certs.json" '.[0].auto_renew' 'true' || return 1
  assert_eq "$(registry_get t1.example.com crt)" "$ESB_CERT_DIR/self-signed-t1.example.com.crt" \
    "注册表 crt 应为证书目录内的绝对路径" || return 1
  assert_eq "$(registry_get t1.example.com key)" "$ESB_CERT_DIR/self-signed-t1.example.com.key" \
    "注册表 key 应为证书目录内的绝对路径" || return 1
  registry_has "t1.example.com"
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "registry_has 应命中已登记证书" || return 1
  registry_has "other.example.com"
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "registry_has 不应命中未登记域名" || return 1

  # 幂等：重复自签只更新同一条记录
  cert_self_signed "t1.example.com" || return 1
  assert_json "$ESB_DIR/certs.json" 'length' '1' "重复自签不应产生重复记录" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 2. cert_list：TSV 形状与取值（已知注册表）
# ---------------------------------------------------------------------------
test_2_cert_list_tsv() {
  state_init || return 1
  cert_self_signed "a.example.com" || return 1
  cert_self_signed "b.example.com" || return 1
  state_set_str ".cert.domain" "a.example.com" || return 1
  state_set_str ".cert.crt" "$ESB_CERT_DIR/a.example.com.crt" || return 1
  state_set_str ".cert.key" "$ESB_CERT_DIR/a.example.com.key" || return 1

  local _cert_case_list=""
  _cert_case_list="$(cert_list)" || return 1
  assert_eq "$(_cert_case_rows "$_cert_case_list")" "2" "两条注册记录应输出两行" || return 1
  _cert_case_assert_no_cr "$_cert_case_list" "cert_list" || return 1
  assert_eq "$(_cert_case_cols "$_cert_case_list" 1)" "6" "每行应为 6 列 TSV" || return 1
  assert_eq "$(_cert_case_cols "$_cert_case_list" 2)" "6" "每行应为 6 列 TSV" || return 1

  # 第 1 行（a.example.com，已应用）
  assert_eq "$(_cert_case_field "$_cert_case_list" 1 1)" "a.example.com" "第 1 列=域名" || return 1
  assert_eq "$(_cert_case_field "$_cert_case_list" 1 2)" "$ESB_CERT_DIR/a.example.com.crt" "第 2 列=crt 路径" || return 1
  assert_eq "$(_cert_case_field "$_cert_case_list" 1 3)" "$ESB_CERT_DIR/a.example.com.key" "第 3 列=key 路径" || return 1
  assert_eq "$(_cert_case_field "$_cert_case_list" 1 5)" "self-signed" "第 5 列=来源" || return 1
  assert_eq "$(_cert_case_field "$_cert_case_list" 1 6)" "1" "已应用证书 applied 列应为 1" || return 1
  _cert_case_assert_int_range "$(_cert_case_field "$_cert_case_list" 1 4)" 3649 3650 \
    "第 4 列=剩余天数（自签 3650 天证书）" || return 1

  # 第 2 行（b.example.com，未应用）
  assert_eq "$(_cert_case_field "$_cert_case_list" 2 1)" "b.example.com" "第 1 列=域名" || return 1
  assert_eq "$(_cert_case_field "$_cert_case_list" 2 5)" "self-signed" "第 5 列=来源" || return 1
  assert_eq "$(_cert_case_field "$_cert_case_list" 2 6)" "0" "未应用证书 applied 列应为 0" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 3. cert_expiring_days：自签 ~3650；未知 / 损坏证书 → -1
# ---------------------------------------------------------------------------
test_3_expiring_days() {
  state_init || return 1
  cert_self_signed "t3.example.com" || return 1
  _cert_case_assert_int_range "$(cert_expiring_days "t3.example.com")" 3649 3650 \
    "自签证书剩余天数应约 3650" || return 1

  assert_eq "$(cert_expiring_days "nothing.example.com")" "-1" \
    "未登记域名应输出 -1" || return 1

  # 不可读的证书文件 → -1（不报错、不退出）
  mkdir -p "$ESB_CERT_DIR" || return 1
  printf 'this is not a certificate\n' >"$ESB_CERT_DIR/broken.example.com.crt"
  assert_eq "$(cert_expiring_days "broken.example.com")" "-1" \
    "损坏证书应输出 -1" || return 1
  # 注册表登记后仍应优雅返回 -1
  registry_add "broken.example.com" "$ESB_CERT_DIR/broken.example.com.crt" \
    "$ESB_CERT_DIR/broken.example.com.key" "self-signed" "" || return 1
  assert_eq "$(cert_expiring_days "broken.example.com")" "-1" \
    "损坏证书（已登记）应输出 -1" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 4. cert_delete：使用中拒绝删除；--force 可删；未使用可直接删
# ---------------------------------------------------------------------------
test_4_delete_guard_and_force() {
  state_init || return 1
  cert_self_signed "used.example.com" || return 1
  cert_self_signed "idle.example.com" || return 1
  state_set_str ".cert.domain" "used.example.com" || return 1

  local _cert_case_rc=0
  # 使用中且无 --force → 必须拒绝，且不动注册表与文件
  cert_delete "used.example.com" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "正在使用的证书无 --force 时必须拒绝删除" || return 1
  registry_has "used.example.com"
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "拒绝删除时不应改动注册表" || return 1
  assert_file "$ESB_CERT_DIR/used.example.com.crt" "拒绝删除时证书文件应保留" || return 1
  assert_eq "$(state_get .cert.domain)" "used.example.com" "拒绝删除时状态不应被清空" || return 1

  # 未使用的证书：直接删除（注册表 + 文件）
  cert_delete "idle.example.com"
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "未使用的证书应可直接删除" || return 1
  registry_has "idle.example.com"
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "删除后注册表不应再有该证书" || return 1
  if [ -f "$ESB_CERT_DIR/idle.example.com.crt" ] || [ -f "$ESB_CERT_DIR/idle.example.com.key" ]; then
    echo "删除后证书文件仍存在" >&2
    return 1
  fi

  # 使用中 + --force → 允许删除
  cert_delete "used.example.com" --force
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "使用中的证书加 --force 应可删除" || return 1
  registry_has "used.example.com"
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "--force 删除后注册表不应再有该证书" || return 1
  assert_eq "$(state_get .cert.domain)" "" "--force 删除已应用证书后应清除 .cert.domain" || return 1

  # 删除前必须留副本
  local _cert_case_bak=""
  _cert_case_bak="$(ls -1d "${ESB_BACKUP_DIR}"/*cert-used.example.com* 2>/dev/null | head -1)"
  assert_contains "$_cert_case_bak" "cert-used.example.com" "删除前应在备份目录留证书副本" || return 1
  assert_file "${_cert_case_bak}/used.example.com.crt" "备份副本应包含 crt" || return 1

  # 未登记域名 → 干净报错
  cert_delete "unknown.example.com" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "未登记域名应报错而不是删除成功" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 5. 注册表权限 600（写入/更新后仍为 600）
# ---------------------------------------------------------------------------
test_5_registry_mode_600() {
  state_init || return 1
  cert_self_signed "t5.example.com" || return 1

  # POSIX 平台（真实目标机 Linux）断言权限位；MSYS/git-bash 上 chmod 是空操作，明确跳过
  if _cert_case_posix_modes_ok; then
    assert_eq "$(_cert_case_mode "$ESB_DIR/certs.json")" "600" "certs.json 新建时权限应为 600" || return 1
    registry_add "t5b.example.com" "$ESB_CERT_DIR/t5b.example.com.crt" \
      "$ESB_CERT_DIR/t5b.example.com.key" "acme" "2030-01-01 00:00:00" || return 1
    assert_eq "$(_cert_case_mode "$ESB_DIR/certs.json")" "600" "certs.json 更新后权限应为 600" || return 1
    registry_remove "t5b.example.com" || return 1
    assert_eq "$(_cert_case_mode "$ESB_DIR/certs.json")" "600" "certs.json 删除记录后权限应为 600" || return 1
  else
    echo "    (本机不实现 POSIX 权限位：chmod 600 实测 $( _cert_case_mode "$ESB_DIR/certs.json")，跳过 600 断言)" >&2
    assert_eq "$( [ -s "$ESB_DIR/certs.json" ] && echo yes )" "yes" "certs.json 应可写且非空" || return 1
    registry_add "t5b.example.com" "$ESB_CERT_DIR/t5b.example.com.crt" \
      "$ESB_CERT_DIR/t5b.example.com.key" "acme" "2030-01-01 00:00:00" || return 1
    registry_remove "t5b.example.com" || return 1
  fi

  assert_json "$ESB_DIR/certs.json" 'length' '1' "删除记录后应只剩 1 条" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 6. 损坏的 certs.json：干净报错（非 0）且不杀死 shell
# ---------------------------------------------------------------------------
test_6_corrupt_registry_clean_error() {
  state_init || return 1
  printf 'this is not json at all {{{' >"$ESB_DIR/certs.json"

  local _cert_case_rc=0 _cert_case_out=""
  # 直接调用（同一 shell 内）必须只返回非 0，绝不能 exit
  cert_list >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "损坏的注册表：cert_list 应返回 1" || return 1

  # 子 shell 里再验证一次：能继续打印 RC=$? 说明脚本没被终止
  _cert_case_out="$( cert_list 2>&1; printf 'RC=%s' "$?" )"
  assert_contains "$_cert_case_out" "RC=1" "损坏的注册表：子 shell 应能打印 RC=1" || return 1
  assert_contains "$_cert_case_out" "损坏" "应给出可读的错误提示" || return 1

  # 其它注册表入口同样返回非 0
  registry_get "a.example.com" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "损坏的注册表：registry_get 应返回 1" || return 1
  registry_has "a.example.com" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "损坏的注册表：registry_has 应返回 1" || return 1
  registry_add "a.example.com" "/x/a.crt" "/x/a.key" "acme" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "损坏的注册表：registry_add 不应覆盖成新内容" || return 1
  # 直接调用 registry_load/registry_save：必须是 return 1，不能 exit（否则调用者 shell 会被拖死）
  registry_load >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "损坏的注册表：registry_load 必须返回 1 而不是 exit" || return 1
  printf '[]\n' | registry_save >/dev/null 2>&1
  _cert_case_rc=$?
  # registry_save 读的是合法内容，应成功；这里只证明直接调用不会终止 shell
  assert_eq "$_cert_case_rc" "0" "直接调用 registry_save 不应终止 shell" || return 1

  # 修复后可恢复正常
  printf '[]\n' >"$ESB_DIR/certs.json"
  cert_list >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "修复注册表后 cert_list 应恢复为 0" || return 1
  assert_eq "$(cert_list)" "" "空注册表应无输出" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 7. cert_apply 参数校验（不联网、不改系统）
# ---------------------------------------------------------------------------
test_7_apply_mode_validation() {
  state_init || return 1
  _cert_case_fake_acme || return 1
  local _cert_case_rc=0
  local _cert_case_gate_mark=""

  cert_apply "not_a_domain" "standalone" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "非法域名应被拒绝" || return 1

  cert_apply "ok.example.com" "" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "缺少申请方式应被拒绝" || return 1

  cert_apply "ok.example.com" "bogus" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "未知申请方式应被拒绝" || return 1

  cert_apply "ok.example.com" "dns:dns_unknown" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "不支持的 DNS 服务商应被拒绝" || return 1

  # 被拒绝的调用不得在 gate 日志里留下任何 acme.sh 调用
  cert_apply "ok.example.com" "dns:dns_unknown" >/dev/null 2>&1
  _cert_case_gate_mark="$(grep -c 'acme.sh' "${ESB_GATE_LOG:-/dev/null}" 2>/dev/null)"
  assert_eq "$_cert_case_gate_mark" "0" "参数校验失败时不应调用 acme.sh" || return 1

  # 合法 DNS 服务商但缺凭据文件 → 干净失败
  [ -f "$ESB_SECRET_DIR/dns.env" ] && rm -f "$ESB_SECRET_DIR/dns.env"
  cert_apply "ok.example.com" "dns:dns_cf" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "缺少 DNS 凭据文件时应干净失败" || return 1

  # 注册表不应因失败的申请而新增记录
  assert_eq "$(cert_list)" "" "申请失败不应登记任何证书" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 8. dns_provider_list：形状（UI 会不加引号地展开，必须 key|label 且无空格）
# ---------------------------------------------------------------------------
test_8_dns_provider_list_format() {
  local _cert_case_provs=""
  _cert_case_provs="$(dns_provider_list)" || return 1
  assert_contains "$_cert_case_provs" "dns_cf|" "应包含 Cloudflare 的 dns_cf" || return 1
  assert_contains "$_cert_case_provs" "dns_huaweicloud|" "应包含华为云的 dns_huaweicloud" || return 1

  # 每一行都必须是 "dns_xxx|标签"，且没有空标签
  local _cert_case_bad=0
  _cert_case_bad="$(printf '%s\n' "$_cert_case_provs" | awk -F'|' 'NF != 2 || $1 == "" || $2 == "" { n++ } END { print n + 0 }')"
  assert_eq "$_cert_case_bad" "0" "每行都应为 key|label 两段" || return 1

  # 不含空格（ask_single 由 $(dns_provider_list) 展开，空格会拆散条目）
  local _cert_case_spaces=0
  _cert_case_spaces="$(printf '%s' "$_cert_case_provs" | tr -dc ' ' | wc -c | tr -d ' ')"
  assert_eq "$_cert_case_spaces" "0" "标签中不能含 ASCII 空格（否则 UI 选择项会被拆散）" || return 1

  # 至少覆盖任务要求的 5 家
  local _cert_case_rows=0
  _cert_case_rows="$(printf '%s\n' "$_cert_case_provs" | grep -c . )"
  assert_eq "$_cert_case_rows" "5" "应提供 5 个 DNS 服务商" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 9. cert_reloadcmd_setup：给 acme 证书装 --reloadcmd，自签证书跳过
# ---------------------------------------------------------------------------
test_9_reloadcmd_setup() {
  state_init || return 1
  _cert_case_fake_acme || return 1
  cert_self_signed "self.example.com" || return 1
  registry_add "acme.example.com" "$ESB_CERT_DIR/acme.example.com.crt" \
    "$ESB_CERT_DIR/acme.example.com.key" "acme" "2031-01-01 00:00:00" || return 1

  local _cert_case_rc=0 _cert_case_log=""
  : >"${ESB_GATE_LOG:-/dev/null}"

  ESB_INIT=systemd cert_reloadcmd_setup
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "systemd 下配置续期重载应成功" || return 1
  _cert_case_log="$(cat "${ESB_GATE_LOG:-/dev/null}" 2>/dev/null)"
  assert_contains "$_cert_case_log" "--install-cert" "应调用 acme.sh --install-cert" || return 1
  assert_contains "$_cert_case_log" "-d acme.example.com" "应针对已登记的 acme 证书" || return 1
  assert_contains "$_cert_case_log" "--key-file $ESB_CERT_DIR/acme.example.com.key" "应指定 --key-file" || return 1
  assert_contains "$_cert_case_log" "--fullchain-file $ESB_CERT_DIR/acme.example.com.crt" "应指定 --fullchain-file" || return 1
  assert_contains "$_cert_case_log" "systemctl restart sing-box" "systemd 下 --reloadcmd 应为 systemctl restart sing-box" || return 1

  : >"${ESB_GATE_LOG:-/dev/null}"
  ESB_INIT=openrc cert_reloadcmd_setup
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "openrc 下配置续期重载应成功" || return 1
  _cert_case_log="$(cat "${ESB_GATE_LOG:-/dev/null}" 2>/dev/null)"
  assert_contains "$_cert_case_log" "rc-service sing-box restart" "openrc 下应使用 rc-service 重启" || return 1

  : >"${ESB_GATE_LOG:-/dev/null}"
  ESB_INIT=none cert_reloadcmd_setup
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "没有服务管理器时也应正常结束" || return 1
  _cert_case_log="$(cat "${ESB_GATE_LOG:-/dev/null}" 2>/dev/null)"
  assert_contains "$_cert_case_log" "--install-cert" "仍应调用 --install-cert" || return 1
  case "$_cert_case_log" in
    *--reloadcmd*) echo "没有服务管理器时不应设置 --reloadcmd" >&2; return 1 ;;
  esac

  # 自签证书不应出现在任何 acme.sh 调用里
  : >"${ESB_GATE_LOG:-/dev/null}"
  ESB_INIT=systemd cert_reloadcmd_setup || return 1
  _cert_case_log="$(cat "${ESB_GATE_LOG:-/dev/null}" 2>/dev/null)"
  case "$_cert_case_log" in
    *self.example.com*) echo "自签证书不应被写入 acme.sh 续期配置" >&2; return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# 10. cert_use：把别处的证书安装进证书目录、写注册表与 state
# ---------------------------------------------------------------------------
test_10_cert_use_installs_files() {
  state_init || return 1
  local _cert_case_rc=0

  cert_use "not-registered.example.com" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "未登记的证书应拒绝应用" || return 1

  # 造一份"在别处"的证书，模拟 acme 产物还没安装到证书目录
  local _cert_case_stage="${ESB_TEST_WORK:-$ESB_DIR}/staging/use.example.com"
  mkdir -p "$_cert_case_stage" || return 1
  cert_self_signed "staging.example.com" || return 1
  cp "$ESB_CERT_DIR/staging.example.com.crt" "$_cert_case_stage/use.example.com.crt" || return 1
  cp "$ESB_CERT_DIR/staging.example.com.key" "$_cert_case_stage/use.example.com.key" || return 1
  registry_add "use.example.com" "$_cert_case_stage/use.example.com.crt" \
    "$_cert_case_stage/use.example.com.key" "self-signed" "" || return 1

  # apply_change 在沙箱里可能失败（未部署内核/协议），这里只断言安装与状态写入
  cert_use "use.example.com" >/dev/null 2>&1
  assert_file "$ESB_CERT_DIR/use.example.com.crt" "cert_use 应把证书安装到证书目录" || return 1
  assert_file "$ESB_CERT_DIR/use.example.com.key" "cert_use 应把私钥安装到证书目录" || return 1
  assert_eq "$(state_get .cert.domain)" "use.example.com" "cert_use 应写入 .cert.domain" || return 1
  assert_eq "$(state_get .cert.crt)" "$ESB_CERT_DIR/use.example.com.crt" "cert_use 应写入 .cert.crt" || return 1
  assert_eq "$(state_get .cert.key)" "$ESB_CERT_DIR/use.example.com.key" "cert_use 应写入 .cert.key" || return 1
  assert_eq "$(state_get .cert.source)" "self-signed" "cert_use 应写入 .cert.source" || return 1
  assert_eq "$(registry_get use.example.com crt)" "$ESB_CERT_DIR/use.example.com.crt" \
    "cert_use 应把注册表路径更新到证书目录" || return 1

  # 安装后的文件应能被 openssl 解析（不是空文件/占位）
  openssl x509 -in "$ESB_CERT_DIR/use.example.com.crt" -noout -subject >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "安装后的证书应可解析" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 11. cert_detail：主体 / SAN / 颁发者 / 有效期
# ---------------------------------------------------------------------------
test_11_cert_detail() {
  state_init || return 1
  cert_self_signed "detail.example.com" || return 1
  local _cert_case_rc=0 _cert_case_out=""

  _cert_case_out="$(cert_detail "detail.example.com")"
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "已登记证书应能取到详情" || return 1
  assert_contains "$_cert_case_out" "detail.example.com" "详情应包含域名" || return 1
  assert_contains "$_cert_case_out" "DNS:detail.example.com" "详情应包含 SAN" || return 1

  cert_detail "missing.example.com" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "不存在的证书应干净报错" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 12. cert_tool_installed / cert_tool_install：就绪判定与幂等、离线干净失败
# ---------------------------------------------------------------------------
test_12_tool_install_idempotent() {
  state_init || return 1
  local _cert_case_rc=0

  assert_eq "$(cert_acme_home)" "${ESB_ROOT}/root/.acme.sh" "acme 目录应在沙箱根下" || return 1

  cert_tool_installed
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "未安装 acme.sh 时 cert_tool_installed 应返回 1" || return 1

  _cert_case_fake_acme || return 1
  cert_tool_installed
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "存在可执行 acme.sh 时应返回 0" || return 1

  # 已就绪时 cert_tool_install 必须幂等：不重新下载
  : >"${ESB_GATE_LOG:-/dev/null}"
  cert_tool_install "test@example.com" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "已安装时 cert_tool_install 应直接成功" || return 1
  assert_eq "$(printf '%s' "$(cat "${ESB_GATE_LOG:-/dev/null}" 2>/dev/null || true)" | grep -c . || true)" "0" \
    "已安装时不应再次执行安装命令" || return 1

  # 离线（沙箱 ESB_OFFLINE=1）下载失败 → 返回 1，且不杀死 shell
  rm -f "$(cert_acme_home)/acme.sh" || return 1
  ESB_OFFLINE=1 cert_tool_install "test@example.com" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "离线时安装 acme.sh 应干净失败" || return 1
  printf 'still alive\n' >"${ESB_TEST_WORK:-$ESB_DIR}/alive.txt" 2>/dev/null || true
  assert_file "${ESB_TEST_WORK:-$ESB_DIR}/alive.txt" "失败后 shell 应仍然存活" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 13. DNS 凭据：加载进 acme.sh 的环境，但绝不出现在命令行 / 日志里（硬规则 7）
#     用 ESB_GATE=0 + 沙箱内的假 acme.sh 观察真实子进程环境。
# ---------------------------------------------------------------------------
test_13_dns_env_not_on_cmdline() {
  state_init || return 1
  local _cert_case_dump="${ESB_TMP:-${TMPDIR:-/tmp}}/acme-dump.txt"
  local _cert_case_acme_home
  _cert_case_acme_home="$(cert_acme_home)"
  mkdir -p "$_cert_case_acme_home" || return 1
  # 假 acme.sh：把参数与关键环境变量落到 dump 文件（不联外网、不改系统）
  cat >"${_cert_case_acme_home}/acme.sh" <<EOF
#!/bin/sh
{
  env | grep -i '^CF_Token=' >"$_cert_case_dump"
  printf 'ARGS=%s\n' "\$*" >>"$_cert_case_dump"
} 2>/dev/null
exit 0
EOF
  chmod 755 "${_cert_case_acme_home}/acme.sh" || return 1

  mkdir -p "$ESB_SECRET_DIR" || return 1
  printf 'CF_Token=super-secret-token-1234\n' >"$ESB_SECRET_DIR/dns.env"
  chmod 600 "$ESB_SECRET_DIR/dns.env" 2>/dev/null || true

  local _cert_case_rc=0 _cert_case_out="" _cert_case_dump_text="" _cert_case_args=""
  _cert_case_out="$(ESB_GATE=0 cert_apply "dns.example.com" "dns:dns_cf" 2>&1)"
  _cert_case_rc=$?
  # 沙箱里 acme.sh 不会产出证书文件 → cert_apply 必须干净失败（不是 exit）
  assert_eq "$_cert_case_rc" "1" "假 acme.sh 未产出证书时 cert_apply 应干净失败" || return 1

  assert_file "$_cert_case_dump" "假 acme.sh 应被真正执行（ESB_GATE=0）" || return 1
  _cert_case_dump_text="$(cat "$_cert_case_dump" 2>/dev/null)"
  assert_contains "$_cert_case_dump_text" "CF_Token=super-secret-token-1234" \
    "dns.env 应被加载进 acme.sh 的环境" || return 1
  _cert_case_args="$(printf '%s\n' "$_cert_case_dump_text" | grep '^ARGS=' || true)"
  assert_contains "$_cert_case_args" "--dns dns_cf" "acme.sh 应收到 --dns dns_cf" || return 1
  case "$_cert_case_args" in
    *super-secret-token*) echo "凭据不得出现在 acme.sh 的命令行参数里" >&2; return 1 ;;
  esac
  case "$_cert_case_out" in
    *super-secret-token*) echo "凭据不得出现在证书申请的输出/日志里" >&2; return 1 ;;
  esac
  # 失败不得留下注册记录
  assert_eq "$(cert_list)" "" "申请失败不应留下注册记录" || return 1
  # 凭据文件本身权限不得被放宽（POSIX 平台）
  if _cert_case_posix_modes_ok; then
    assert_eq "$(_cert_case_mode "$ESB_SECRET_DIR/dns.env")" "600" "dns.env 权限应保持 600" || return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 14. acme.sh “成功”但没产出证书 → 干净失败、不登记、不动状态
# ---------------------------------------------------------------------------
test_14_acme_no_output_clean_error() {
  state_init || return 1
  _cert_case_fake_acme || return 1
  local _cert_case_rc=0
  local _cert_case_before=""
  _cert_case_before="$(state_get .cert.domain)"

  cert_apply "nooutput.example.com" "standalone" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "acme.sh 未产出证书时 cert_apply 应返回 1" || return 1
  assert_eq "$(cert_list)" "" "失败时不应登记注册表" || return 1
  assert_eq "$(state_get .cert.domain)" "$_cert_case_before" "失败时不应改动已应用证书" || return 1
  if [ -e "${ESB_CERT_DIR}/nooutput.example.com.crt" ]; then
    echo "失败时不应生成证书文件" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 15. cert_renew / cert_renew_all：acme 参数、自签证书不进 acme、renew_all 跳过自签
#     （用 ESB_GATE=0 + 沙箱内假 acme.sh 观察真实调用参数）
# ---------------------------------------------------------------------------
test_15_renew_args_and_all() {
  state_init || return 1
  local _cert_case_dump="${ESB_TMP:-${TMPDIR:-/tmp}}/acme-renew-dump.txt"
  local _cert_case_acme_home
  _cert_case_acme_home="$(cert_acme_home)"
  mkdir -p "$_cert_case_acme_home" || return 1
  cat >"${_cert_case_acme_home}/acme.sh" <<EOF
#!/bin/sh
printf 'ARGS=%s\n' "\$*" >>"$_cert_case_dump"
exit 0
EOF
  chmod 755 "${_cert_case_acme_home}/acme.sh" || return 1
  rm -f "$_cert_case_dump" 2>/dev/null || true

  local _cert_case_rc=0 _cert_case_dump_text=""

  # 自签证书不能走 acme 续期（且不得调用 acme.sh）
  cert_self_signed "self-rev.example.com" || return 1
  cert_renew "self-rev.example.com" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "自签证书应拒绝 acme 续期" || return 1
  if [ -e "$_cert_case_dump" ]; then
    echo "自签证书续期不应调用 acme.sh" >&2
    return 1
  fi

  # 未登记域名：交给 acme.sh --renew -d <域名>（默认**不加** --force）
  # 依据是实测：对刚签发 3 天的证书强续会被 CA 拒绝并白耗 Let's Encrypt 频率额度，
  # acme.sh 自己的行为是"未到时间就 Skipping"，因此默认不强制，仅在 ESB_CERT_FORCE=1 时才加 --force。
  ESB_GATE=0 cert_renew "loose.example.com" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "假 acme.sh 成功时续期应返回 0" || return 1
  _cert_case_dump_text="$(cat "$_cert_case_dump" 2>/dev/null)"
  assert_contains "$_cert_case_dump_text" "--renew -d loose.example.com" \
    "续期应调用 acme.sh --renew -d <域名>" || return 1
  assert_not_contains "$_cert_case_dump_text" "--force" \
    "默认不得使用 --force（会消耗 CA 频率额度；实测强续会被拒绝）" || return 1

  # ESB_CERT_FORCE=1 时才允许强制续期
  : >"$_cert_case_dump"
  ESB_GATE=0 ESB_CERT_FORCE=1 cert_renew "loose.example.com" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "ESB_CERT_FORCE=1 时续期仍应返回 0" || return 1
  assert_contains "$(cat "$_cert_case_dump" 2>/dev/null)" "--force" \
    "ESB_CERT_FORCE=1 时应带上 --force" || return 1

  # 已登记的 acme 证书：续期后要重新安装证书文件（沙箱无 acme 产物 → 干净失败）
  registry_add "acme-rev.example.com" "$ESB_CERT_DIR/acme-rev.example.com.crt" \
    "$ESB_CERT_DIR/acme-rev.example.com.key" "acme" "" || return 1
  ESB_GATE=0 cert_renew "acme-rev.example.com" >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "1" "续期成功但取不到证书文件时应返回 1" || return 1

  # cert_renew_all：注册表里只剩自签证书 → 全部跳过并返回 0，且不调用 acme.sh
  registry_remove "acme-rev.example.com" || return 1
  : >"$_cert_case_dump"
  cert_renew_all >/dev/null 2>&1
  _cert_case_rc=$?
  assert_eq "$_cert_case_rc" "0" "只有自签证书时 renew_all 应成功结束（跳过）" || return 1
  assert_eq "$(cat "$_cert_case_dump" 2>/dev/null)" "" "renew_all 不应为自签证书调用 acme.sh" || return 1
  return 0
}

# 16. 同一域名下"自签证书"与"域名证书"的文件必须分开（否则按协议切换证书模式会互相覆盖）
test_16_selfsigned_paths_do_not_clash() {
  state_init >/dev/null 2>&1 || return 1
  cert_self_signed "clash.example.com" >/dev/null 2>&1 || { _harness_fail "生成自签证书失败"; return 1; }

  local _t16_selfsigned _t16_selfsigned_key _t16_acme_style
  _t16_selfsigned="$(cert_selfsigned_paths clash.example.com | cut -f1)"
  _t16_selfsigned_key="$(cert_selfsigned_paths clash.example.com | cut -f2)"
  _t16_acme_style="${ESB_CERT_DIR}/clash.example.com.crt"

  assert_file "$_t16_selfsigned" "自签证书应存在" || return 1
  assert_file "$_t16_selfsigned_key" "自签密钥应存在" || return 1
  assert_ne "$_t16_selfsigned" "$_t16_acme_style" "自签证书路径不能与域名证书路径相同" || return 1
  assert_contains "$_t16_selfsigned" "self-signed-" "自签证书路径应带 self-signed- 前缀" || return 1
  assert_fail "此时 <域名>.crt 不应存在（还没申请域名证书）" test -f "$_t16_acme_style" || return 1

  # 模拟已有域名证书：两份文件必须同时存在且内容不同
  printf 'ACME-CERT-PLACEHOLDER\n' >"$_t16_acme_style" || return 1
  assert_file "$_t16_selfsigned" "放入域名证书后自签证书仍应在" || return 1
  assert_ne "$(cat "$_t16_selfsigned")" "$(cat "$_t16_acme_style")" "两份证书内容应各自独立" || return 1

  # 协议解析：同一个域名下不同协议取到不同文件
  sandbox_seed_state >/dev/null 2>&1 || true
  state_set_str ".domain" "clash.example.com" || return 1
  state_set_str ".cert.source" "acme:webroot" || return 1
  state_set_str ".cert.crt" "$_t16_acme_style" || return 1
  mkdir -p "$ESB_CERT_DIR" || return 1
  printf 'FAKE-KEY\n' >"${ESB_CERT_DIR}/clash.example.com.key" || return 1
  state_set_str ".cert.key" "${ESB_CERT_DIR}/clash.example.com.key" || return 1
  proto_cert_mode_set anytls self-signed || return 1
  proto_cert_mode_set hysteria2 auto || return 1
  assert_eq "$(cert_files_for_proto anytls | cut -f1)" "$_t16_selfsigned" \
    "自签协议的证书应指向 self-signed-<域名>.crt" || return 1
  assert_eq "$(cert_files_for_proto hysteria2 | cut -f1)" "$_t16_acme_style" \
    "域名证书协议的证书应指向 <域名>.crt" || return 1
  return 0
}
