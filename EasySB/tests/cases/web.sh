#!/usr/bin/env bash
# =============================================================================
# EasySB — tests/cases/web.sh
# 70-web.sh（伪装站点）用例：模板列表 / 部署（含 ACME location 与 nginx -t 顺序）/
#                            ACME webroot / 443 证书与端口冲突拒绝 / 关闭 / 端口检查 /
#                            绝不触碰其它站点配置
# 由 tests/run_tests.sh 在沙箱里 source（已加载 lib/*.sh 与沙箱环境变量）
# =============================================================================
# shellcheck shell=bash

TESTS="test_1_web_templates_tsv test_2_web_deploy_blog_conf test_3_web_acme_webroot test_4_web_apply_cert_refuses_port_conflict test_5_web_disable_keeps_webroot test_6_web_deploy_proxy_only_conf test_7_web_apply_cert_writes_443 test_8_web_port_free test_9_web_deploy_keeps_other_sites"

# ---------------------------------------------------------------------------
# 本地助手（只使用公共 API 与环境变量；不覆盖 runner 的沙箱设置）
# ---------------------------------------------------------------------------
# runner 未提供时补齐派生路径（与 easysb.sh 的派生规则一致）
_webt_env() {
  if [ -z "${ESB_DIR:-}" ];    then ESB_DIR="${ESB_ROOT}/etc/easysb"; fi
  if [ -z "${ESB_STATE:-}" ];  then ESB_STATE="${ESB_DIR}/state.json"; fi
  if [ -z "${ESB_LOG:-}" ];    then ESB_LOG="${ESB_DIR}/easysb.log"; fi
  if [ -z "${ESB_SECRET_DIR:-}" ]; then ESB_SECRET_DIR="${ESB_DIR}/secrets"; fi
  if [ -z "${ESB_CLIENT_DIR:-}" ]; then ESB_CLIENT_DIR="${ESB_DIR}/client"; fi
  if [ -z "${ESB_BACKUP_DIR:-}" ]; then ESB_BACKUP_DIR="${ESB_ROOT}/var/backups/easysb"; fi
  if [ -z "${ESB_CONF_DIR:-}" ];   then ESB_CONF_DIR="${ESB_ROOT}/etc/sing-box"; fi
  if [ -z "${ESB_CONFIG:-}" ];     then ESB_CONFIG="${ESB_CONF_DIR}/config.json"; fi
  if [ -z "${ESB_CERT_DIR:-}" ];   then ESB_CERT_DIR="${ESB_CONF_DIR}/certs"; fi
  if [ -z "${ESB_TMP:-}" ];        then ESB_TMP="${ESB_ROOT}/tmp"; fi
  mkdir -p "$ESB_TMP" 2>/dev/null || true
  return 0
}

# 契约路径（独立于被测代码自己的推导，写死在用例里）
_webt_root()     { printf '%s\n' "${ESB_WEB_ROOT:-${ESB_ROOT}/var/www/easysb}"; }
_webt_conf()     { printf '%s\n' "${ESB_NGINX_CONF:-${ESB_ROOT}/etc/nginx/conf.d/easysb.conf}"; }
_webt_gate_log() { printf '%s\n' "${ESB_GATE_LOG:-${ESB_TEST_WORK:-/tmp}/gate.log}"; }
_webt_cat()      { cat "$1" 2>/dev/null; }

# gate 日志里第一处匹配的行号（用于断言 nginx -t 早于 reload）
_webt_gate_line() {
  grep -nE "$1" "$(_webt_gate_log)" 2>/dev/null | head -1 | cut -d: -f1
}

# 干净起点：清掉本工具自己的产物（站点根目录、我们的 conf 与其备份）并初始化 state
_webt_prepare() {
  _webt_env
  mkdir -p "$(dirname "$(_webt_conf)")" || return 1
  rm -f "$(_webt_conf)" "$(_webt_conf).easysb.bak" 2>/dev/null || true
  rm -rf "$(_webt_root)" 2>/dev/null || true
  : >"$(_webt_gate_log)" 2>/dev/null || true
  if ! state_init >/dev/null 2>&1; then
    echo "准备失败：state_init 无法创建 $ESB_STATE" >&2
    return 1
  fi
  return 0
}

