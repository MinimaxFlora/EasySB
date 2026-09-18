#!/usr/bin/env bash
# =============================================================================
# EasySB 测试运行器 —— 契约见 docs/TESTING.md
#
#   bash tests/run_tests.sh --list              列出全部用例
#   bash tests/run_tests.sh --unit              跑全部用例
#   bash tests/run_tests.sh --case <name>       只跑一个用例
#   bash tests/run_tests.sh [--unit|--case x] --verbose   打印用例完整输出
#
# 退出码：0=全绿   1=有失败   2=用法/环境错误   3=无失败但有 SKIP（环境不完整，例如缺 jq）
# 结果：$ESB_TEST_WORK/results.tsv（case TAB status TAB seconds TAB message）
#       单用例模式只更新自己那一行，不会清掉整轮结果。
# 沙箱：每个用例一个干净 $ESB_TEST_WORK/root/<case>，环境见 TESTING.md 的环境表。
# =============================================================================

_rt_repo_msys="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Windows 上的 jq.exe 是原生程序，读不了 MSYS 风格路径（/d/...）：jq 会直接报
# "Could not open file"。因此所有导出的 ESB_* 路径一律用原生正斜杠形式（D:/...），
# 而 PATH 里的条目必须保持 MSYS 形式，否则 bash 的命令查找不认（实测 D:/... 条目查不到 stub）。
_rt_native_path() {
  local _rt_np_in="${1-}" _rt_np_out=""
  if command -v cygpath >/dev/null 2>&1; then
    _rt_np_out="$(cygpath -m "$_rt_np_in" 2>/dev/null | tr -d '\r\n')"
  fi
  if [ -z "$_rt_np_out" ]; then
    _rt_np_out="$(cd "$_rt_np_in" 2>/dev/null && pwd -W 2>/dev/null | tr -d '\r\n')"
  fi
  if [ -z "$_rt_np_out" ]; then printf '%s' "$_rt_np_in"; else printf '%s' "$_rt_np_out"; fi
}

ESB_REPO_ROOT="$(_rt_native_path "$_rt_repo_msys")"
ESB_TESTS_DIR="$ESB_REPO_ROOT/tests"
ESB_TEST_WORK="$(_rt_native_path "${ESB_TEST_WORK:-$ESB_TESTS_DIR/.work}")"
export ESB_REPO_ROOT ESB_TESTS_DIR ESB_TEST_WORK

_rt_cases_dir="$ESB_TESTS_DIR/cases"
_rt_bin="$_rt_repo_msys/tests/bin"
_rt_tools_bin="$_rt_repo_msys/tools/bin"
_rt_log_dir="$ESB_TEST_WORK/logs"
_rt_results="$ESB_TEST_WORK/results.tsv"

_rt_verbose=0
_rt_mode=""
_rt_case_arg=""

_rt_usage() {
  # 打印文件头部的用法注释块（第 3–13 行），去掉行首的 "# "
  sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  return 0
}

# ---------------------------------------------------------------------------
# PATH：tests/bin（stub）最前；tools/bin 只在"本机没有 jq"时加入，
# 免得 Linux 主机上自带的 jq 被 Windows 的 jq.exe 遮蔽（TESTING.md 环境表）。
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  export PATH="$_rt_bin:$PATH"
  _rt_tools_used="no"
else
  export PATH="$_rt_bin:$_rt_tools_bin:$PATH"
  _rt_tools_used="yes"
fi
_rt_jq="$(command -v jq 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --list|-l)      _rt_mode="list" ;;
    --unit|-u)      _rt_mode="unit" ;;
    --case|-c)
      _rt_mode="case"
      _rt_case_arg="${2-}"
      if [ -z "$_rt_case_arg" ]; then printf '错误：--case 需要一个用例名\n' >&2; exit 2; fi
      shift
      ;;
    --verbose|-v)   _rt_verbose=1 ;;
    --help|-h)      _rt_usage; exit 0 ;;
    *) printf '错误：未知参数 %s\n' "$1" >&2; _rt_usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$_rt_mode" ] || _rt_mode="unit"

