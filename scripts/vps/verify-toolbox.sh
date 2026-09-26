#!/usr/bin/env bash
# 在真机上把工具箱的每一项都跑一遍：每项都要能起来、能给出表格、能正常退出。
#
# 用法（在 VPS 上，root）：
#   bash verify-toolbox.sh /root/easysb-new              # 全部条目
#   bash verify-toolbox.sh /root/easysb-new backtrace ipquality   # 只跑指定条目
#
# 退出码 0 表示每一项都跑通；任何一项失败都会列出它的输出尾巴。
set -uo pipefail

BIN="${1:-/root/easysb-new}"
shift || true

# 每项的预算：测速与跑分最慢，给它们更多时间。
budget() {
  case "$1" in
    speed-near|speed-cn) echo 600 ;;
    bench-cpu|bench-mem|bench-disk|bench-disks) echo 900 ;;
    backtrace|ipquality|portcheck|unlock-*) echo 300 ;;
    *) echo 180 ;;
  esac
}

note() { printf '\n\033[1m===== %s\033[0m\n' "$*"; }

if [ ! -x "$BIN" ]; then
  echo "找不到可执行文件：$BIN" >&2
  exit 2
fi

if [ "$#" -gt 0 ]; then
  entries="$*"
else
  entries="$("$BIN" --tool list | awk '/^  /{print $1}')"
fi

failed=0
for id in $entries; do
  limit="$(budget "$id")"
  note "$id（上限 ${limit}s）"
  out="$(timeout "$limit" "$BIN" --tool "$id" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "失败：退出码 $status"
    echo "$out" | tail -20
    failed=$((failed + 1))
    continue
  fi
  rows="$(printf '%s\n' "$out" | sed '/^$/d' | wc -l)"
  echo "退出码 0，输出 ${rows} 行"
  printf '%s\n' "$out" | head -8
  if [ "$rows" -gt 10 ]; then
    printf '  …（另有 %d 行，完整输出见下）\n' "$((rows - 10))"
  fi
  printf '%s\n' "$out" > "/root/toolbox-$id.txt"
  echo "完整输出：/root/toolbox-$id.txt"
done

note "结论"
if [ "$failed" -eq 0 ]; then
  echo "全部条目跑通"
else
  echo "$failed 项失败"
fi
exit "$failed"
