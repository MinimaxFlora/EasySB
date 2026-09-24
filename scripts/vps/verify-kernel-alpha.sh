#!/bin/bash
# 单独验证「测试版 · 作者源」这条组合（alpha 通道）
set -u
tmux kill-server 2>/dev/null
sleep 1
tmux new-session -d -s sb -x 100 -y 33 /root/easysb-new
sleep 3
keys() { for k in "$@"; do tmux send-keys -t sb "$k"; sleep 0.6; done; }
snap() { tmux capture-pane -p -t sb | sed -n "$1"; }

echo "== 内核管理 =="
keys 1 Enter
sleep 2
snap '10,14p'

echo "== 切换内核 =="
keys 1 Enter
sleep 2
snap '6,13p'

echo "== [2] 测试版 · 作者源 =="
keys 2 Enter
sleep 45
snap '3,9p'
echo "  来源=$(grep CORE_SOURCE /etc/sing-box/easysb.conf) 通道=$(grep CORE_CHANNEL /etc/sing-box/easysb.conf)"
echo "  v2ray_api块=$(grep -c v2ray_api /etc/sing-box/config.json) API端口=$(ss -ltn | grep -c 10085) sing-box=$(systemctl is-active sing-box)"
echo "  内核自报版本: $(/etc/sing-box/sing-box version | sed -n '1p')"
keys Enter
sleep 1

echo
echo "== 恢复：切回 [1] 正式版 · 作者源 =="
keys 1 Enter
sleep 2
keys 1 Enter
sleep 45
snap '3,9p'
echo "  来源=$(grep CORE_SOURCE /etc/sing-box/easysb.conf) 通道=$(grep CORE_CHANNEL /etc/sing-box/easysb.conf)"
echo "  v2ray_api块=$(grep -c v2ray_api /etc/sing-box/config.json) API端口=$(ss -ltn | grep -c 10085)"
echo "  内核自报版本: $(/etc/sing-box/sing-box version | sed -n '1p')"
echo "  订阅: $(curl -sk -m 20 -o /dev/null -w '%{http_code}' https://text.kejizero.xyz:8443/sub/7emr5rpg2chbr2vq)"