# ---------------------------------------------------------------------------
# 加载被测代码（lib/*.sh，文件名字典序）与断言助手
# ---------------------------------------------------------------------------
for _rt_lib in "$ESB_REPO_ROOT"/lib/*.sh; do
  [ -r "$_rt_lib" ] || continue
  # shellcheck disable=SC1090
  . "$_rt_lib" || { printf '错误：无法加载 %s\n' "$_rt_lib" >&2; exit 2; }
done
# shellcheck disable=SC1091
. "$ESB_TESTS_DIR/lib/harness.sh" || { printf '错误：无法加载 tests/lib/harness.sh\n' >&2; exit 2; }

_rt_names=()
declare -A _rt_file_of=()

_rt_collect_cases() {
  local _rt_cc_f _rt_cc_t
  for _rt_cc_f in "$_rt_cases_dir"/*.sh; do
    [ -r "$_rt_cc_f" ] || continue
    TESTS=""
    # shellcheck disable=SC1090
    . "$_rt_cc_f" || { printf '错误：用例文件加载失败 %s\n' "$_rt_cc_f" >&2; exit 2; }
    for _rt_cc_t in ${TESTS:-}; do
      if ! declare -F "$_rt_cc_t" >/dev/null 2>&1; then
        printf '错误：%s 的 TESTS 列出的 "%s" 不是已定义的函数（用例名必须与函数名一致）\n' \
          "$(basename "$_rt_cc_f")" "$_rt_cc_t" >&2
        exit 2
      fi
      if [ -n "${_rt_file_of[$_rt_cc_t]+x}" ]; then
        printf '错误：用例名重复 %s（%s 与 %s）\n' "$_rt_cc_t" "${_rt_file_of[$_rt_cc_t]}" "$_rt_cc_f" >&2
        exit 2
      fi
      _rt_names+=("$_rt_cc_t")
      _rt_file_of["$_rt_cc_t"]="$_rt_cc_f"
    done
  done
  if [ "${#_rt_names[@]}" = "0" ]; then
    printf '错误：%s 下没有用例文件\n' "$_rt_cases_dir" >&2
    exit 2
  fi
}

_rt_jq_note() {
  if [ -n "$_rt_jq" ]; then
    printf '# jq: %s\n' "$_rt_jq"
  else
    printf '# jq: 未找到 —— jq 相关用例会 SKIP（不计为通过）\n'
    printf '#     修复：Linux 主机 apt-get install jq；Windows 开发机把 jq.exe 放到 tools/bin/\n'
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 计时 / 文本清洗
# ---------------------------------------------------------------------------
_rt_now() { printf '%s' "${EPOCHREALTIME:-$(date +%s)}"; }
_rt_secs() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", (b - a)}'; }
_rt_one_line() { printf '%s' "${1-}" | tr '\t\n\r' '   ' | cut -c1-160; }

# ---------------------------------------------------------------------------
# 跑一个用例：独立沙箱 + 独立子 shell
# ---------------------------------------------------------------------------
_rt_rows=()
_rt_rc_fail=0
_rt_rc_skip=0
_rt_rc_pass=0
_rt_t_start="$(_rt_now)"

_rt_run_case() {
  local _rr_name="$1"
  local _rr_root="$ESB_TEST_WORK/root/$_rr_name"
  local _rr_log="$_rt_log_dir/$_rr_name.log"
  local _rr_clean="$_rt_log_dir/$_rr_name.clean"
  local _rr_rc=0

  mkdir -p "$_rt_log_dir" || { printf '错误：无法创建 %s\n' "$_rt_log_dir" >&2; exit 2; }
  rm -rf "$_rr_root" 2>/dev/null || true
  mkdir -p "$_rr_root" || { printf '错误：无法创建沙箱 %s\n' "$_rr_root" >&2; exit 2; }

  # TESTING.md 环境表：runner 设置，用例不得覆盖
  export ESB_ROOT="$_rr_root"
  export ESB_GATE=1
  export ESB_GATE_LOG="$ESB_TEST_WORK/gate.log"
  export ESB_OFFLINE=1
  export ESB_NO_COLOR=1
  export ESB_NO_PAUSE=1
  export ESB_ASSUME_YES=1
  export ESB_TEST_CASE="$_rr_name"
  export ESB_TESTS_DIR
  harness_paths_init

  # 每个用例一份干净证据（gate.log / stubs.log）与固定默认 state.json
  : >"$ESB_TEST_WORK/stubs.log" 2>/dev/null || true
  : >"$ESB_GATE_LOG" 2>/dev/null || true
  ( state_init ) >/dev/null 2>&1 || true

  local _rr_t0 _rr_t1 _rr_secs
  _rr_t0="$(_rt_now)"
  # stdin 固定 /dev/null：非 TTY 契约，任何用例都不可能挂住等输入。
  # 另加看门狗（默认 300s，ESB_TEST_CASE_TIMEOUT 可改）：超时杀掉并记为失败，保证套件一定结束。
  local _rr_limit="${ESB_TEST_CASE_TIMEOUT:-300}"
  local _rr_pid _rr_waited=0 _rr_timeout=0
  ( "$_rr_name" ) </dev/null >"$_rr_log" 2>&1 &
  _rr_pid=$!
  while kill -0 "$_rr_pid" 2>/dev/null; do
    if [ "$_rr_waited" -ge "$_rr_limit" ]; then
      kill -TERM "$_rr_pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$_rr_pid" 2>/dev/null || true
      _rr_timeout=1
      break
    fi
    sleep 1
    _rr_waited=$((_rr_waited + 1))
  done
  wait "$_rr_pid" 2>/dev/null || _rr_rc=$?
  if [ "$_rr_timeout" = "1" ]; then
    _rr_rc=124
    printf 'FAIL %s :: 用例超时（>%ss）已被杀掉\n' "$_rr_name" "$_rr_limit" >>"$_rr_log"
  fi
  _rr_t1="$(_rt_now)"
  _rr_secs="$(_rt_secs "$_rr_t0" "$_rr_t1")"

  # 先剥 ANSI 再匹配/聚合
  sed 's/\x1b\[[0-9;]*m//g' "$_rr_log" >"$_rr_clean" 2>/dev/null || cp -f "$_rr_log" "$_rr_clean" 2>/dev/null

  local _rr_fails _rr_passes _rr_skips
  _rr_fails="$(grep -c '^FAIL ' "$_rr_clean" 2>/dev/null)"
  case "$_rr_fails" in ''|*[!0-9]*) _rr_fails=0 ;; esac
  _rr_passes="$(grep -c '^PASS ' "$_rr_clean" 2>/dev/null)"
  case "$_rr_passes" in ''|*[!0-9]*) _rr_passes=0 ;; esac
  _rr_skips="$(grep -c '^SKIP ' "$_rr_clean" 2>/dev/null)"
  case "$_rr_skips" in ''|*[!0-9]*) _rr_skips=0 ;; esac

  local _rr_status="PASS" _rr_msg=""
  if [ "$_rr_fails" != "0" ]; then
    _rr_status="FAIL"
  elif [ "$_rr_rc" = "77" ] || [ "$_rr_skips" != "0" ]; then
    # 用例整体跳过（return 77）或内部有断言被跳过 → 都算“未验证”，不计入通过
    _rr_status="SKIP"
  elif [ "$_rr_rc" != "0" ]; then
    _rr_status="FAIL"
  fi

  if [ "$_rr_status" = "FAIL" ]; then
    if [ "$_rr_fails" != "0" ]; then
      _rr_msg="$(_rt_one_line "$(grep -m1 '^FAIL ' "$_rr_clean" | sed 's/^FAIL [^:]*:: *//')")"
    else
      _rr_msg="用例以 $_rr_rc 退出且没有断言行"
    fi
  elif [ "$_rr_status" = "SKIP" ]; then
    _rr_msg="$(_rt_one_line "$(grep -m1 '^SKIP ' "$_rr_clean" | sed 's/^SKIP [^:]*:: *//')")"
  else
    _rr_msg="$(_rt_one_line "$(grep -m1 '^SKIP ' "$_rr_clean" | sed 's/^SKIP [^:]*:: *//')")"
  fi

  # 输出：默认只打 PASS/FAIL/SKIP 行及其 4 空格明细；--verbose 全量
  if [ "$_rt_verbose" = "1" ]; then
    cat "$_rr_clean"
  else
    grep -E '^(PASS|FAIL|SKIP) |^    ' "$_rr_clean" 2>/dev/null || true
  fi
  if [ "$_rr_fails" = "0" ] && [ "$_rr_rc" != "0" ] && [ "$_rr_rc" != "77" ]; then
    printf '    --- %s 原始输出（无断言行，rc=%s）---\n' "$_rr_name" "$_rr_rc"
    sed -n '1,20p' "$_rr_clean" | sed 's/^/    /'
  fi

  if [ "$_rr_status" = "PASS" ]; then _rt_rc_pass=$((_rt_rc_pass + 1))
  elif [ "$_rr_status" = "SKIP" ]; then _rt_rc_skip=$((_rt_rc_skip + 1))
  else _rt_rc_fail=$((_rt_rc_fail + 1))
  fi

  _rt_rows+=("$_rr_name	$_rr_status	$_rr_secs	$_rr_msg")
  # 增量落盘：即使整轮被中途杀掉（或 CI 超时），也留下已经跑完的结果
  _rt_write_results >/dev/null 2>&1 || true

  if [ "${ESB_TEST_KEEP_SANDBOX:-0}" != "1" ] && [ "$_rr_status" != "FAIL" ]; then
    rm -rf "$_rr_root" 2>/dev/null || true
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 写 results.tsv（单用例模式只替换自己那一行）
# ---------------------------------------------------------------------------
_rt_write_results() {
  local _rr_w_tmp="$ESB_TEST_WORK/results.new.$$"
  printf '%s\n' "${_rt_rows[@]}" >"$_rr_w_tmp" || return 1
  if [ "$_rt_mode" = "case" ] && [ -f "$_rt_results" ]; then
    awk -F'\t' -v OFS='\t' '
      FNR==NR { new[$1]=$2"\t"$3"\t"$4; order[++n]=$1; next }
      { if ($1 in new) { print $1 "\t" new[$1]; used[$1]=1 } else print }
      END { for (i=1;i<=n;i++) if (!(order[i] in used)) print order[i] "\t" new[order[i]] }
    ' "$_rr_w_tmp" "$_rt_results" >"$_rt_results.tmp.$$" && mv -f "$_rt_results.tmp.$$" "$_rt_results"
  else
    mv -f "$_rr_w_tmp" "$_rt_results"
  fi
  rm -f "$_rr_w_tmp" 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
_rt_collect_cases
mkdir -p "$ESB_TEST_WORK" "$_rt_log_dir" || { printf '错误：无法创建工作目录 %s\n' "$ESB_TEST_WORK" >&2; exit 2; }

if [ "$_rt_mode" = "list" ]; then
  printf '# 仓库: %s\n' "$ESB_REPO_ROOT"
  printf '# 工作目录: %s\n' "$ESB_TEST_WORK"
  _rt_jq_note
  for _rt_l_name in "${_rt_names[@]}"; do
    printf '%s\t%s\n' "$(basename "${_rt_file_of[$_rt_l_name]}")" "$_rt_l_name"
  done
  printf '# 共 %s 个用例（%s 个用例文件）\n' "${#_rt_names[@]}" "$(ls -1 "$_rt_cases_dir"/*.sh 2>/dev/null | wc -l | tr -d ' ')"
  exit 0
fi

printf '== EasySB 测试套件 ==\n'
printf '   仓库      : %s\n' "$ESB_REPO_ROOT"
printf '   工作目录  : %s\n' "$ESB_TEST_WORK"
printf '   stub      : %s\n' "$_rt_bin"
if [ "$_rt_tools_used" = "yes" ]; then printf '   tools/bin : %s（本机无 jq，已加入 PATH）\n' "$_rt_tools_bin"
else printf '   tools/bin : 未加入 PATH（本机已有 jq）\n'; fi
if [ -z "$_rt_jq" ]; then
  printf '\n!! jq 未找到：所有 jq 相关用例会 SKIP，且本轮不会判为"全绿"（退出码 3）\n'
  printf '!!   Linux 主机：apt-get install jq ／ Debian: apt-get install -y jq\n'
  printf '!!   Windows 开发机：把 jq.exe 放进 %s\n\n' "$_rt_tools_bin"
else
  printf '   jq        : %s\n' "$_rt_jq"
fi
printf '\n'

if [ "$_rt_mode" = "case" ]; then
  if [ -z "${_rt_file_of[$_rt_case_arg]+x}" ]; then
    printf '错误：未知用例 %s（用 --list 查看全部用例）\n' "$_rt_case_arg" >&2
    exit 2
  fi
  _rt_run_case "$_rt_case_arg"
else
  for _rt_name in "${_rt_names[@]}"; do
    _rt_run_case "$_rt_name"
  done
fi

_rt_write_results
_rt_t_end="$(_rt_now)"
_rt_total_secs="$(_rt_secs "$_rt_t_start" "$_rt_t_end")"

printf '================ 结果 ================\n'
printf '通过 %s   失败 %s   跳过 %s   用例 %s   用时 %ss\n' \
  "$_rt_rc_pass" "$_rt_rc_fail" "$_rt_rc_skip" "${#_rt_rows[@]}" "$_rt_total_secs"
printf '结果文件: %s\n' "$_rt_results"

if [ "$_rt_rc_fail" != "0" ]; then
  printf '\n失败用例:\n'
  for _rt_row in "${_rt_rows[@]}"; do
    printf '%s' "$_rt_row" | awk -F'	' '$2=="FAIL" { printf "  - %s：%s\n", $1, $4 }'
  done
  exit 1
fi
if [ "$_rt_rc_skip" != "0" ]; then
  printf '\n有 %s 个用例被跳过（环境不完整，未验证）：\n' "$_rt_rc_skip"
  for _rt_row in "${_rt_rows[@]}"; do
    printf '%s' "$_rt_row" | awk -F'	' '$2=="SKIP" { printf "  - %s：%s\n", $1, $4 }'
  done
  exit 3
fi
exit 0
