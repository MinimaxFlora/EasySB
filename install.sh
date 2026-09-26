#!/usr/bin/env bash
# ==============================================================================
#  EasySB Go 版一键安装脚本 / one-click installer for the Go build
#  项目地址 Homepage : https://github.com/MinimaxFlora/EasySB
# ==============================================================================
#  做两件事 / does two things:
#    1. 检测并安装运行与构建依赖（curl / openssl / jq / qrencode / tar / Go）
#    2. 安装 EasySB 二进制到 /usr/local/bin，并创建 sb 快捷指令
#
#  内核已编译进面板：sing-box 是面板自己的依赖，装完就有，不需要再下载内核。
#  The core is compiled into the panel — sing-box is a dependency of the binary
#  itself, so a finished install already carries it and nothing downloads a core.
#
#  用法 / Usage:
#    bash install.sh                # 安装或升级
#    bash install.sh --from-source  # 强制从源码构建
#    bash install.sh --binary PATH  # 使用本地已编译好的二进制
#    bash install.sh --lang E       # 英文输出
#
#  版本号没有常量：源码树内取根目录 VERSION，独立运行时从默认分支读取同一个文件。
#  The version is not a constant: the in-tree VERSION inside a checkout, otherwise the
#  same file read from the default branch.
# ==============================================================================

set -euo pipefail

REPO='MinimaxFlora/EasySB'
# VERSION / RELEASE_TAG 由 resolve_version 填充（见下），这里不写死任何版本号。
# VERSION / RELEASE_TAG are filled in by resolve_version; no version is hardcoded.
VERSION=''
RELEASE_TAG=''
PREFIX="${PREFIX:-/usr/local}"
BIN_NAME='easysb'
# 源码构建必须带这些标签：with_quic 是 Hysteria2 / TUIC，with_utls 是 Reality，
# with_v2ray_api 是账号流量统计；缺了 with_v2ray_api 面板会照常部署可用节点，只是
# 不计流量。release/TAGS 是唯一的标签来源，工作流读同一个文件；这份常量只在这份
# 脚本离开源码树、读不到 release/TAGS 时兜底，因此必须与它保持一致。
# A source build needs these tags: with_quic for Hysteria2 / TUIC, with_utls for
# Reality, and with_v2ray_api for per-account counters (without it the panel still
# deploys a working node, it just cannot count). release/TAGS is the single source of
# truth and the workflow reads the same file; this constant is only the fallback for
# when this script runs outside the source tree, so it has to match it.
DEFAULT_TAGS='with_quic,with_utls,with_v2ray_api'

LANG_MODE='C'
FROM_SOURCE=0
LOCAL_BINARY=''
SUDO=''

# ------------------------------------------------------------------------------
# 输出辅助 / Output helpers
# ------------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_CYAN=$'\033[36m'; C_BLUE=$'\033[34m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'
else
  C_RESET=''; C_CYAN=''; C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''
fi

_zh() { [ "$LANG_MODE" = 'C' ]; }

log()  { printf '%s%s%s\n' "$C_CYAN"   "==> $*" "$C_RESET"; }
ok()   { printf '%s%s%s\n'  "$C_GREEN"  "  ✓ $*" "$C_RESET"; }
warn() { printf '%s%s%s\n'  "$C_YELLOW" "  ! $*" "$C_RESET" >&2; }
err()  { printf '%s%s%s\n'  "$C_RED"    "  ✗ $*" "$C_RESET" >&2; }
dim()  { printf '%s%s%s\n'  "$C_DIM"    "    $*" "$C_RESET"; }

die() {
  err "$@"
  exit 1
}

# 中英双语提示 / bilingual notice
say() {
  local cn="$1" en="$2"
  if _zh; then printf '%s\n' "$cn"; else printf '%s\n' "$en"; fi
}

