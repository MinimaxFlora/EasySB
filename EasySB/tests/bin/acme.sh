#!/usr/bin/env bash
# acme.sh stub —— 记录调用；--version 打印固定版本，其余子命令成功（ESB_STUB_ACME_FAIL=1 时失败）
printf '%s\t%s\n' "${0##*/}" "$*" >>"${ESB_TEST_WORK:-/dev/null}/stubs.log" 2>/dev/null || true
case "${1:-}" in
  --version|-v) printf 'https://github.com/acmesh-official/acme.sh\nv3.0.7\n'; exit 0 ;;
esac
if [ "${ESB_STUB_ACME_FAIL:-0}" = "1" ]; then
  printf 'acme.sh stub: 模拟失败（ESB_STUB_ACME_FAIL=1）\n' >&2
  exit 1
fi
exit 0
