#!/usr/bin/env bash
# =============================================================================
# EasySB — 80-subscribe.sh
# 节点链接与订阅：分享链接输出、多格式订阅文件（base64 通用 / sing-box JSON /
# Mihomo(Clash) YAML）、订阅站点（复用伪装站点或独立 nginx 站点）、订阅 URL 与二维码
# 依赖：00-core.sh, 10-detect.sh, 20-state.sh, 40-render.sh
# =============================================================================
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# token / 路径
# ---------------------------------------------------------------------------
sub_token() {
  local _sub_token_tok
  _sub_token_tok="$(state_get .sub.token)"
  if [ -z "$_sub_token_tok" ]; then
    _sub_token_tok="$(gen_hex 16)"
    state_set_str ".sub.token" "$_sub_token_tok" || return 1
  fi
  printf '%s\n' "$_sub_token_tok"
  return 0
}

sub_token_regen() {
  local _sub_token_regen_tok
  _sub_token_regen_tok="$(gen_hex 16)"
  state_set_str ".sub.token" "$_sub_token_regen_tok" || return 1
  printf '%s\n' "$_sub_token_regen_tok"
  return 0
}

# 订阅是否复用伪装站点（伪装站点开启时自动复用）
sub_use_site() {
  if [ "$(state_get .web.enabled)" = "true" ] && [ "$(state_get .sub.serve_via_site)" = "true" ]; then
    return 0
  fi
  return 1
}

sub_url_base() {
  local _sub_url_base_domain _sub_url_base_scheme _sub_url_base_port="" _sub_url_base_wport=""
  _sub_url_base_domain="$(state_get .domain)"
  if sub_use_site; then
    if [ "$(state_get .web.tls)" = "true" ] && [ -f "$(state_get .cert.crt)" ]; then
      _sub_url_base_scheme="https"
      _sub_url_base_wport="$(state_get .web.tls_port)"
      [ "$_sub_url_base_wport" = "443" ] || _sub_url_base_port=":${_sub_url_base_wport}"
    else
      _sub_url_base_scheme="http"
      _sub_url_base_wport="$(state_get .web.http_port)"
      [ "$_sub_url_base_wport" = "80" ] || _sub_url_base_port=":${_sub_url_base_wport}"
    fi
    printf '%s://%s%s/sub/%s\n' "$_sub_url_base_scheme" "$_sub_url_base_domain" "$_sub_url_base_port" "$(sub_token)"
  else
    _sub_url_base_port="$(state_get .sub.port)"; [ -n "$_sub_url_base_port" ] || _sub_url_base_port=8080
    [ "$_sub_url_base_port" = "80" ] || _sub_url_base_port=":${_sub_url_base_port}"
    printf 'http://%s%s/sub/%s\n' "$_sub_url_base_domain" "$_sub_url_base_port" "$(sub_token)"
  fi
  return 0
}

# 订阅文件所在目录（token 目录）
sub_dir() {
  local _sub_dir_root=""
  if sub_use_site; then
    # 站点根目录以 web 模块的解析结果为准（它保证路径落在 ESB_ROOT 之下）
    if command -v _web_root >/dev/null 2>&1; then
      _sub_dir_root="$(_web_root)"
    else
      _sub_dir_root="$(esb_rooted "$(state_get .web.root)")"
    fi
  else
    _sub_dir_root="$(esb_rooted "$(state_get .sub.root)")"
  fi
  [ -n "$_sub_dir_root" ] || _sub_dir_root="${ESB_ROOT}/var/www/easysb-sub"
  printf '%s/sub/%s\n' "$_sub_dir_root" "$(sub_token)"
  return 0
}

