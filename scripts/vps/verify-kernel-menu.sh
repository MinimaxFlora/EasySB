#!/bin/bash
# 真机走一遍新的内核管理：切换内核（四个组合）+ 更新内核 + 看板来源标记
set -u
BIN=/root/easysb-new
tmux kill-server 2>/dev/null
sleep 1
tmux new-session -d -s sb -x 100 -y 33 "$BIN"
sleep 3

keys() { for k in "$@"; do tmux send-keys -t sb "$k"; sleep 0.4; done; }
snap() { tmux capture-pane -p -t sb | sed -n "$1"; }
state() {
  echo "  来源=$(grep CORE_SOURCE /etc/sing-box/easysb.conf) 通道=$(grep CORE_CHANNEL /etc/sing-box/easysb.conf)"
  echo "  v2ray_api块=$(grep -c v2ray_api /etc/sing-box/config.json) API端口=$(ss -ltn | grep -c 10085) sing-box=$(systemctl is-active sing-box)"
}

echo "== 打开 内核管理 =="
keys 1 Enter
sleep 1.5
snap '5,13p'

echo
echo "== 进入 切换内核，看当前组合是否被标记 =="
keys 1 Enter
sleep 1.5
snap '5,15p'

echo
echo "== [1] 正式版 · 作者源（已装，应判无操作）=="
keys 1 Enter
sleep 6
snap '3,6p'
keys Enter
sleep 1

echo
echo "== [5] 返回上一级 再到 [2] 更新内核 =="
keys 5 Enter
sleep 1
keys 2 Enter
sleep 25
snap '3,8p'
state
keys Enter
sleep 1

echo
echo "== 切到 [2] 测试版 · 作者源（真装 alpha）=="
keys 1 Enter
sleep 1.5
keys 2 Enter
sleep 40
snap '3,8p'
state
keys Enter
sleep 1

echo
echo "== 切到 [3] 正式版 · 官方源（真装官方，节点应仍起来）=="
keys 1 Enter
sleep 1.5
keys 3 Enter
sleep 45
snap '3,8p'
state
keys Enter
sleep 1

echo
echo "== 切回 [1] 正式版 · 作者源（恢复用户设置）=="
keys 1 Enter
sleep 1.5
keys 1 Enter
sleep 45
snap '3,8p'
state
echo "  订阅: $(curl -sk -m 20 -o /dev/null -w '%{http_code}' https://text.kejizero.xyz:8443/sub/7emr5rpg2chbr2vq)"
echo "  单元: $(grep ExecStart /etc/systemd/system/easysb.service)"