# 造一对假证书文件（不联网）并注册到 state，模拟"已申请并应用证书"
_webt_fake_cert() {
  mkdir -p "$ESB_CERT_DIR" || return 1
  printf 'EASYSB-TEST-CRT\n' >"${ESB_CERT_DIR}/test.crt" || return 1
  printf 'EASYSB-TEST-KEY\n' >"${ESB_CERT_DIR}/test.key" || return 1
  state_set_str ".cert.crt" "${ESB_CERT_DIR}/test.crt" >/dev/null 2>&1 || return 1
  state_set_str ".cert.key" "${ESB_CERT_DIR}/test.key" >/dev/null 2>&1 || return 1
  state_set_str ".cert.domain" "node.example.com" >/dev/null 2>&1 || true
  return 0
}

# ---------------------------------------------------------------------------
# 1) 模板列表：TSV、5 行、key 唯一
# ---------------------------------------------------------------------------
test_1_web_templates_tsv() {
  local out n_lines n_keys line n_fields
  out="$(web_templates)" || return 1
  n_lines="$(printf '%s\n' "$out" | grep -c .)"
  assert_eq "5" "$n_lines" "web_templates 必须输出 5 行模板" || return 1
  n_keys="$(printf '%s\n' "$out" | cut -f1 | sort -u | grep -c .)"
  assert_eq "5" "$n_keys" "模板 key 必须互不重复" || return 1
  assert_eq "$(printf 'blog\t个人博客')" "$(printf '%s\n' "$out" | head -1)" \
    "第一行必须是 blog<TAB>个人博客" || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n_fields="$(printf '%s' "$line" | awk -F"$(printf '\t')" '{print NF}')"
    if [ "$n_fields" != "2" ]; then
      echo "断言失败：模板行不是两列 TSV：[$line]" >&2
      return 1
    fi
  done <<EOF
$out
EOF
  assert_contains "$(printf '%s\n' "$out" | cut -f1)" "blog" "必须含 blog 模板" || return 1
  assert_contains "$(printf '%s\n' "$out" | cut -f1)" "proxy" "必须含 proxy 模板" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 2) 部署 blog：配置带管理标记 + ACME location，且 nginx -t 早于 reload
# ---------------------------------------------------------------------------
test_2_web_deploy_blog_conf() {
  _webt_prepare || return 1
  local conf body index body_index t_line r_line
  conf="$(_webt_conf)"
  index="$(_webt_root)/index.html"

  assert_ok "部署 blog 模板" web_deploy blog || return 1
  assert_file "$conf" "web_deploy 必须生成 nginx 配置 $conf" || return 1

  body="$(_webt_cat "$conf")"
  assert_contains "$body" "EasySB-MANAGED" "nginx 配置必须带 EasySB 管理标记" || return 1
  assert_contains "$body" "location /.well-known/acme-challenge/" "配置必须包含 ACME 挑战目录 location" || return 1
  assert_contains "$body" "$(_webt_root);" "ACME location 的 root 必须是站点根目录" || return 1
  assert_contains "$body" "listen 80;" "配置必须监听 80" || return 1

  assert_file "$index" "blog 模板必须生成 index.html" || return 1
  body_index="$(_webt_cat "$index")"
  assert_contains "$body_index" "<html" "首页必须是完整 HTML（nginx 应返回 200）" || return 1
  assert_contains "$body_index" "云间笔记" "blog 首页必须含中文内容" || return 1

  assert_json "$ESB_STATE" '.web.enabled' 'true' || return 1
  assert_json "$ESB_STATE" '.web.template' 'blog' || return 1

  # nginx -t 必须先于 reload（gate 日志里记录的是系统变更命令）
  assert_contains "$(_webt_cat "$(_webt_gate_log)")" "nginx -t" "部署必须先执行 nginx -t（gate 日志）" || return 1
  assert_contains "$(_webt_cat "$(_webt_gate_log)")" "reload" "部署必须执行 nginx reload（gate 日志）" || return 1
  t_line="$(_webt_gate_line 'nginx -t')"
  r_line="$(_webt_gate_line 'reload')"
  if [ -z "$t_line" ] || [ -z "$r_line" ] || [ "$t_line" -ge "$r_line" ]; then
    echo "断言失败：gate 日志中 nginx -t（第 ${t_line:-无} 行）必须早于 reload（第 ${r_line:-无} 行）" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 3) ACME webroot：输出路径并创建目录
