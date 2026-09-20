#!/usr/bin/env bash
# 构建完整性测试 / Build integrity test
# 校验模块清单与 build.sh 一致、合成产物可被 bash 解析

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EASYSB_DIR="$(dirname "$TESTS_DIR")"
LIB_DIR="${EASYSB_DIR}/lib"
DIST_SCRIPT="${EASYSB_DIR}/dist/easysb.sh"

. "${TESTS_DIR}/helpers.sh"

# 从 build.sh 中提取模块清单，避免测试与构建脚本各写一份顺序
mapfile -t MODULES < <(sed -n '/^MODULES=(/,/^)/p' "${EASYSB_DIR}/build.sh" | grep -oE '^[[:space:]]+[0-9]{2}-[a-z0-9]+' | tr -d ' ')

assert_eq "模块数量" "${#MODULES[@]}" "19"

for MODULE in "${MODULES[@]}"; do
  assert_file "模块存在 lib/${MODULE}.sh" "${LIB_DIR}/${MODULE}.sh"
done

assert_eq "首模块为 00-header" "${MODULES[0]}" "00-header"
assert_eq "末模块为 18-entry" "${MODULES[-1]}" "18-entry"
assert_eq "首行 shebang" "$(head -n 1 "${LIB_DIR}/00-header.sh")" "#!/usr/bin/env bash"

# 入口模块必须包含最终的分发逻辑，否则合成脚本不会执行任何动作
assert_grep "入口模块含菜单调用" '^  menu_setting$' "${LIB_DIR}/18-entry.sh"
assert_grep "入口模块含 CDN 探测" '^check_cdn$' "${LIB_DIR}/18-entry.sh"

assert_true "build.sh --check 通过" bash "${EASYSB_DIR}/build.sh" --check

assert_file "产物 dist/easysb.sh" "$DIST_SCRIPT"
assert_true "产物语法校验" bash -n "$DIST_SCRIPT"
assert_true "产物可执行" test -x "$DIST_SCRIPT"

finish_tests "test-build"
