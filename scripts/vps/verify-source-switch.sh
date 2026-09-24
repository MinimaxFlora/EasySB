#!/bin/bash
# 真机来回验证：官方源 → 切回作者源
set -u
tmux kill-server 2>/dev/null
sleep 1
tmux new-session -d -s sb -x 100 -y 33 /root/easysb-scratch
sleep 3
/root/sb2.sh 1 Enter >/dev/null
sleep 1

echo "== 步骤1: 内核管理 -> 切换到官方源内核 =="
WATCH=8 /root/sb2.sh 5 Enter >/dev/null
WATCH=35 /root/sb2.sh >/dev/null
grep -h "官方源\|重新生成\|部署完成" /root/f2/f*.txt | sort -u | head -4
echo "结果: 来源=$(grep CORE_SOURCE /etc/sing-box/easysb.conf) v2ray_api块=$(grep -c v2ray_api /etc/sing-box/config.json) sing-box=$(systemctl is-active sing-box)"

echo
echo "== 步骤2: 内核管理 -> [1] 安装正式版内核（切回作者源）=="
rm -f /root/f2/f*.txt
WATCH=1 /root/sb2.sh Enter >/dev/null
sleep 1
WATCH=8 /root/sb2.sh 1 Enter >/dev/null
WATCH=35 /root/sb2.sh >/dev/null
grep -h "作者源\|已是该通道\|重新生成\|部署完成\|GET " /root/f2/f*.txt | sort -u | head -6
echo "结果: 来源=$(grep CORE_SOURCE /etc/sing-box/easysb.conf) 统计=$(grep STATS_API /etc/sing-box/easysb.conf) v2ray_api块=$(grep -c v2ray_api /etc/sing-box/config.json) API端口=$(ss -ltn | grep -c 10085)"
echo "服务: easysb=$(systemctl is-active easysb) sing-box=$(systemctl is-active sing-box) 单元=$(grep ExecStart /etc/systemd/system/easysb.service)"
curl -sk -m 20 -o /dev/null -w "订阅 HTTP %{http_code}\n" https://text.kejizero.xyz:8443/sub/7emr5rpg2chbr2vq
