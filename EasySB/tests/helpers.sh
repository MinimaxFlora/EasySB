#!/usr/bin/env bash
# 测试断言工具 / Test assertion helpers

TESTS_RUN=0
TESTS_FAILED=0

pass() {
  TESTS_RUN=$(( TESTS_RUN + 1 ))
  printf '  ok   %s\n' "$1"
}

fail() {
  TESTS_RUN=$(( TESTS_RUN + 1 ))
  TESTS_FAILED=$(( TESTS_FAILED + 1 ))
  printf '  FAIL %s\n' "$1"
}

assert_eq() {
  local NAME=$1 ACTUAL=$2 EXPECTED=$3
  if [ "$ACTUAL" = "$EXPECTED" ]; then
    pass "$NAME"
  else
    fail "$NAME (expected=[$EXPECTED] actual=[$ACTUAL])"
  fi
}

assert_true() {
  local NAME=$1
  shift
  if "$@"; then pass "$NAME"; else fail "$NAME"; fi
}

assert_file() {
  local NAME=$1 FILE=$2
  if [ -s "$FILE" ]; then pass "$NAME"; else fail "$NAME (missing or empty: $FILE)"; fi
}

assert_grep() {
  local NAME=$1 PATTERN=$2 FILE=$3
  if grep -qE "$PATTERN" "$FILE"; then pass "$NAME"; else fail "$NAME (pattern not found: $PATTERN)"; fi
}

assert_no_grep() {
  local NAME=$1 PATTERN=$2 FILE=$3
  if grep -qE "$PATTERN" "$FILE"; then fail "$NAME (unexpected pattern: $PATTERN)"; else pass "$NAME"; fi
}

# 汇总并返回测试结果码
finish_tests() {
  local SUITE=$1
  printf '%s: %d checks, %d failed\n' "$SUITE" "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