# ------------------------------------------------------------------------------
# 参数解析 / Argument parsing
# ------------------------------------------------------------------------------
usage() {
  cat <<'EOF'
EasySB install.sh

  --lang C|E        输出语言 / output language
  --from-source     强制从源码构建 / force build from source
  --binary PATH     使用指定二进制 / use a local binary
  -h, --help        显示帮助 / show this help

面板只用终端自带字形，不再安装 Nerd Font；为兼容旧脚本，--no-font 与
--font-only 仍被接受，但不再做任何事。
The panel only uses glyphs shipped with terminal fonts and no longer installs
a Nerd Font; --no-font and --font-only are still accepted for old scripts but
no longer do anything.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --lang) LANG_MODE="${2:-C}"; shift 2 ;;
    --lang=*) LANG_MODE="${1#*=}"; shift ;;
    --no-font|--font-only) shift ;;
    --from-source) FROM_SOURCE=1; shift ;;
    --binary) LOCAL_BINARY="${2:-}"; shift 2 ;;
    --binary=*) LOCAL_BINARY="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$LANG_MODE" in
  C|c|CN|zh|zh_CN) LANG_MODE='C' ;;
  E|e|EN|en|en_US) LANG_MODE='E' ;;
  *) LANG_MODE='C' ;;
esac

# ------------------------------------------------------------------------------
# 系统探测 / System detection
# ------------------------------------------------------------------------------
PKG_MGR=''
ARCH=''
OS_ID=''

detect_system() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-linux}"
  else
    OS_ID='linux'
  fi

  if command -v apt-get >/dev/null 2>&1; then PKG_MGR='apt'
  elif command -v dnf >/dev/null 2>&1; then PKG_MGR='dnf'
  elif command -v yum >/dev/null 2>&1; then PKG_MGR='yum'
  elif command -v apk >/dev/null 2>&1; then PKG_MGR='apk'
  elif command -v pacman >/dev/null 2>&1; then PKG_MGR='pacman'
  elif command -v zypper >/dev/null 2>&1; then PKG_MGR='zypper'
  else PKG_MGR='unknown'; fi

  case "$(uname -m)" in
    x86_64|amd64) ARCH='amd64' ;;
    aarch64|arm64) ARCH='arm64' ;;
    armv7l|armv7) ARCH='armv7' ;;
    armv6l|armv6) ARCH='armv6' ;;
    i386|i486|i586|i686) ARCH='386' ;;
    riscv64) ARCH='riscv64' ;;
    s390x) ARCH='s390x' ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

# 独立运行时从默认分支读取 VERSION 文件（与 internal/update 是同一个地址），而不是
# 在脚本里写死版本号。用 raw 文件而非 GitHub API：匿名 API 有 60 次/小时的限流，raw
# 没有。
# Standalone runs read the VERSION file from the default branch — the same URL
# internal/update uses — instead of pinning a number. The raw file is used rather than
# the GitHub API because anonymous API calls are rate limited to 60 per hour.
latest_version() {
  local url="https://raw.githubusercontent.com/${REPO}/master/VERSION" v
  v="$(curl -fsSL -A 'EasySB-installer' --connect-timeout 15 "$url" 2>/dev/null)" || return 1
  v="$(printf '%s' "$v" | tr -d '[:space:]')"
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# VERSION 的唯一来源；RELEASE_TAG 永远由它派生，脚本里不再出现第二个版本号。
# The single source of VERSION; RELEASE_TAG is always derived from it, so the script
# carries no second copy of the number.
resolve_version() {
  local dir v

  # 本地二进制自带版本号，无需 release tag。
  # A local binary carries its own version, so no release tag is involved.
  if [ -n "$LOCAL_BINARY" ]; then
    VERSION="$( { "$LOCAL_BINARY" --version 2>/dev/null || true; } | sed -n 's/^EasySB[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)" || VERSION=''
    RELEASE_TAG=''
    return 0
  fi

  # 源码树内以根目录 VERSION 为准（发布工作流读的就是它）。
  # Inside a checkout the root VERSION file wins; it is what the release workflow reads.
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -r "$dir/VERSION" ]; then
    v="$(tr -d '[:space:]' < "$dir/VERSION")"
    if [ -n "$v" ]; then
      VERSION="$v"
      RELEASE_TAG="v${VERSION}"
      return 0
    fi
  fi

  # 独立运行（curl | bash）：从默认分支读取当前版本，而不是固定写死。
  # Standalone (curl | bash): read the current version from the default branch instead
  # of pinning one.
  VERSION="$(latest_version)" || VERSION=''
  [ -n "$VERSION" ] || die "$(say '无法获取最新版本号，请在源码树内运行或检查网络' 'cannot determine the latest version; run inside the source tree or check the network')"
  RELEASE_TAG="v${VERSION}"
}