sub_formats() {
  cat <<'EOF'
base64	通用订阅（v2rayN / Shadowrocket / NekoBox 等，Base64 节点列表）
links	纯文本节点链接（每行一条）
singbox	sing-box 客户端配置（按仓库 Templates/tun-fakeip.json 的 TUN + FakeIP + 规则分流模板生成）
singbox-mixed	sing-box 精简配置（mixed 入站 10000 + 五条节点，适合只当本地代理用）
mihomo	Mihomo / Clash 配置（按仓库 Mihomo 模板生成：fake-ip DNS + sniffer + 负载均衡/自动选择/手动选择）
EOF
  return 0
}

# ---------------------------------------------------------------------------
# 生成内容
# ---------------------------------------------------------------------------
sub_links_text() {
  local _sub_links_text_l
  render_links | while IFS= read -r _sub_links_text_l; do
    [ -n "$_sub_links_text_l" ] || continue
    printf '%s\n' "$_sub_links_text_l"
  done
  return 0
}

sub_links_base64() {
  sub_links_text | base64 | tr -d '\n'
  printf '\n'
  return 0
}

_mihomo_yaml_quote() {
  # YAML 双引号字符串转义（值里可能出现的反斜杠与双引号都要转义）
  local _mhq_s="$1"
  _mhq_s="$(printf '%s' "$_mhq_s" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  printf '"%s"' "$_mhq_s"
  return 0
}

