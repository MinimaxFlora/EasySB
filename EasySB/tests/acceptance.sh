#!/usr/bin/env bash
# =============================================================================
# EasySB — tests/acceptance.sh
# 真机验收脚本：在**已部署好的 Linux VPS 上**运行，检查沙箱证明不了的部分
#   （systemd 服务、真实端口监听、nginx 伪装站点、订阅地址可访问、防火墙规则、
#     内核版本与仓库最新版本、配置能被已安装内核校验）
#
# 用法（在 VPS 上，root）：
#   bash <(curl -fsSL <raw>/EasySB/tests/acceptance.sh)
#   或把本文件 scp 上去后： bash acceptance.sh
#
# 退出码：0=全部通过；1=有失败；77=环境不适用（没部署 / 不是 root）
# 只读检查为主，唯一会做的是 nginx -t 与 curl 本机地址；不会改动任何配置。
# =============================================================================
set -u

ESB_TEST_ROOT="${ESB_TEST_ROOT:-}"
E() { printf '%s\n' "$*"; }
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  \033[33mSKIP\033[0m %s\n' "$*"; }
hdr()  { printf '\n== %s ==\n' "$*"; }

p() { printf '%s' "${ESB_TEST_ROOT}$1"; }

if [ "$(id -u)" != "0" ] && [ "${ESB_TEST_ALLOW_NONROOT:-0}" != "1" ]; then E "请以 root 运行"; exit 77; fi
[ -f "$(p /etc/easysb/state.json)" ] || { E "未找到 /etc/easysb/state.json：这台机器还没用 EasySB 部署过"; exit 77; }
command -v jq >/dev/null 2>&1 || { E "缺少 jq，请先安装（apt-get install -y jq）"; exit 77; }

STATE="$(p /etc/easysb/state.json)"
CFG="$(p /etc/sing-box/config.json)"
BIN="$(p /usr/bin/sing-box)"
DOMAIN="$(jq -r '.domain // empty' "$STATE")"
jqv() { jq -r "$1" "$STATE" 2>/dev/null | tr -d '\r'; }

E "EasySB 真机验收开始（域名：${DOMAIN:-未设置}）"

# ---------------------------------------------------------------------------
hdr "1. 内核"
if [ -x "$BIN" ]; then
  pass "内核存在：$BIN"
  INSTALLED="$("$BIN" version 2>/dev/null | head -1 | tr -d '\r')"
  pass "内核自报版本：${INSTALLED:-未知}"
  if command -v curl >/dev/null 2>&1; then
    LATEST="$(curl -fsSL --connect-timeout 10 https://api.github.com/repos/MinimaxFlora/EasySB/releases/latest 2>/dev/null \
      | jq -r '.tag_name // empty' | tr -d '\r' | sed 's/^v//')"
    if [ -n "$LATEST" ]; then
      case "$INSTALLED" in
        *"$LATEST"*) pass "已是仓库最新版本 v$LATEST" ;;
        *) fail "本机 ${INSTALLED:-未知}，仓库最新 v$LATEST（可在菜单【更新】里升级）" ;;
      esac
    else
      skip "无法获取仓库最新版本（网络不可达）"
    fi
  fi
else
  fail "内核不存在或不可执行：$BIN"
fi

hdr "2. 配置与校验"
if [ -f "$CFG" ]; then
  pass "存在服务端配置：$CFG"
  if [ -x "$BIN" ]; then
    if "$BIN" check -c "$CFG" >/dev/null 2>&1; then
      pass "已安装内核校验配置通过（sing-box check）"
    else
      fail "配置校验失败，请执行： $BIN check -c $CFG"
      "$BIN" check -c "$CFG" 2>&1 | sed 's/^/       /' | head -5
    fi
  fi
  # 协议端口与 state 是否一致
  PROTO_N=$(jq -r '.inbounds | length' "$CFG" 2>/dev/null | tr -d '\r')
  pass "配置里包含 $PROTO_N 个入站（state 中启用 $(jqv '[.protocols[]|select(.enabled)]|length') 个）"
else
  fail "不存在服务端配置：$CFG"
fi

hdr "3. 服务（systemd）"
if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet sing-box; then pass "sing-box 服务运行中"; else fail "sing-box 服务未运行（journalctl -u sing-box -n 50）"; fi
  if systemctl is-enabled --quiet sing-box 2>/dev/null; then pass "开机自启已启用"; else fail "开机自启未启用（systemctl enable sing-box）"; fi
  UNIT_USER="$(systemctl show -p User --value sing-box 2>/dev/null | tr -d '\r')"
  pass "服务运行用户：${UNIT_USER:-root}"
  if [ -x "$BIN" ] && [ -f "$CFG" ] && [ -n "$UNIT_USER" ] && [ "$UNIT_USER" != "root" ]; then
    if su -s /bin/sh -c "cat '$CFG' >/dev/null 2>&1" "$UNIT_USER" 2>/dev/null; then
      pass "服务用户可以读取配置（属主/权限正确）"
    else
      fail "服务用户 $UNIT_USER 读不到配置 → 服务会启动失败（应为 root:sing-box 640）"
    fi
  fi
