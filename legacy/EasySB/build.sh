#!/usr/bin/env bash
# ==============================================================================
#  EasySB 构建脚本 / EasySB build script
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
VERSION_FILE="${SCRIPT_DIR}/VERSION"

CHECK_ONLY=''
[ "${1:-}" = '--check' ] && CHECK_ONLY='is_check'

MODULES=(
  00-header
  01-i18n
  02-utils
  03-detect
  04-core
  05-cert
  06-protocols
  07-firewall
  08-service
  09-subscribe
  10-menu
  11-entry
)

die() { printf 'build failed: %s\n' "$*" >&2; exit 1; }

for MODULE in "${MODULES[@]}"; do
  [ -s "${LIB_DIR}/${MODULE}.sh" ] || die "missing module lib/${MODULE}.sh"
done
head -n 1 "${LIB_DIR}/${MODULES[0]}.sh" | grep -q '^#!/usr/bin/env bash$' \
  || die "lib/${MODULES[0]}.sh must start with the bash shebang"
[ "${MODULES[-1]}" = '11-entry' ] || die "entry module must be the last one"

[ -s "${VERSION_FILE}" ] || die "missing VERSION file"
EASYSB_VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
[ -n "${EASYSB_VERSION}" ] || die "empty VERSION file"

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT
for MODULE in "${MODULES[@]}"; do
  cat "${LIB_DIR}/${MODULE}.sh" >> "$TMP_FILE"
  printf '\n' >> "$TMP_FILE"
done

# 注入版本号 / Inject the version at build time
sed -i "s/@EASYSB_VERSION@/${EASYSB_VERSION}/g" "$TMP_FILE"

bash -n "$TMP_FILE" || die "generated script has syntax errors"

if [ "$CHECK_ONLY" = 'is_check' ]; then
  printf 'check passed: %d modules, %d lines\n' "${#MODULES[@]}" "$(wc -l < "$TMP_FILE")"
  exit 0
fi

mkdir -p "$DIST_DIR"
install -m 0755 "$TMP_FILE" "$OUTPUT"

printf 'built %s\n  version : %s\n  modules : %d\n  lines   : %s\n' \
  "${OUTPUT#"${SCRIPT_DIR}/"}" "$EASYSB_VERSION" "${#MODULES[@]}" "$(wc -l < "$OUTPUT")"