# ---------------------------------------------------------------------------
test_3_web_acme_webroot() {
  _webt_prepare || return 1
  local dir
  dir="$(web_acme_webroot)" || return 1
  assert_eq "$(_webt_root)/.well-known/acme-challenge" "$dir" \
    "web_acme_webroot 必须输出 <webroot>/.well-known/acme-challenge" || return 1
  assert_ok "ACME 挑战目录必须被创建" test -d "$dir" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 4) 443 被已启用协议占用时必须拒绝（这是最容易出的端口冲突缺陷）
# ---------------------------------------------------------------------------
test_4_web_apply_cert_refuses_port_conflict() {
  _webt_prepare || return 1
  local conf body rc
  conf="$(_webt_conf)"

  assert_ok "先部署 80 站点" web_deploy blog || return 1
  _webt_fake_cert || return 1
  state_set ".web.tls" "true" >/dev/null 2>&1 || return 1
  state_set ".web.tls_port" "443" >/dev/null 2>&1 || return 1
  state_set '.protocols["vless-vision-reality"].enabled' "true" >/dev/null 2>&1 || return 1
  state_set '.protocols["vless-vision-reality"].port' "443" >/dev/null 2>&1 || return 1

  web_apply_cert >/dev/null 2>&1
  rc=$?
  assert_eq "1" "$rc" "443 被 vless-vision-reality 占用时 web_apply_cert 必须返回 1" || return 1
  assert_fail "端口被启用协议占用时必须拒绝写入 443 配置" web_apply_cert || return 1

  body="$(_webt_cat "$conf")"
  assert_contains "$body" "listen 80;" "拒绝后必须保留 80 单端口站点" || return 1
  if printf '%s\n' "$body" | grep -qE '^[[:space:]]*listen[[:space:]]+(\[::\]:)?443([[:space:];]|$)'; then
    echo "断言失败：被拒绝时不得写入 443 站点（配置里出现了 listen 443）" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 5) 关闭站点：删除配置、保留站点根目录内容、状态置 false
# ---------------------------------------------------------------------------
test_5_web_disable_keeps_webroot() {
  _webt_prepare || return 1
  local conf root
  conf="$(_webt_conf)"
  root="$(_webt_root)"

  assert_ok "部署 blog" web_deploy blog || return 1
  assert_file "$conf" "部署后配置必须存在" || return 1

  : >"$(_webt_gate_log)" 2>/dev/null || true
  assert_ok "关闭伪装站点" web_disable || return 1

  if [ -f "$conf" ]; then
    echo "断言失败：web_disable 必须删除本工具的 nginx 配置 $conf" >&2
    return 1
  fi
  assert_file "${root}/index.html" "web_disable 必须保留站点根目录内容" || return 1
  assert_json "$ESB_STATE" '.web.enabled' 'false' || return 1
  assert_contains "$(_webt_cat "$(_webt_gate_log)")" "nginx -t" "关闭时也必须先执行 nginx -t" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 6) proxy 模板：只写 nginx 配置（proxy_pass + Host 头保留），不生成 index.html
