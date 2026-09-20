#!/usr/bin/env bash
# 逐个模块与合成脚本的语法校验 / Syntax checks
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
# shellcheck source=helpers.sh
. "${DIR}/helpers.sh"

printf '\n[syntax]\n'
for f in "${ROOT}"/lib/*.sh; do
  if bash -n "$f"; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done

if [ -s "${ROOT}/dist/easysb.sh" ]; then
  if bash -n "${ROOT}/dist/easysb.sh"; then ok 'bash -n dist/easysb.sh'; else bad 'bash -n dist/easysb.sh'; fi
else
  bad 'dist/easysb.sh missing'
fi

summary