sub_mihomo_yaml() {
  local _mh_domain _mh_port _mh_p _mh_name _mh_names=""
  _mh_domain="$(state_get .domain)"
  [ -n "$_mh_domain" ] || { error "尚未设置域名，无法生成 Mihomo 配置"; return 1; }

  # 结构对齐仓库 Mihomo 模板：顶层端口/DNS(fake-ip)/sniffer → proxies → 三个策略组 → 四条规则
  printf '# EasySB 订阅 · Mihomo / Clash 配置（按仓库 Mihomo 模板生成）\n'
  printf 'port: 7890\n'
  printf 'allow-lan: true\n'
  printf 'mode: rule\n'
  printf 'log-level: info\n'
  printf 'unified-delay: true\n'
  printf '\n'
  printf 'dns:\n'
  printf '  enable: true\n'
  printf '  listen: "0.0.0.0:1053"\n'
  printf '  ipv6: true\n'
  printf '  prefer-h3: false\n'
  printf '  respect-rules: true\n'
  printf '  use-system-hosts: false\n'
  printf '  cache-algorithm: "arc"\n'
  printf '  enhanced-mode: fake-ip\n'
  printf '  fake-ip-range: 198.18.0.1/16\n'
  printf '\n'
  printf '  fake-ip-filter:\n'
  printf '    - "+.lan"\n'
  printf '    - "+.local"\n'
  printf '    - "+.msftconnecttest.com"\n'
  printf '    - "+.msftncsi.com"\n'
  printf '    - "localhost.ptlogin2.qq.com"\n'
  printf '    - "localhost.sec.qq.com"\n'
  printf '    - "+.in-addr.arpa"\n'
  printf '    - "+.ip6.arpa"\n'
  printf '    - "time.*.com"\n'
  printf '    - "time.*.gov"\n'
  printf '    - "pool.ntp.org"\n'
  printf '    - "localhost.work.weixin.qq.com"\n'
  printf '\n'
  printf '  default-nameserver:\n'
  printf '    - "223.5.5.5"\n'
  printf '    - "119.29.29.29"\n'
  printf '\n'
  printf '  nameserver:\n'
  printf '    - "https://1.1.1.1/dns-query"\n'
  printf '    - "https://8.8.8.8/dns-query"\n'
  printf '\n'
  printf '  proxy-server-nameserver:\n'
  printf '    - "https://223.5.5.5/dns-query"\n'
  printf '    - "https://doh.pub/dns-query"\n'
  printf '\n'
  printf 'sniffer:\n'
  printf '  enable: true\n'
  printf '  sniff:\n'
  printf '    HTTP:\n'
  printf '      ports:\n'
  printf '        - 80\n'
  printf '        - 8080\n'
  printf '    TLS:\n'
  printf '      ports:\n'
  printf '        - 443\n'
  printf '        - 8443\n'
  printf '    QUIC:\n'
  printf '      ports:\n'
  printf '        - 443\n'
  printf '        - 8443\n'
  printf '\n'
  printf 'proxies:\n'

  for _mh_p in $(proto_enabled_list); do
    _mh_port="$(proto_port "$_mh_p")"
    case "$_mh_p" in
      vless-vision-reality) _mh_name="vless-reality-vision-${_mh_domain}" ;;
      vmess-ws-tls)
        # 与分享链接一致：域名证书才叫 vmess-ws-tls，自签/关闭 TLS 叫 vmess-ws
        if [ "$(vmess_display_name)" = "VMess-WS-TLS" ]; then
          _mh_name="vmess-ws-tls-${_mh_domain}"
        else
          _mh_name="vmess-ws-${_mh_domain}"
        fi
        ;;
      hysteria2)            _mh_name="hysteria2-${_mh_domain}" ;;
      tuic)                 _mh_name="tuic5-${_mh_domain}" ;;
      anytls)               _mh_name="anytls-${_mh_domain}" ;;
      *)                    _mh_name="${_mh_p}-${_mh_domain}" ;;
    esac
    _mh_names="$_mh_names $_mh_name"
    case "$_mh_p" in
      vless-vision-reality)
        printf '  - name: %s\n' "$_mh_name"
        printf '    type: vless\n'
        printf '    server: %s\n' "$_mh_domain"
        printf '    port: %s\n' "$_mh_port"
        printf '    uuid: %s\n' "$(secret_get vless_uuid)"
        printf '    network: tcp\n'
        printf '    udp: true\n'
        printf '    tls: true\n'
        printf '    flow: xtls-rprx-vision\n'
        printf '    servername: %s\n' "$(state_get .reality.server_name)"
        printf '    reality-opts:\n'
        printf '      public-key: %s\n' "$(state_get .reality.public_key)"
        printf '      short-id: %s\n' "$(state_get .reality.short_id)"
        printf '    client-fingerprint: chrome\n'
        ;;
      vmess-ws-tls)
        printf '  - name: %s\n' "$_mh_name"
        printf '    type: vmess\n'
        printf '    server: %s\n' "$_mh_domain"
        printf '    port: %s\n' "$_mh_port"
        printf '    uuid: %s\n' "$(secret_get vmess_uuid)"
        printf '    alterId: 0\n'
        printf '    cipher: auto\n'
        printf '    udp: true\n'
        if [ "$(proto_tls_enabled vmess-ws-tls)" = "true" ]; then
          printf '    tls: true\n'
          printf '    skip-cert-verify: %s\n' "$(_sub_yaml_bool "$(proto_insecure_json vmess-ws-tls)")"
        else
          printf '    tls: false\n'
        fi
        printf '    network: ws\n'
        printf '    servername: %s\n' "$_mh_domain"
        printf '    ws-opts:\n'
        printf '      path: "%s"\n' "$(state_get '.protocols["vmess-ws-tls"].path')"
        printf '      headers:\n'
        printf '        Host: %s\n' "$_mh_domain"
        ;;
      hysteria2)
        printf '  - name: %s\n' "$_mh_name"
        printf '    type: hysteria2\n'
        printf '    server: %s\n' "$_mh_domain"
        printf '    port: %s\n' "$_mh_port"
        if [ "$(state_get '.protocols.hysteria2.hop.enabled')" = "true" ]; then
          printf '    ports: %s\n' "$(state_get '.protocols.hysteria2.hop.range')"
        fi
        printf '    password: %s\n' "$(secret_get hysteria2_password)"
        printf '    alpn:\n'
        printf '      - h3\n'
        printf '    sni: %s\n' "$_mh_domain"
        printf '    skip-cert-verify: %s\n' "$(_sub_yaml_bool "$(proto_insecure_json hysteria2)")"
        printf '    fast-open: true\n'
        ;;
      tuic)
        printf '  - name: %s\n' "$_mh_name"
        printf '    type: tuic\n'
        printf '    server: %s\n' "$_mh_domain"
        printf '    port: %s\n' "$_mh_port"
        printf '    uuid: %s\n' "$(secret_get tuic_uuid)"
        printf '    password: %s\n' "$(secret_get tuic_password)"
        printf '    alpn:\n'
        printf '      - h3\n'
        printf '    disable-sni: false\n'
        printf '    reduce-rtt: true\n'
        printf '    udp-relay-mode: native\n'
        printf '    congestion-controller: bbr\n'
        printf '    sni: %s\n' "$_mh_domain"
        printf '    skip-cert-verify: %s\n' "$(_sub_yaml_bool "$(proto_insecure_json tuic)")"
        ;;
      anytls)
        printf '  - name: %s\n' "$_mh_name"
        printf '    type: anytls\n'
        printf '    server: %s\n' "$_mh_domain"
        printf '    port: %s\n' "$_mh_port"
        printf '    password: %s\n' "$(secret_get anytls_password)"
        printf '    sni: %s\n' "$_mh_domain"
        printf '    skip-cert-verify: %s\n' "$(_sub_yaml_bool "$(proto_insecure_json anytls)")"
        printf '    udp: true\n'
        printf '    client-fingerprint: chrome\n'
        ;;
    esac
  done

  local _mh_proxies="" _mh_n
  for _mh_n in $_mh_names; do
    _mh_proxies="${_mh_proxies}      - ${_mh_n}\n"
  done

  printf '\n'
  printf 'proxy-groups:\n'
  printf '\n'
  printf '  - name: 负载均衡\n'
  printf '    type: load-balance\n'
  printf '    url: https://www.gstatic.com/generate_204\n'
  printf '    interval: 300\n'
  printf '    strategy: round-robin\n'
  printf '    proxies:\n'
  printf '%b' "$_mh_proxies"
  printf '\n'
  printf '  - name: 自动选择\n'
  printf '    type: url-test\n'
  printf '    url: https://www.gstatic.com/generate_204\n'
  printf '    interval: 300\n'
  printf '    tolerance: 50\n'
  printf '    proxies:\n'
  printf '%b' "$_mh_proxies"
  printf '\n'
  printf '  - name: 🌍选择代理节点\n'
  printf '    type: select\n'
  printf '    proxies:\n'
  printf '      - 负载均衡\n'
  printf '      - 自动选择\n'
  printf '      - DIRECT\n'
  printf '%b' "$_mh_proxies"
  printf '\n'
  printf 'rules:\n'
  printf '  - GEOIP,LAN,DIRECT\n'
  printf '  - GEOSITE,CN,DIRECT\n'
  printf '  - GEOIP,CN,DIRECT\n'
  printf '  - MATCH,🌍选择代理节点\n'
  return 0
}

