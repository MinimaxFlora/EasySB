#!/bin/bash
# 真机验证 EasySB 5.0：内核编进面板、账号流量统计、服务解锁状态、lego 证书路径。
# 面板是 TUI，所以在 tmux 里驱动，用 capture-pane 留下每一步的画面作为证据。
#
# 前置：把 5.0 的 linux/amd64 二进制放在 /root/easysb-new（install.sh --binary 用它）。
set -u
BIN=/usr/local/bin/easysb
NEW=/root/easysb-new

tmux kill-server 2>/dev/null
sleep 1
tmux new-session -d -s sb -x 110 -y 42 "$BIN"
sleep 3

keys() { for k in "$@"; do tmux send-keys -t sb "$k"; sleep 0.5; done; }
snap() { tmux capture-pane -p -t sb | sed -n "${1:-1,40p}"; }
line() { echo; echo "== $* =="; }
state() {
  echo "  面板版本: $($BIN --version)"
  echo "  内核: $($BIN core version | tr '\n' ' ')"
  echo "  单元: $(grep -h ExecStart /etc/systemd/system/sing-box.service /etc/systemd/system/easysb.service 2>/dev/null | tr '\n' ' ')"
  echo "  状态: sing-box=$(systemctl is-active sing-box 2>&1) easysb=$(systemctl is-active easysb 2>&1)"
  echo "  v2ray_api 块: $(grep -c v2ray_api /etc/sing-box/config.json 2>/dev/null) / 计数端口: $(ss -ltn 2>/dev/null | grep -c 10085)"
  echo "  状态文件里的内核键: $(grep -c 'CORE_CHANNEL\|CORE_SOURCE\|STATS_API' /etc/sing-box/easysb.conf 2>/dev/null)"
  echo "  协议端口: $(ss -ltnp 2>/dev/null | grep -c easysb)"
}

line "1. 版本与能力位（内核已编译进面板）"
$BIN core version

line "2. 用 5.0 的引擎校验 4.x 留下的配置"
$BIN core check -c /etc/sing-box/config.json

line "3. 服务解锁状态（无终端 CLI 形态）"
timeout 300 "$BIN" --unlock || echo "  (--unlock 退出码 $?)"

line "4. TUI 首页看板（应显示 5.0.0 与内核版本·带流量统计）"
snap '1,12p'

line "5. 打开「服务解锁状态」（主菜单第 1 项）"
keys 1 Enter
sleep 1
snap '1,22p'

line "6. 检测全部服务并在任务页留下结论"
keys 1 Enter
sleep 120
snap '1,34p'
keys Enter
sleep 1

line "7. 回到主菜单，重新部署节点（会用面板自己当内核单元）"
keys 0 Enter
sleep 1
keys 2 Enter
sleep 1
keys 1 Enter
sleep 75
snap '1,30p'
keys Enter
sleep 1
state

line "8. 订阅服务状态与本地订阅拉取"
keys 0 Enter
sleep 1
keys 4 Enter
sleep 1
keys 3 Enter
sleep 5
snap '1,20p'
keys Enter
sleep 1
TOKEN=$(sed -n 's/.*"token": *"\([a-z0-9]*\)".*/\1/p' /etc/sing-box/easysb-users.json | head -1)
echo "  账号令牌: ${TOKEN:0:4}****"
echo "  订阅自测: $(curl -sk -m 20 -o /dev/null -w 'HTTP %{http_code}  %{size_download} bytes' https://text.kejizero.xyz:8443/sub/$TOKEN 2>/dev/null)"
echo "  订阅头: $(curl -sk -m 20 -D - -o /dev/null https://text.kejizero.xyz:8443/sub/$TOKEN 2>/dev/null | grep -i 'Subscription-Userinfo\|Content-Disposition' | tr '\n' ' ')"

line "9. 证书（lego 目录与续期定时器）"
ls -l /etc/sing-box/acme/ 2>/dev/null | head -5
systemctl is-active easysb-acme.timer 2>&1
$BIN --version >/dev/null && echo "  面板可执行"

line "10. 收尾：退出 TUI"
keys Q
sleep 1
tmux kill-server 2>/dev/null
echo "  完成"