# ---------------------------------------------------------------------------
test_6_web_deploy_proxy_only_conf() {
  _webt_prepare || return 1
  local conf body rc
  conf="$(_webt_conf)"

  web_deploy proxy >/dev/null 2>&1
  rc=$?
  assert_eq "1" "$rc" "proxy 模板缺少反代目标时必须返回 1" || return 1
  if [ -f "$conf" ]; then
    echo "断言失败：被拒绝的部署不得留下 nginx 配置" >&2
    return 1
  fi

  state_set_str ".web.proxy_target" "https://example.org/" >/dev/null 2>&1 || return 1
  assert_ok "部署 proxy 模板" web_deploy proxy || return 1
  body="$(_webt_cat "$conf")"
  assert_contains "$body" "proxy_pass https://example.org;" \
    "proxy_pass 必须指向 .web.proxy_target（去掉尾部斜杠）" || return 1
  assert_contains "$body" 'proxy_set_header Host $host;' "必须保留 Host 头" || return 1
  assert_contains "$body" "location /.well-known/acme-challenge/" \
    "反向代理站点同样要保留 ACME 挑战目录" || return 1
  if [ -f "$(_webt_root)/index.html" ]; then
    echo "断言失败：proxy 模板只写 nginx 配置，不得生成 index.html" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 7) 无冲突时把已应用证书写进 443 配置
# ---------------------------------------------------------------------------
test_7_web_apply_cert_writes_443() {
  _webt_prepare || return 1
  local conf body crt key
  conf="$(_webt_conf)"
  crt="${ESB_CERT_DIR}/test.crt"
  key="${ESB_CERT_DIR}/test.key"

  assert_ok "部署 blog" web_deploy blog || return 1
  _webt_fake_cert || return 1
  state_set ".web.tls" "true" >/dev/null 2>&1 || return 1

  : >"$(_webt_gate_log)" 2>/dev/null || true
  assert_ok "应用证书（写入 443）" web_apply_cert || return 1

  body="$(_webt_cat "$conf")"
  assert_contains "$body" "listen 443 ssl" "必须写入 443 ssl 监听" || return 1
  if ! printf '%s\n' "$body" | grep -qE "^[[:space:]]*ssl_certificate[[:space:]]+${crt};"; then
    echo "断言失败：ssl_certificate 必须使用 state 中的证书路径 $crt" >&2
    return 1
  fi
  if ! printf '%s\n' "$body" | grep -qE "^[[:space:]]*ssl_certificate_key[[:space:]]+${key};"; then
    echo "断言失败：ssl_certificate_key 必须使用 state 中的私钥路径 $key" >&2
    return 1
  fi
  assert_contains "$body" "listen 80;" "启用 443 后 80 站点仍必须保留" || return 1
  assert_contains "$(_webt_cat "$(_webt_gate_log)")" "nginx -t" "写入 443 前必须执行 nginx -t" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 8) 端口可用性检查（空闲端口可用、非法端口拒绝）
# ---------------------------------------------------------------------------
test_8_web_port_free() {
  _webt_prepare || return 1
  local rc
  assert_ok "空闲的高位端口必须判定为可用" web_port_free 54321 || return 1
  assert_fail "超出范围的端口必须被拒绝" web_port_free 99999 || return 1
  web_port_free "" >/dev/null 2>&1
  rc=$?
  assert_eq "1" "$rc" "空端口必须返回 1" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 9) 绝不触碰其它站点的 nginx 配置（硬规则）
# ---------------------------------------------------------------------------
test_9_web_deploy_keeps_other_sites() {
  _webt_prepare || return 1
  local other
  other="$(dirname "$(_webt_conf)")/other-site.conf"
  printf '# 其它站点，EasySB 不得修改\nserver { listen 8080; }\n' >"$other" || return 1

  assert_ok "部署 blog" web_deploy blog || return 1
  assert_file "$other" "部署不得删除其它站点的配置" || return 1
  assert_contains "$(_webt_cat "$other")" "listen 8080;" "部署不得改动其它站点配置的内容" || return 1

  assert_ok "关闭伪装站点" web_disable || return 1
  assert_file "$other" "关闭伪装站点后其它站点配置仍必须存在" || return 1
  return 0
}