sub_singbox_json() {
  local _sub_singbox_json_src="${ESB_CLIENT_DIR}/all.json"
  [ -f "$_sub_singbox_json_src" ] || { render_client_all || return 1; }
  cat "$_sub_singbox_json_src"
  return 0
}

# ---------------------------------------------------------------------------
# sing-box TUN 模板（按仓库 Templates/tun-fakeip.json 生成）
# 做法：拉取仓库模板 → 去掉 JSONC 注释 → 只把"节点类" outbound 换成我们生成的，
#       其余（dns / inbounds / route / rule_set / experimental / 策略组 / direct）原样保留。
# ---------------------------------------------------------------------------
_sub_singbox_tpl_raw()  { printf '%s\n' "${ESB_SUB_SINGBOX_TPL_URL:-https://raw.githubusercontent.com/${ESB_REPO}/${ESB_REPO_BRANCH}/Templates/tun-fakeip.json}"; }
_sub_singbox_tpl_file() { printf '%s\n' "${ESB_DIR}/templates/tun-fakeip.jsonc"; }

# 获取模板（带缓存；离线时用缓存；都没有则失败）
sub_singbox_template() {
  local _sub_tpl_url _sub_tpl_file _sub_tpl_age=""
  _sub_tpl_url="$(_sub_singbox_tpl_raw)"
  _sub_tpl_file="$(_sub_singbox_tpl_file)"
  mkdir -p "$(dirname "$_sub_tpl_file")" 2>/dev/null || true
  if [ -f "$_sub_tpl_file" ]; then
    _sub_tpl_age="$(find "$_sub_tpl_file" -mtime +7 2>/dev/null)"
    [ -n "$_sub_tpl_age" ] || { printf '%s\n' "$_sub_tpl_file"; return 0; }
  fi
  if [ "${ESB_OFFLINE:-0}" = "1" ]; then
    [ -f "$_sub_tpl_file" ] && { printf '%s\n' "$_sub_tpl_file"; return 0; }
    error "离线模式下没有缓存的 sing-box 模板"
    return 1
  fi
  local _sub_tpl_tmp="${_sub_tpl_file}.tmp.$$"
  if http_get "$_sub_tpl_url" "$_sub_tpl_tmp"; then
    mv -f "$_sub_tpl_tmp" "$_sub_tpl_file" 2>/dev/null || true
    printf '%s\n' "$_sub_tpl_file"
    return 0
  fi
  rm -f "$_sub_tpl_tmp" 2>/dev/null || true
  if [ -f "$_sub_tpl_file" ]; then
    log_warn "无法更新 sing-box 模板，改用本地缓存"
    printf '%s\n' "$_sub_tpl_file"
    return 0
  fi
  error "无法获取 sing-box 模板：$_sub_tpl_url"
  return 1
}

