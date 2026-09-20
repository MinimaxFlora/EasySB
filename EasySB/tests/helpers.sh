#!/usr/bin/env bash
# 测试辅助 / Test helpers
set -u

PASS=0
FAIL=0

ok()   { printf '  \033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

assert_file() {
  [ -s "$1" ] && ok "$2" || bad "$2"
}

assert_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -qF -- "$pattern" "$file"; then ok "$name"; else bad "$name"; fi
}

assert_not_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -qF -- "$pattern" "$file"; then bad "$name"; else ok "$name"; fi
}

summary() {
  printf '\n%s: %d, %s: %d\n' 'PASS' "$PASS" 'FAIL' "$FAIL"
  [ "$FAIL" -eq 0 ]
}