else
  skip "本机没有 systemd"
fi

hdr "4. 端口监听"
while IFS=$'\t' read -r PROTO PORT; do
  [ -n "$PROTO" ] || continue
  case "$PROTO" in
    hysteria2|tuic) FLAG="-u" ;;
    *) FLAG="-t" ;;
  esac
  if command -v ss >/dev/null 2>&1; then
    if ss -H -ln $FLAG 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
      pass "$PROTO 正在监听 ${PORT}$( [ "$FLAG" = "-u" ] && echo '/udp' || echo '/tcp')"
    else
      fail "$PROTO 没有监听端口 ${PORT}"
    fi
  else
    skip "缺少 ss，无法检查端口（$PROTO $PORT）"
  fi
done <<EOF
$(jq -r '.protocols | to_entries[] | select(.value.enabled) | "\(.key)\t\(.value.port)"' "$STATE" 2>/dev/null | tr -d '\r')
EOF

hdr "5. 防火墙规则（本工具添加的那些）"
FW_BACKEND="$(jqv '.firewall.backend')"
E "  记录的后端：${FW_BACKEND:-未知}"
RULE_N=0
while IFS= read -r RULE; do
  [ -n "$RULE" ] || continue
  RULE_N=$((RULE_N + 1))
  PORT="${RULE%%/*}"; PROTO="${RULE##*/}"
  case "$FW_BACKEND" in
    nftables)
      if command -v nft >/dev/null 2>&1 && nft list table inet easysb 2>/dev/null | grep -q "dport ${PORT%\/*}"; then
        pass "nftables 表 inet easysb 中存在 ${RULE} 规则"
      else
        fail "nftables 中找不到 ${RULE} 规则"
      fi
      ;;
    ufw)
      if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "${PORT%\/*}.*${PROTO}.*EasySB"; then
        pass "ufw 中存在带 EasySB 标签的 ${RULE} 规则"
      else
        fail "ufw 中找不到带 EasySB 标签的 ${RULE} 规则"
      fi
      ;;
    firewalld|iptables|none|'')
      skip "跳过 ${RULE} 自动检查（后端 $FW_BACKEND，请人工确认）"
      ;;
  esac
done <<EOF
$(jqv '.firewall.rules[]?' | tr -d '\r')
EOF
[ "$RULE_N" -gt 0 ] || skip "state 中没有记录任何防火墙规则"
if jq -e '.firewall.hop.enabled == true' "$STATE" >/dev/null 2>&1; then
  HOP_RANGE="$(jqv '.firewall.hop.range')"
  if command -v nft >/dev/null 2>&1 && nft list table inet easysb 2>/dev/null | grep -q "redirect to :"; then
    pass "端口跳跃 DNAT 规则存在（$HOP_RANGE）"
  elif command -v iptables >/dev/null 2>&1 && iptables -t nat -S EASYSB_HOP 2>/dev/null | grep -q REDIRECT; then
    pass "端口跳跃 DNAT 规则存在（iptables 链 EASYSB_HOP，$HOP_RANGE）"
  else
    fail "state 说端口跳跃已启用，但找不到 DNAT 重定向规则"
  fi
fi

hdr "6. 伪装站点"
if [ "$(jqv '.web.enabled')" = "true" ]; then
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then pass "nginx 配置校验通过（nginx -t）"; else fail "nginx 配置校验失败（nginx -t）"; fi
  fi
  WEB_PORT="$(jqv '.web.http_port')"; [ -n "$WEB_PORT" ] || WEB_PORT=80
  if command -v curl >/dev/null 2>&1; then
    CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${WEB_PORT}/" 2>/dev/null)"
    [ -n "$CODE" ] || CODE="000"
    if [ "$CODE" = "200" ]; then pass "伪装站点首页返回 200（127.0.0.1:${WEB_PORT}）"; else fail "伪装站点首页返回 $CODE（期望 200）"; fi
    if [ -n "$DOMAIN" ]; then
      CODE2="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${DOMAIN}/" 2>/dev/null)"
      [ -n "$CODE2" ] || CODE2="000"
      [ "$CODE2" = "200" ] && pass "通过域名访问伪装站点返回 200（http://$DOMAIN/）" || fail "通过域名访问返回 $CODE2（检查 DNS/端口/防火墙）"
    fi
  fi
  if [ "$(jqv '.web.tls')" = "true" ] && [ -n "$DOMAIN" ]; then
    CODE3="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${DOMAIN}/" 2>/dev/null)"
    [ -n "$CODE3" ] || CODE3="000"
    [ "$CODE3" = "200" ] && pass "HTTPS 访问伪装站点返回 200" || fail "HTTPS 访问返回 $CODE3"
  fi