# JSONC → JSON（字符串感知：URL 里的 // 不会被当成注释）
_sub_jsonc_strip() {
  awk '
    BEGIN { q = sprintf("%c", 34); bs = sprintf("%c", 92); instr = 0; esc = 0; inblock = 0 }
    {
      line = $0; out = ""; i = 1; n = length(line)
      while (i <= n) {
        c = substr(line, i, 1)
        if (instr) {
          out = out c
          if (esc) { esc = 0 }
          else if (c == bs) { esc = 1 }
          else if (c == q) { instr = 0 }
          i++; continue
        }
        if (c == q) { instr = 1; out = out c; i++; continue }
        nxt = substr(line, i + 1, 1)
        if (c == "/" && nxt == "/") { break }
        if (c == "/" && nxt == "*") { inblock = 1; i += 2; continue }
        if (inblock && c == "*" && nxt == "/") { inblock = 0; i += 2; continue }
        if (!inblock) { out = out c }
        i++
      }
      print out
    }
  '
}

# 按标签把模板里的节点 outbound 换成我们生成的（策略组 / direct / 其余配置保持模板原样）
sub_singbox_tun_json() {
  local _sub_tun_tpl _sub_tun_clean _sub_tun_p _sub_tun_node=""
  _sub_tun_tpl="$(sub_singbox_template)" || return 1
  _sub_tun_clean="${ESB_TMP}/tun-fakeip.json"
  _sub_jsonc_strip <"$_sub_tun_tpl" >"$_sub_tun_clean" || { error "模板去注释失败"; return 1; }
  if ! jq -e '.outbounds' "$_sub_tun_clean" >/dev/null 2>&1; then
    error "sing-box 模板结构异常（缺少 outbounds）"
    return 1
  fi

  local _sub_tun_prog='.' _sub_tun_args=""
  # 逐个已启用协议：把模板中对应 tag 的 outbound 整体替换
  for _sub_tun_p in $(proto_enabled_list); do
    _sub_tun_node="${ESB_TMP}/node-${_sub_tun_p}.json"
    render_outbound "$_sub_tun_p" >"$_sub_tun_node" || { error "渲染节点失败：$_sub_tun_p"; return 1; }
    if ! jq -e --arg t "$_sub_tun_p" '[.outbounds[]|select(.tag==$t)]|length>0' "$_sub_tun_clean" >/dev/null 2>&1; then
      log_warn "模板里没有名为 $_sub_tun_p 的节点，跳过替换"
      continue
    fi
    if ! jq --slurpfile n "$_sub_tun_node" --arg t "$_sub_tun_p" \
          '(.outbounds[] | select(.tag==$t)) = $n[0]' "$_sub_tun_clean" >"${_sub_tun_clean}.new"; then
      error "合并节点失败：$_sub_tun_p"
      return 1
    fi
    mv -f "${_sub_tun_clean}.new" "$_sub_tun_clean" || return 1
  done

  # 模板里存在、但本次没启用的节点：从策略组引用与 outbounds 中摘掉，避免引用不存在的 outbound
  local _sub_tun_all="vless-vision-reality vmess-ws-tls anytls hysteria2 tuic"
  local _sub_tun_enabled=" $(proto_enabled_list) "
  local _sub_tun_off=""
  local _sub_tun_k
  for _sub_tun_k in $_sub_tun_all; do
    case "$_sub_tun_enabled" in
      *" $_sub_tun_k "*) ;;
      *) _sub_tun_off="$_sub_tun_off $_sub_tun_k" ;;
    esac
  done
  if [ -n "$(trim "$_sub_tun_off")" ]; then
    jq --arg off "$(trim "$_sub_tun_off")" '
      ($off | split(" ")) as $offlist
      | .outbounds = [ .outbounds[]
          | select((.tag as $t | $offlist | index($t)) == null)
          | if .outbounds then .outbounds = [ .outbounds[] | select(. as $x | $offlist | index($x) | not) ] else . end ]
    ' "$_sub_tun_clean" >"${_sub_tun_clean}.new" && mv -f "${_sub_tun_clean}.new" "$_sub_tun_clean"
    log_info "模板中未启用的节点已摘除：$(trim "$_sub_tun_off")" >&2
  fi

  jq '.' "$_sub_tun_clean"
  return 0
}

