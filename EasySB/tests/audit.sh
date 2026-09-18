#!/usr/bin/env bash
# =============================================================================
# EasySB 契约审计（tests/audit.sh）—— 见 docs/TESTING.md
#
#   (a) INTERFACES.md §2–§10 承诺的公共函数是否都在 lib/*.sh 里实现
#       （函数定义用 grep -E '^[a-z][a-z0-9_]*\(\)[[:space:]]*\{' 识别）
#   (b) 违规模式扫描（lib/*.sh + easysb.sh）：跳过注释行与 heredoc 里的文本
#       规则 1 下载即执行 / 规则 2 sed -i 按行号改配置 / 规则 3 清空防火墙 /
#       规则 4 resolv.conf / lib 内 set -e / lib 内直接 exit（die 除外）
#
# 退出码：0=干净   1=有发现   2=用法/环境错误
# =============================================================================

_au_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_au_doc="$_au_repo/docs/INTERFACES.md"

if [ ! -f "$_au_doc" ]; then printf '错误：找不到契约文件 %s\n' "$_au_doc" >&2; exit 2; fi

_au_libs=()
for _au_f in "$_au_repo"/lib/*.sh; do
  [ -r "$_au_f" ] && _au_libs+=("$_au_f")
done
if [ "${#_au_libs[@]}" -eq 0 ]; then printf '错误：lib/ 下没有任何 .sh\n' >&2; exit 2; fi

_au_tmp="$_au_repo/tests/.work/audit.$$"
mkdir -p "$_au_tmp" || { printf '错误：无法创建 %s\n' "$_au_tmp" >&2; exit 2; }
trap 'rm -rf "$_au_tmp"' EXIT

_au_findings=0
_au_missing_count=0

printf '== EasySB 契约审计 ==\n'
printf '   仓库: %s\n' "$_au_repo"
printf '   契约: %s\n' "$_au_doc"

# ---------------------------------------------------------------------------
# (a) 契约函数是否齐全
# ---------------------------------------------------------------------------
# 只解析 §2–§10 的围栏代码块：一行写成 "a / b / c" 的按 / 拆开，各自取首个标识符
awk '
  function secnum(s,   m) { return (match(s, /^## [0-9]+\./)) ? substr(s, RSTART+3, RLENGTH-4)+0 : 0 }
  /^## / {
    sec = secnum($0)
    lib = ""
    if (match($0, /`[0-9]+-[a-z]+\.sh`/)) lib = substr($0, RSTART+1, RLENGTH-2)
    inblock = 0
    next
  }
  /^```/ { if (sec >= 2 && sec <= 10) inblock = !inblock; next }
  (sec >= 2 && sec <= 10 && inblock) {
    line = $0
    sub(/#.*/, "", line)
    n = split(line, parts, "/")
    for (i = 1; i <= n; i++) {
      p = parts[i]
      gsub(/^[ \t]+/, "", p); gsub(/[ \t]+$/, "", p)
      if (p == "") continue
      if (match(p, /^[a-z][a-zA-Z0-9_]*/)) print sec "\t" lib "\t" substr(p, RSTART, RLENGTH)
    }
  }
' "$_au_doc" | sort -u >"$_au_tmp/spec.tsv"

_au_promised="$(wc -l <"$_au_tmp/spec.tsv" | tr -d ' ')"
if [ "$_au_promised" -lt 60 ]; then
  printf '错误：只从 INTERFACES.md 解析出 %s 个函数（<60），解析逻辑可能已失效\n' "$_au_promised" >&2
  exit 2
fi

: >"$_au_tmp/defined.txt"
for _au_lib in "${_au_libs[@]}"; do
  grep -oE '^[a-z][a-z0-9_]*\(\)[[:space:]]*\{' "$_au_lib" 2>/dev/null \
    | sed -e 's/[[:space:]]*{$//' -e 's/()$//' >>"$_au_tmp/defined.txt"
done
sort -u "$_au_tmp/defined.txt" >"$_au_tmp/defined_sorted.txt"

: >"$_au_tmp/missing.tsv"
: >"$_au_tmp/libfiles.txt"
while IFS="$(printf '\t')" read -r _au_sec _au_libfile _au_fn; do
  [ -n "$_au_fn" ] || continue
  [ -n "$_au_libfile" ] && printf '%s\n' "$_au_libfile" >>"$_au_tmp/libfiles.txt"
  if ! grep -Fxq "$_au_fn" "$_au_tmp/defined_sorted.txt"; then
    printf '%s\t%s\t%s\n' "$_au_libfile" "$_au_fn" "$_au_sec" >>"$_au_tmp/missing.tsv"
  fi
done <"$_au_tmp/spec.tsv"
sort -u -o "$_au_tmp/missing.tsv" "$_au_tmp/missing.tsv"
sort -u -o "$_au_tmp/libfiles.txt" "$_au_tmp/libfiles.txt"

_au_missing_count="$(wc -l <"$_au_tmp/missing.tsv" | tr -d ' ')"
_au_defined_count="$(wc -l <"$_au_tmp/defined_sorted.txt" | tr -d ' ')"

printf '\n-- (a) 契约函数 --\n'
printf '   承诺函数: %s（INTERFACES §2–§10）   已实现定义: %s   缺失: %s\n' \
  "$_au_promised" "$_au_defined_count" "$_au_missing_count"

