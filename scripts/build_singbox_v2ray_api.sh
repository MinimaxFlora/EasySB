#!/bin/bash
# The build the workflow runs, executed here for real: same tags, same ldflags, same
# archive name. It runs against the sing-box source checked out in the working tree.
set -euo pipefail

VERSION="${1:?version, e.g. 1.14.2}"

base=$(cat release/DEFAULT_BUILD_TAGS)
tags="${base},with_v2ray_api"

ldflags="-s -w -buildid= -X github.com/sagernet/sing-box/constant.Version=${VERSION}"
ldflags="${ldflags} -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0"

mkdir -p build
export CGO_ENABLED=0

# linux/amd64, the shape the release asset has (pure-Go runtime included)
export GOOS=linux GOARCH=amd64
go build -trimpath -tags "${tags},with_purego" -ldflags "${ldflags}" -o build/sing-box ./cmd/sing-box
cp LICENSE README.md build/ 2>/dev/null || true
name="sing-box-${VERSION}-linux-amd64.tar.gz"
tar -czf "${name}" -C build sing-box LICENSE README.md
sha256sum "${name}" > "${name}.sha256"
ls -la "${name}"

# the same source for this host, so `version` and `check` can be run locally
export GOOS=windows GOARCH=amd64
go build -trimpath -tags "${tags}" -ldflags "${ldflags}" -o build/sing-box.exe ./cmd/sing-box
ls -la build/sing-box.exe
echo "BUILD OK with tags: ${tags}"