# YAML 布尔写法（mihomo 只认 true/false）
_sub_yaml_bool() {
  case "${1-}" in
    true|True|TRUE|1) printf 'true' ;;
    *) printf 'false' ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# 写入订阅文件
# ---------------------------------------------------------------------------
sub_write_files() {
  local _sub_write_dir
  _sub_write_dir="$(sub_dir)"
  mkdir -p "$_sub_write_dir" || { error "无法创建订阅目录 $_sub_write_dir"; return 1; }
  # nginx 以自己的用户读取订阅文件，因此这里放宽到 644/755（订阅目录里只有节点信息，
  # 泄露等同于节点泄露 —— URL 里的 token 就是访问凭据，务必不要在公开渠道分享订阅 URL）
  chmod 755 "$(dirname "$_sub_write_dir")" 2>/dev/null || true
  chmod 755 "$_sub_write_dir" 2>/dev/null || true

  local _sub_write_tmp="${ESB_TMP}/sub.$$"
  mkdir -p "$_sub_write_tmp" || return 1

  sub_links_text >"${_sub_write_tmp}/links.txt" || return 1
  sub_links_base64 >"${_sub_write_tmp}/sub" || return 1
  # singbox.json：按仓库 Templates/tun-fakeip.json 模板生成（TUN + FakeIP + 规则分流）
  if sub_singbox_tun_json >"${_sub_write_tmp}/singbox.json"; then
    :
  else
    log_warn "sing-box TUN 模板配置生成失败，退回精简配置"
    sub_singbox_json >"${_sub_write_tmp}/singbox.json" || return 1
  fi
  # singbox-mixed.json：精简配置（mixed 入站，仅代理本机程序）
  sub_singbox_json >"${_sub_write_tmp}/singbox-mixed.json" || return 1
  if sub_mihomo_yaml >"${_sub_write_tmp}/mihomo.yaml"; then
    :
  else
    log_warn "Mihomo 配置生成失败（已跳过该格式）"
    rm -f "${_sub_write_tmp}/mihomo.yaml"
  fi
  {
    printf 'EasySB 订阅信息\n'
    printf '生成时间：%s\n' "$(esb_now)"
    printf '域名：%s\n' "$(state_get .domain)"
    printf '协议：%s\n' "$(proto_enabled_list)"
    printf '说明：本目录内容包含全部节点凭据，请勿公开分享。\n'
  } >"${_sub_write_tmp}/info.txt"

  local _sub_write_f
  for _sub_write_f in "$_sub_write_tmp"/*; do
    [ -f "$_sub_write_f" ] || continue
    chmod 644 "$_sub_write_f" 2>/dev/null || true
    mv -f "$_sub_write_f" "${_sub_write_dir}/" || { error "写入订阅文件失败：$_sub_write_f"; return 1; }
  done
  rm -rf "$_sub_write_tmp"

  # 本地也留一份纯文本链接，方便直接复制
  sub_links_text >"${ESB_CLIENT_DIR}/links.txt" 2>/dev/null || true
  chmod 600 "${ESB_CLIENT_DIR}/links.txt" 2>/dev/null || true
  log_ok "订阅文件已生成：$_sub_write_dir" >&2
  return 0
}

sub_url_list() {
  local _sub_url_base
  _sub_url_base="$(sub_url_base)"
  printf 'base64\t%s/sub\n' "$_sub_url_base"
  printf 'links\t%s/links.txt\n' "$_sub_url_base"
  printf 'singbox\t%s/singbox.json\n' "$_sub_url_base"
  printf 'singbox-mixed\t%s/singbox-mixed.json\n' "$_sub_url_base"
  printf 'mihomo\t%s/mihomo.yaml\n' "$_sub_url_base"
  return 0
}

sub_url() {
  # 主订阅地址（通用 Base64，客户端里填这个）
  printf '%s/sub\n' "$(sub_url_base)"
  return 0
}

# ---------------------------------------------------------------------------
# 订阅站点
# ---------------------------------------------------------------------------
sub_nginx_conf() {
  printf '%s/easysb-sub.conf\n' "$(dirname "$ESB_NGINX_CONF")"
  return 0
}

sub_nginx_conf_dir() {
  local _sub_nginx_conf_dir_d
  for _sub_nginx_conf_dir_d in \
      "${ESB_ROOT}/etc/nginx/conf.d" \
      "${ESB_ROOT}/etc/nginx/http.d" \
      "${ESB_ROOT}/etc/nginx/sites-enabled"; do
    if [ -d "$_sub_nginx_conf_dir_d" ]; then printf '%s\n' "$_sub_nginx_conf_dir_d"; return 0; fi
  done
  printf '%s\n' "${ESB_ROOT}/etc/nginx/conf.d"
  return 0
}

sub_site_deploy() {
  local _sub_site_deploy_root _sub_site_deploy_port _sub_site_deploy_conf
  _sub_site_deploy_root="$(esb_rooted "$(state_get .sub.root)")"
  [ -n "$_sub_site_deploy_root" ] || _sub_site_deploy_root="${ESB_ROOT}/var/www/easysb-sub"
  _sub_site_deploy_port="$(state_get .sub.port)"; [ -n "$_sub_site_deploy_port" ] || _sub_site_deploy_port=8080
  _sub_site_deploy_conf="$(sub_nginx_conf_dir)/easysb-sub.conf"

  if ! web_installed; then
    log_warn "未安装 nginx，无法部署订阅站点"
    return 1
  fi
  mkdir -p "$_sub_site_deploy_root" 2>/dev/null || return 1
  mkdir -p "$(dirname "$_sub_site_deploy_conf")" 2>/dev/null || return 1

  cat <<EOF | file_write "$_sub_site_deploy_conf" 644
# EasySB 订阅站点（由 EasySB 自动生成，请勿手动修改；需要删除请用脚本菜单）
server {
    listen ${_sub_site_deploy_port};
    listen [::]:${_sub_site_deploy_port};
    server_name _;
    root ${_sub_site_deploy_root};
    autoindex off;
    access_log off;

    location /sub/ {
        add_header Cache-Control "no-store";
        try_files \$uri \$uri/ =404;
    }

    location / {
        return 404;
    }
}
EOF
  if ! run_gate "nginx -t" nginx -t >/dev/null 2>&1; then
    log_warn "nginx 配置校验未通过，已移除订阅站点配置"
    rm -f "$_sub_site_deploy_conf" 2>/dev/null || true
    return 1
  fi
  service_mgr nginx reload >/dev/null 2>&1 || service_mgr nginx restart >/dev/null 2>&1 || true
  log_ok "订阅站点已部署：http://$(state_get .domain):${_sub_site_deploy_port}/sub/<token>/" >&2
  return 0
}

sub_site_remove() {
  local _sub_site_remove_conf
  _sub_site_remove_conf="$(sub_nginx_conf_dir)/easysb-sub.conf"
  [ -f "$_sub_site_remove_conf" ] || return 0
  rm -f "$_sub_site_remove_conf" 2>/dev/null || true
  if run_gate "nginx -t" nginx -t >/dev/null 2>&1; then
    service_mgr nginx reload >/dev/null 2>&1 || true
  fi
  log_info "已移除独立订阅站点配置" >&2
  return 0
}

sub_enable() {
  if [ -z "$(proto_enabled_list)" ]; then
    error "尚未启用任何协议，无法生成订阅"
    return 1
  fi
  local _sub_enable_port
  render_clients >/dev/null 2>&1 || true
  sub_write_files || return 1
  if ! sub_use_site; then
    _sub_enable_port="$(state_get .sub.port)"; [ -n "$_sub_enable_port" ] || _sub_enable_port=8080
    sub_site_deploy || log_warn "订阅站点部署失败，订阅文件已生成在 $(sub_dir)"
    fw_open "$_sub_enable_port" tcp >/dev/null 2>&1 || true
  fi
  state_set ".sub.enabled" "true" >/dev/null 2>&1 || true
  log_ok "订阅已启用" >&2
  return 0
}

sub_disable() {
  state_set ".sub.enabled" "false" >/dev/null 2>&1 || true
  sub_site_remove
  fw_close "$(state_get .sub.port)" tcp >/dev/null 2>&1 || true
  log_info "订阅已关闭（订阅文件仍保留在 $(sub_dir)）" >&2
  return 0
}

sub_status() {
  local _sub_status_enabled _sub_status_dir
  _sub_status_enabled="$(state_get .sub.enabled)"
  _sub_status_dir="$(sub_dir)"
  printf '  订阅状态　：%s\n' "$([ "$_sub_status_enabled" = "true" ] && echo '已启用' || echo '未启用')"
  printf '  订阅目录　：%s\n' "$_sub_status_dir"
  if [ "$_sub_status_enabled" = "true" ]; then
    printf '  订阅地址　：%s\n' "$(sub_url)"
    sub_url_list | while IFS="$(printf '\t')" read -r _sub_status_k _sub_status_v; do
      printf '    %-9s %s\n' "$_sub_status_k" "$_sub_status_v"
    done
  fi
  return 0
}

sub_refresh() {
  # 配置变更后刷新订阅内容（静默、失败不影响主流程）
  if [ "$(state_get .sub.enabled)" = "true" ]; then
    render_clients >/dev/null 2>&1 || true
    sub_write_files >/dev/null 2>&1 || log_warn "订阅文件刷新失败，可在菜单中手动重新生成"
  fi
  return 0
}