if [ "$_au_missing_count" != "0" ]; then
  _au_findings=1
  printf '\n[缺失] 以下公共函数在 lib/*.sh 里找不到定义（按契约应实现它们的文件分组）：\n'
  while IFS="$(printf '\t')" read -r _au_mf _au_mfn _au_ms; do
    printf '   %-8s lib/%s: %s\n' "§${_au_ms}" "$_au_mf" "$_au_mfn"
  done <"$_au_tmp/missing.tsv"
fi
# 整个模块文件缺失也单独报（比逐个函数更容易看出进度）
while IFS= read -r _au_lf; do
  [ -n "$_au_lf" ] || continue
  if [ ! -f "$_au_repo/lib/$_au_lf" ]; then
    printf '\n[缺失] 契约要求的模块文件不存在：lib/%s\n' "$_au_lf"
  fi
done <"$_au_tmp/libfiles.txt"

# ---------------------------------------------------------------------------
# (b) 违规模式扫描
# ---------------------------------------------------------------------------
_au_scan() {
  # $1=文件 $2=lib(1/0)
  awk -v f="$1" -v lib="$2" -v sq="'" -v dq='"' '
    {
      line = $0
      if (in_hd) {
        if (line ~ ("^[ \t]*" hd "[ \t]*$")) in_hd = 0
        next
      }
      t = line; sub(/^[ \t]+/, "", t)
      if (substr(t, 1, 1) == "#") next                 # 注释/文档行跳过
      if (match(line, /<<-?[ \t]*[^ \t]+/)) {          # heredoc 里的内容不算代码
        hd = substr(line, RSTART, RLENGTH)
        sub(/<<-?[ \t]*/, "", hd)
        gsub(sq, "", hd); gsub(dq, "", hd)
        in_hd = 1
      }
      code = line
      if (code ~ /sed[ \t]+-i/ && code ~ /[0-9]+[ \t]*s\//)
        print f ":" NR ": sed -i 按行号改配置（违反规则 2：配置必须由 jq 从 state 重新生成） :: " line
      if (code ~ /(^|[^a-zA-Z_])sed[ \t]+-i([^a-zA-Z_]|$)/)
        print f ":" NR ": 使用 sed -i 直接改文件（违反规则 2） :: " line
      if (code ~ /iptables[^|]*[ \t]-F([ \t]|$)/)
        print f ":" NR ": iptables -F 清空规则表（违反规则 3） :: " line
      if (code ~ /nft[^|]*flush[ \t]+ruleset/)
        print f ":" NR ": nft flush ruleset 清空规则集（违反规则 3） :: " line
      if (code ~ /ufw[^|]*disable/)
        print f ":" NR ": ufw disable 关闭防火墙（违反规则 3） :: " line
      if (code ~ /resolv\.conf/)
        print f ":" NR ": 触碰 /etc/resolv.conf（违反规则 4：不改 DNS 系统设置） :: " line
      if (code ~ /(curl|wget)[^|;]*\|[ \t]*(bash|sh)([ \t]|$)/)
        print f ":" NR ": 下载即执行管道（违反规则 1） :: " line
      if (lib == 1 && code ~ /(^|[; \t])set[ \t]+-[a-zA-Z]*e/)
        print f ":" NR ": lib 内 set -e（会中断调用方的错误处理） :: " line
      if (lib == 1 && code ~ /(^|[^a-zA-Z_.])exit([ \t;]|$)/ && code !~ /^die\(\)/)
        print f ":" NR ": lib 内直接 exit（违反规则 5：只 return，die 除外） :: " line
      # 数据型模块（40-render / 80-subscribe）的 stdout 是数据通道：
      # 日志一旦走 stdout 就会写坏生成的 JSON/YAML/链接（真机踩过：部分协议时 singbox.json 前多一行中文）
      if (f ~ /(40-render|80-subscribe)\.sh$/ && code ~ /(^|[;|&[:space:]])log_(info|ok)([[:space:]]|$)/ && code !~ /log_(info|ok)[^|;]*>&2/)
        print f ":" NR ": 数据型模块里 log_info/log_ok 未重定向到 stderr（会污染 stdout 输出） :: " line
    }
  ' "$1"
}

printf '\n-- (b) 违规模式扫描（注释行与 heredoc 内容已跳过）--\n'
_au_scanned=0
for _au_lib in "${_au_libs[@]}"; do
  _au_scanned=$((_au_scanned + 1))
  printf '   lib/%s\n' "$(basename "$_au_lib")"
  _au_hits="$(_au_scan "$_au_lib" 1)"
  if [ -n "$_au_hits" ]; then
    _au_findings=1
    printf '%s\n' "$_au_hits" | sed 's/^/     /'
  fi
done
_au_entry="$_au_repo/easysb.sh"
if [ -f "$_au_entry" ]; then
  printf '   easysb.sh\n'
  _au_hits="$(_au_scan "$_au_entry" 0)"
  if [ -n "$_au_hits" ]; then
    _au_findings=1
    printf '%s\n' "$_au_hits" | sed 's/^/     /'
  fi
else
  printf '   easysb.sh（不存在，跳过）\n'
fi

# ---------------------------------------------------------------------------
printf '\n== 审计结论 ==\n'
if [ "$_au_findings" = "0" ]; then
  printf '干净：契约函数齐全，未发现违规模式。\n'
  exit 0
fi
printf '有发现：缺失契约函数 %s 个；违规模式见上（每条都带 file:line 与原因）。\n' "$_au_missing_count"
exit 1
