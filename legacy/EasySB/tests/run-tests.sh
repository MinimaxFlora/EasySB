#!/usr/bin/env bash
# EasySB 测试入口 / Test runner
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"

printf '== EasySB tests ==\n'

printf '\n[build dist]\n'
bash "${ROOT}/build.sh"

FAILED=0
for t in test-build test-static test-lint; do
  if ! bash "${DIR}/${t}.sh"; then
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  printf '\n== tests failed ==\n'
  exit 1
fi
printf '\n== all tests passed ==\n'