# 提权执行 / Run as root
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif [ -n "$SUDO" ]; then
    $SUDO "$@"
  else
    die "$(say '需要 root 权限' 'root privileges required')"
  fi
}

setup_sudo() {
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO='sudo'
  fi
}

# ------------------------------------------------------------------------------
# 依赖安装 / Dependency installation
# ------------------------------------------------------------------------------
pkg_install() {
  [ "$#" -eq 0 ] && return 0
  case "$PKG_MGR" in
    apt)
      as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
      ;;
    dnf)    as_root dnf install -y -q "$@" ;;
    yum)    as_root yum install -y -q "$@" ;;
    apk)    as_root apk add --no-cache "$@" ;;
    pacman) as_root pacman -Sy --noconfirm --needed "$@" ;;
    zypper) as_root zypper -n install "$@" ;;
    *)      return 1 ;;
  esac
}

# 运行时依赖 / Runtime dependencies
ensure_runtime_deps() {
  log "$(say '检查运行时依赖' 'Checking runtime dependencies')"
  # 证书用面板内置的 lego 申请，验证在面板自己的进程里完成，所以不再需要 socat 这类
  # 帮 acme.sh 监听 80 端口的工具。
  # Certificates come from the lego client compiled into the panel, which answers the
  # challenge from its own process, so the helper acme.sh needed to hold port 80 is gone.
  local missing=()
  for cmd in curl openssl jq tar gzip; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    say "安装缺失依赖: ${missing[*]}" "Installing missing packages: ${missing[*]}"
    local pkgs=("${missing[@]}")
    pkg_install "${pkgs[@]}" || warn "$(say '部分依赖安装失败，请手动安装' 'some packages failed, install manually')"
  fi
  for cmd in curl openssl jq tar gzip; do
    command -v "$cmd" >/dev/null 2>&1 && ok "$cmd" || warn "$cmd $(say '缺失' 'missing')"
  done

  # qrencode 可选，用于终端二维码 / optional, terminal QR codes
  if command -v qrencode >/dev/null 2>&1; then
    ok 'qrencode'
  else
    if pkg_install qrencode >/dev/null 2>&1; then
      ok 'qrencode'
    else
      dim "$(say 'qrencode 未安装，二维码改为内置渲染' 'qrencode absent, built-in QR renderer is used')"
    fi
  fi
}

# 构建依赖 Go / Go toolchain for source builds
ensure_go() {
  if command -v go >/dev/null 2>&1 && go version >/dev/null 2>&1; then
    ok "$(go version)"
    return 0
  fi
  log "$(say '未检测到 Go，正在安装工具链' 'Go not found, installing toolchain')"
  case "$PKG_MGR" in
    apt)    pkg_install golang-go ;;
    dnf|yum) pkg_install golang ;;
    apk)    pkg_install go ;;
    pacman) pkg_install go ;;
    zypper) pkg_install go ;;
    *)      _install_go_tarball ;;
  esac
  command -v go >/dev/null 2>&1 || _install_go_tarball
  command -v go >/dev/null 2>&1 || die "$(say 'Go 安装失败' 'failed to install Go')"
  ok "$(go version)"
}

