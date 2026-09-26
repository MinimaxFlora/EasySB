#!/bin/bash
# 真机验证 5.0 的证书链路：面板内置 lego 走 HTTP-01 申请 Let's Encrypt 证书。
# 前置：域名已解析到本机、80 端口空闲（text.kejizero.xyz -> 154.201.92.132）。
set -u
BIN=/usr/local/bin/easysb
DOMAIN="${1:-text.kejizero.xyz}"
EMAIL="${2:-admin@kejizero.xyz}"

tmux kill-server 2>/dev/null
sleep 1
tmux new-session -d -s acme -x 110 -y 42 "$BIN"
sleep 3

keys() { for k in "$@"; do tmux send-keys -t acme "$k"; sleep 0.6; done; }
snap() { tmux capture-pane -p -t acme | sed -n "${1:-1,40p}"; }

echo "== 打开「域名管理」（主菜单第 3 项）=="
keys 3 Enter
sleep 1
snap '1,18p'

echo
echo "== [1] 申请证书（ACME 邮箱还没记过，应先问邮箱）=="
keys 1 Enter
sleep 1.5
snap '1,12p'

echo
echo "== 填邮箱 =="
tmux send-keys -t acme "$EMAIL"
sleep 0.6
tmux send-keys -t acme Enter
sleep 2
snap '1,12p'

echo
echo "== 填域名并等待签发（停内核 -> 监听 80 -> HTTP-01 -> 起内核）=="
tmux send-keys -t acme "$DOMAIN"
sleep 0.6
tmux send-keys -t acme Enter
sleep 75
snap '1,34p'
keys Enter
sleep 1

echo
echo "== 结果 =="
echo "入口:"
ls -l /etc/sing-box/acme/ 2>/dev/null
echo "证书:"
ls -l "/etc/sing-box/acme/$DOMAIN/" 2>/dev/null
openssl x509 -in "/etc/sing-box/acme/$DOMAIN/fullchain.cer" -noout -subject -issuer -dates 2>/dev/null
echo "服务: sing-box=$(systemctl is-active sing-box 2>&1) easysb=$(systemctl is-active easysb 2>&1) acme.timer=$(systemctl is-active easysb-acme.timer 2>&1)"
echo "配置里的证书路径: $(grep -o 'certificate_path": "[^"]*' /etc/sing-box/config.json | head -1)"
echo "tls 监听: $(ss -ltn | grep -c ':8443 ')"

echo
echo "== 返回并退出 =="
keys 0 Enter
keys Q
sleep 1
tmux kill-server 2>/dev/null
echo "  完成"
