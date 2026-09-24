#!/bin/bash
# Verify the per-architecture tag choice the workflow makes, locally, before pushing:
# upstream builds amd64/arm64 from DEFAULT_BUILD_TAGS (naive outbound included, which
# needs the Chromium toolchain those jobs set up) and every other architecture from
# DEFAULT_BUILD_TAGS_OTHERS. with_purego is amd64/arm64 only.
set -euo pipefail
cd "$(dirname "$0")/../../sing-box" 2>/dev/null || cd /d/work/sing-box

VERSION="${1:-1.14.2}"
ldflags="-s -w -buildid= -X github.com/sagernet/sing-box/constant.Version=${VERSION}"
ldflags="${ldflags} -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0"
export CGO_ENABLED=0 GOOS=linux

for arch in amd64 arm64 386 armv7 armv6 riscv64 s390x; do
  case "${arch}" in
    amd64) export GOARCH=amd64; base=$(cat release/DEFAULT_BUILD_TAGS); tags="${base},with_v2ray_api,with_purego" ;;
    arm64) export GOARCH=arm64; base=$(cat release/DEFAULT_BUILD_TAGS); tags="${base},with_v2ray_api,with_purego" ;;
    386)   export GOARCH=386 GO386=sse2; base=$(cat release/DEFAULT_BUILD_TAGS_OTHERS); tags="${base},with_v2ray_api" ;;
    armv7) export GOARCH=arm GOARM=7; base=$(cat release/DEFAULT_BUILD_TAGS_OTHERS); tags="${base},with_v2ray_api" ;;
    armv6) export GOARCH=arm GOARM=6; base=$(cat release/DEFAULT_BUILD_TAGS_OTHERS); tags="${base},with_v2ray_api" ;;
    riscv64) export GOARCH=riscv64; base=$(cat release/DEFAULT_BUILD_TAGS_OTHERS); tags="${base},with_v2ray_api" ;;
    s390x) export GOARCH=s390x; base=$(cat release/DEFAULT_BUILD_TAGS_OTHERS); tags="${base},with_v2ray_api" ;;
  esac
  echo "--- linux-${arch}: building"
  go build -trimpath -tags "${tags}" -ldflags "${ldflags}" -o "build/sing-box-${arch}" ./cmd/sing-box
  ls -la "build/sing-box-${arch}" | awk '{print "    ok:", $5, $9}'
done
echo "ALL ARCHES BUILD OK"
