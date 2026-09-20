#!/usr/bin/env bash
# ==============================================================================
#  EasySB 测试入口 / EasySB test runner
# ------------------------------------------------------------------------------
#  项目地址 Homepage  : https://github.com/MinimaxFlora/EasySB
# ------------------------------------------------------------------------------
#  步骤：先构建 dist/easysb.sh，再依次执行 tests/test-*.sh
#
#  用法 / Usage:
#    bash EasySB/tests/run-tests.sh
# ==============================================================================

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EASYSB_DIR="$(dirname "$TESTS_DIR")"

SUITES=(
  test-build
  test-unit
  test-i18n
  test-static
  test-lint
)

printf '== 构建产物 ==\n'
bash "${EASYSB_DIR}/build.sh" || { printf 'BUILD FAILED\n' >&2; exit 1; }

FAILED=''
for SUITE in "${SUITES[@]}"; do
  printf '\n== %s ==\n' "$SUITE"
  if ! bash "${TESTS_DIR}/${SUITE}.sh"; then
    FAILED="${FAILED} ${SUITE}"
  fi
done

printf '\n== 结果 ==\n'
if [ -n "$FAILED" ]; then
  printf 'FAILED:%s\n' "$FAILED" >&2
  exit 1
fi
printf 'ALL TESTS PASSED\n'
