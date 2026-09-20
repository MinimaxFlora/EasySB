#!/usr/bin/env bash
# 构建产物检查 / Build artifact checks
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
# shellcheck source=helpers.sh
. "${DIR}/helpers.sh"

DIST="${ROOT}/dist/easysb.sh"

printf '\n[build]\n'
assert_file "$DIST" 'dist/easysb.sh exists and is non-empty'
[ -x "$DIST" ] && ok 'dist/easysb.sh is executable' || bad 'dist/easysb.sh is executable'
head -n1 "$DIST" | grep -q '^#!/usr/bin/env bash$' && ok 'shebang present' || bad 'shebang present'
EXPECT_VER="$(tr -d '[:space:]' < "${ROOT}/VERSION")"
assert_contains "$DIST" "SCRIPT_VERSION='${EXPECT_VER}'" 'version injected from VERSION file'
assert_not_contains "$DIST" '@EASYSB_VERSION@' 'version placeholder replaced'
assert_contains "$DIST" '五合一 sing-box' 'banner tagline present'

summary
