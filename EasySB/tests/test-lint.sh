#!/usr/bin/env bash
# 静态语法检查 / Lint test
# 用 shellcheck 扫描产物；若未安装 shellcheck 则跳过
#
# 已知例外：menu_setting() 在 if/else 分支内定义 ACTION[n]() 处理函数。
# 这是合法的 bash 语法（bash -n 可通过），但 shellcheck 的解析器无法处理，
# 会连带报出下列解析类错误码。此清单为白名单，出现清单外的错误码即判定失败。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EASYSB_DIR="$(dirname "$TESTS_DIR")"
DIST_SCRIPT="${EASYSB_DIR}/dist/easysb.sh"

. "${TESTS_DIR}/helpers.sh"

ALLOWED_CODES='SC1036 SC1046 SC1047 SC1072 SC1073'

if ! command -v shellcheck >/dev/null 2>&1; then
  printf '  skip shellcheck 未安装，跳过\n'
  finish_tests "test-lint"
  exit $?
fi

assert_file "产物存在" "$DIST_SCRIPT"

REPORT="$(shellcheck --shell=bash --severity=error "$DIST_SCRIPT" 2>&1 || true)"

UNEXPECTED=''
for CODE in $(grep -oE 'SC[0-9]+' <<< "$REPORT" | sort -u); do
  grep -qw "$CODE" <<< "$ALLOWED_CODES" || UNEXPECTED="${UNEXPECTED} ${CODE}"
done

assert_eq "无白名单外的 shellcheck 错误" "${UNEXPECTED# }" ""

finish_tests "test-lint"
