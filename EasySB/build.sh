#!/usr/bin/env bash
# ==============================================================================
#  EasySB 构建脚本 / EasySB build script
# ------------------------------------------------------------------------------
#  项目地址 Homepage  : https://github.com/MinimaxFlora/EasySB
#  参考项目 Reference : https://github.com/fscarmen/sing-box
# ------------------------------------------------------------------------------
#  作用：把 EasySB/lib/ 下的模块按编号顺序合成单文件发行脚本
#        EasySB/dist/easysb.sh，并在合成后做语法校验。
#
#  之所以合成单文件：用户安装方式是 `bash <(curl .../easysb.sh)`，
#  运行期只下载一个文件，因此模块化只发生在源码层面。
#
#  用法 / Usage:
#    bash EasySB/build.sh            # 生成 dist/easysb.sh
#    bash EasySB/build.sh --check    # 只校验，不写文件
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
DIST_DIR="${SCRIPT_DIR}/dist"
OUTPUT="${DIST_DIR}/easysb.sh"

CHECK_ONLY=''
[ "${1:-}" = '--check' ] && CHECK_ONLY='is_check'

# 模块顺序即 lib 文件名编号顺序，入口模块必须排在最后
MODULES=(
  00-header
  01-i18n
  02-utils
  03-detect
  04-input
  05-config
  06-argo
  07-route
  08-warp
  09-system
  10-ports
  11-firewall
  12-baseconf
  13-install
  14-export
  15-protocols
  16-maintenance
  17-menu
  18-entry
)

die() { printf 'build failed: %s\n' "$*" >&2; exit 1; }

# 前置检查：模块齐全、首模块为 shebang、入口模块在最后
for MODULE in "${MODULES[@]}"; do
  [ -s "${LIB_DIR}/${MODULE}.sh" ] || die "missing module lib/${MODULE}.sh"
done
head -n 1 "${LIB_DIR}/${MODULES[0]}.sh" | grep -q '^#!/usr/bin/env bash$' \
  || die "lib/${MODULES[0]}.sh must start with the bash shebang"
[ "${MODULES[-1]}" = '18-entry' ] || die "entry module must be the last one"

# 合成：模块之间保留空行，保证函数与注释不粘连
TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT
for MODULE in "${MODULES[@]}"; do
  cat "${LIB_DIR}/${MODULE}.sh" >> "$TMP_FILE"
  printf '\n' >> "$TMP_FILE"
done

# 语法校验
bash -n "$TMP_FILE" || die "generated script has syntax errors"

if [ "$CHECK_ONLY" = 'is_check' ]; then
  printf 'check passed: %d modules, %d lines\n' "${#MODULES[@]}" "$(wc -l < "$TMP_FILE")"
  exit 0
fi

mkdir -p "$DIST_DIR"
install -m 0755 "$TMP_FILE" "$OUTPUT"

SCRIPT_VERSION="$(grep -m1 '^VERSION=' "${LIB_DIR}/00-header.sh" | cut -d"'" -f2)"
printf 'built %s\n  version : %s\n  modules : %d\n  lines   : %s\n' \
  "${OUTPUT#"${SCRIPT_DIR}/"}" "$SCRIPT_VERSION" "${#MODULES[@]}" "$(wc -l < "$OUTPUT")"
