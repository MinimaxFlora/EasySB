#!/usr/bin/env bash
# 核心工具层单元测试 / Core utility unit test
# 在子 shell 中加载 00-header / 01-i18n / 02-utils 三个无副作用的模块，
# 验证文案取值、状态正则与步骤计算等基础能力

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EASYSB_DIR="$(dirname "$TESTS_DIR")"
LIB_DIR="${EASYSB_DIR}/lib"

. "${TESTS_DIR}/helpers.sh"

RUN_UNIT_TEST='
  source "'"$LIB_DIR"'/00-header.sh" >/dev/null 2>&1
  source "'"$LIB_DIR"'/01-i18n.sh"
  source "'"$LIB_DIR"'/02-utils.sh"

  # 文案取值：中文与英文都必须有内容
  L=C; CN="$(text 24)"
  L=E; EN="$(text 24)"
  printf "cn=%s\nen=%s\n" "$CN" "$EN"

  # 状态正则：随语言切换
  L=C; printf "regex_c=%s\n" "$(status_on_off_regex)"
  L=E; printf "regex_e=%s\n" "$(status_on_off_regex)"

  # 步骤计算：b(Reality) + c(Hy2) + h(WS) 三个协议，无订阅、无 Argo
  INSTALL_PROTOCOLS=(b c h)
  IS_SUB=no_sub
  IS_ARGO=no_argo
  calc_install_steps
  printf "steps=%s\n" "$TOTAL_STEPS"

  # 步骤计算：全部协议 + 订阅 + Argo
  INSTALL_PROTOCOLS=(a b c d e f g h i j k l m)
  IS_SUB=is_sub
  IS_ARGO=is_argo
  calc_install_steps
  printf "steps_full=%s\n" "$TOTAL_STEPS"
'

OUTPUT="$(bash -c "$RUN_UNIT_TEST")"

field() { sed -n "s/^$1=//p" <<< "$OUTPUT"; }

assert_true "中文文案非空" test -n "$(field cn)"
assert_true "英文文案非空" test -n "$(field en)"
assert_eq "中文状态正则" "$(field regex_c)" "关闭|开启"
assert_eq "英文状态正则" "$(field regex_e)" "close|open"
assert_eq "三协议步骤数（无订阅/无 Argo）" "$(field steps)" "7"
# 5 个固定步骤 + 订阅/Argo 触发的 nginx 端口 + Reality 私钥 + CDN 域名 + Argo 域名
assert_eq "全协议步骤数（含订阅/Argo）" "$(field steps_full)" "9"

finish_tests "test-unit"
