#!/usr/bin/env bash
# 多语言文案测试 / Bilingual catalog test
# 校验 E（英文）与 C（简体中文）数组下标一一对应且无空值

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EASYSB_DIR="$(dirname "$TESTS_DIR")"
I18N_MODULE="${EASYSB_DIR}/lib/01-i18n.sh"

. "${TESTS_DIR}/helpers.sh"

assert_file "文案模块存在" "$I18N_MODULE"

# 文案模块只做数组赋值，可在子 shell 中安全加载
RESULT="$(bash -c '
  source "'"$I18N_MODULE"'"
  MISSING_C=0 MISSING_E=0 EMPTY=0
  for i in "${!E[@]}"; do
    [ -n "${C[$i]}" ] || MISSING_C=$(( MISSING_C + 1 ))
    [ -n "${E[$i]}" ] || EMPTY=$(( EMPTY + 1 ))
  done
  for i in "${!C[@]}"; do
    [ -n "${E[$i]}" ] || MISSING_E=$(( MISSING_E + 1 ))
  done
  printf "E=%d C=%d missing_c=%d missing_e=%d empty_e=%d\n" \
    "${#E[@]}" "${#C[@]}" "$MISSING_C" "$MISSING_E" "$EMPTY"
')"

E_COUNT="$(sed -n 's/^E=\([0-9]*\).*/\1/p' <<< "$RESULT")"
C_COUNT="$(sed -n 's/.*C=\([0-9]*\).*/\1/p' <<< "$RESULT")"
MISSING_C="$(sed -n 's/.*missing_c=\([0-9]*\).*/\1/p' <<< "$RESULT")"
MISSING_E="$(sed -n 's/.*missing_e=\([0-9]*\).*/\1/p' <<< "$RESULT")"
EMPTY_E="$(sed -n 's/.*empty_e=\([0-9]*\).*/\1/p' <<< "$RESULT")"

assert_eq "英文条目数" "$E_COUNT" "$C_COUNT"
assert_eq "英文缺中文翻译数" "$MISSING_C" "0"
assert_eq "中文缺英文翻译数" "$MISSING_E" "0"
assert_eq "空英文条目数" "$EMPTY_E" "0"

# 文案表规模下限，避免模块被误截断
assert_true "文案条目不少于 190 条" test "$E_COUNT" -ge 190

finish_tests "test-i18n"