else
  skip "未启用伪装站点"
fi

hdr "7. 订阅地址"
if [ "$(jqv '.sub.enabled')" = "true" ]; then
  TOKEN="$(jqv '.sub.token')"
  if [ -n "$DOMAIN" ] && [ -n "$TOKEN" ]; then
    if [ "$(jqv '.web.enabled')" = "true" ] && [ "$(jqv '.web.tls')" = "true" ]; then
      SUB_URL="https://${DOMAIN}/sub/${TOKEN}/sub"
      CURL_OPT="-sk"
    elif [ "$(jqv '.web.enabled')" = "true" ]; then
      SUB_URL="http://${DOMAIN}/sub/${TOKEN}/sub"
      CURL_OPT="-s"
    else
      SUB_URL="http://${DOMAIN}:$(jqv '.sub.port')/sub/${TOKEN}/sub"
      CURL_OPT="-s"
    fi
    BODY="$(curl $CURL_OPT --max-time 10 "$SUB_URL" 2>/dev/null | head -c 2000)"
    if [ -n "$BODY" ]; then
      if printf '%s' "$BODY" | base64 -d >/dev/null 2>&1; then
        LINES="$(printf '%s' "$BODY" | base64 -d | grep -c .)"
        pass "订阅地址可访问且内容可解码（$LINES 条节点链接）：$SUB_URL"
      else
        fail "订阅地址返回了内容但不是合法 Base64：$SUB_URL"
      fi
    else
      fail "订阅地址无法访问：$SUB_URL"
    fi
    for F in links.txt singbox.json mihomo.yaml; do
      C="$(curl $CURL_OPT -o /dev/null -w '%{http_code}' --max-time 10 "${SUB_URL%/sub}/${F}" 2>/dev/null)"
      [ -n "$C" ] || C="000"
      [ "$C" = "200" ] && pass "订阅文件可访问：$F" || fail "订阅文件 $F 返回 $C"
    done
  else
    skip "state 中缺少域名或订阅 token"
  fi
else
  skip "未启用订阅"
fi

hdr "8. 证书"
CERT_DOMAIN="$(jqv '.cert.domain')"
if [ -n "$CERT_DOMAIN" ]; then
  CRT="$(jqv '.cert.crt')"
  if [ -f "$CRT" ]; then
    pass "已应用证书文件存在：$CRT"
    END="$(openssl x509 -in "$CRT" -noout -enddate 2>/dev/null | cut -d= -f2)"
    SUBJ="$(openssl x509 -in "$CRT" -noout -subject 2>/dev/null | tr -d '\r')"
    pass "证书：${SUBJ:-未知}，到期 ${END:-未知}"
    if openssl x509 -in "$CRT" -noout -checkend 604800 >/dev/null 2>&1; then
      pass "证书 7 天内不会过期"
    else
      fail "证书即将过期（7 天内），请续期"
    fi
    if [ -n "$DOMAIN" ]; then
      if printf '%s' "$SUBJ" | grep -q "$DOMAIN"; then pass "证书主体与部署域名一致（$DOMAIN）"; else fail "证书主体与部署域名不一致（期望 $DOMAIN）"; fi
    fi
  else
    fail "state 指向的证书文件不存在：$CRT"
  fi
else
  skip "state 中没有已应用证书"
fi

hdr "9. 客户端产物"
for F in /etc/easysb/client/links.txt /etc/easysb/client/all.json; do
  if [ -f "$(p $F)" ]; then pass "存在 $F"; else fail "缺少 $F（可在菜单【客户端配置与分享链接】里重新生成）"; fi
done
LINKS_FILE="$(p /etc/easysb/client/links.txt)"
if [ -f "$LINKS_FILE" ]; then
  N="$(grep -c . "$LINKS_FILE")"
  ENABLED="$(jqv '[.protocols[]|select(.enabled)]|length')"
  if [ "$N" = "$ENABLED" ]; then pass "链接条数（$N）与启用协议数一致"; else fail "链接条数 $N 与启用协议数 $ENABLED 不一致"; fi
fi

printf '\n================ 验收结果 ================\n'
printf '通过 %s   失败 %s   跳过 %s\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" = "0" ]; then
  printf '\n全部通过：这台机器上的部署已按预期工作。\n'
  exit 0
fi
printf '\n存在失败项，请把上面的完整输出发回。\n'
exit 1