# 官方 tarball 兜底 / Fallback: official tarball
_install_go_tarball() {
  local goversion='1.27.1' goarch tgz tmp
  case "$ARCH" in
    amd64) goarch='amd64' ;;
    arm64) goarch='arm64' ;;
    armv7) goarch='armv6l' ;;
    386)   goarch='386' ;;
    *)     return 1 ;;
  esac
  tgz="go${goversion}.linux-${goarch}.tar.gz"
  tmp="$(mktemp -d)"
  say "下载 Go ${goversion} (${goarch})" "Downloading Go ${goversion} (${goarch})"
  if ! curl -fsSL --connect-timeout 20 -o "$tmp/$tgz" "https://go.dev/dl/$tgz"; then
    warn "$(say '下载 Go 失败' 'failed to download Go')"
    return 1
  fi
  as_root tar -C /usr/local -xzf "$tmp/$tgz" || return 1
  export PATH="/usr/local/go/bin:$PATH"
  return 0
}

# ------------------------------------------------------------------------------
# EasySB 二进制安装 / EasySB binary installation
# ------------------------------------------------------------------------------
download_binary() {
  local url="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/easysb-linux-${ARCH}"
  local out="$1"
  say "尝试下载预编译二进制" "Trying prebuilt binary"
  dim "$url"
  curl -fsSL -A 'EasySB-installer' --connect-timeout 15 -o "$out" "$url" 2>/dev/null || return 1
  [ -s "$out" ] || return 1
  return 0
}

build_from_source() {
  local out="$1" srcdir tags
  srcdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$srcdir/go.mod" ] || { warn "$(say '未找到源码' 'source tree not found')"; return 1; }
  ensure_go
  tags="$DEFAULT_TAGS"
  [ -r "$srcdir/release/TAGS" ] && tags="$(tr -d '[:space:]' < "$srcdir/release/TAGS")"
  say "正在从源码构建" "Building from source"
  dim "tags: $tags"
  ( cd "$srcdir" && CGO_ENABLED=0 go build -trimpath -tags "$tags" \
      -ldflags "-s -w" -o "$out" . ) || return 1
  [ -s "$out" ] || return 1
  return 0
}

install_binary() {
  local tmp bin
  tmp="$(mktemp -d)"
  bin="$tmp/easysb"

  if [ -n "$LOCAL_BINARY" ]; then
    [ -s "$LOCAL_BINARY" ] || die "$(say '指定的二进制不存在' 'given binary not found'): $LOCAL_BINARY"
    cp -f "$LOCAL_BINARY" "$bin"
  elif [ "$FROM_SOURCE" -eq 0 ] && download_binary "$bin"; then
    ok "$(say '已获取预编译二进制' 'prebuilt binary downloaded')"
  elif [ -x "$(dirname "${BASH_SOURCE[0]}")/easysb" ]; then
    cp -f "$(dirname "${BASH_SOURCE[0]}")/easysb" "$bin"
    ok "$(say '使用仓库内已编译二进制' 'using in-tree binary')"
  else
    build_from_source "$bin" || die "$(say '无法获取 EasySB 二进制' 'cannot obtain EasySB binary')"
  fi

  chmod 0755 "$bin"
  as_root install -m 0755 "$bin" "$PREFIX/bin/$BIN_NAME"
  as_root ln -sf "$PREFIX/bin/$BIN_NAME" "$PREFIX/bin/sb"
  ok "$(say '已安装' 'installed'): $PREFIX/bin/$BIN_NAME"
  ok "$(say '快捷指令' 'shortcut'): sb"
  rm -rf "$tmp"
}

# ------------------------------------------------------------------------------
# 主流程 / Main
# ------------------------------------------------------------------------------
main() {
  setup_sudo
  detect_system
  ensure_runtime_deps
  resolve_version
  log "EasySB installer · ${OS_ID}/${ARCH} · pkg=${PKG_MGR}${VERSION:+ · v${VERSION}}"
  install_binary

  printf '\n'
  ok "$(say '安装完成，运行 sb 启动' 'Installation complete, run sb to start')"
  dim "$(say '内核已随面板安装，无需再装 sing-box' 'The sing-box core came with the panel, nothing else to install')"
}

main "$@"
