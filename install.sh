#!/usr/bin/env bash
# ==============================================================================
#  EasySB Go 版一键安装脚本 / one-click installer for the Go build
#  项目地址 Homepage : https://github.com/MinimaxFlora/EasySB
# ==============================================================================
#  做两件事 / does two things:
#    1. 检测并安装运行与构建依赖（curl / openssl / jq / qrencode / tar / Go）
#    2. 安装 EasySB 二进制到 /usr/local/bin，并创建 sb 快捷指令
#
#  用法 / Usage:
#    bash install.sh                # 安装或升级
#    bash install.sh --from-source  # 强制从源码构建
#    bash install.sh --binary PATH  # 使用本地已编译好的二进制
#    bash install.sh --lang E       # 英文输出
# ==============================================================================

set -euo pipefail

VERSION='4.2.1'
REPO='MinimaxFlora/EasySB'
RELEASE_TAG="v${VERSION}"
PREFIX="${PREFIX:-/usr/local}"
BIN_NAME='easysb'

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

# 脚本位于源码树内时以树内 VERSION 为准，避免版本号两处维护
# Prefer the in-tree VERSION when this script sits inside the source tree.
sync_version_from_tree() {
  local dir v
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -r "$dir/VERSION" ] || return 0
  v="$(tr -d '[:space:]' < "$dir/VERSION")"
  [ -n "$v" ] || return 0
  VERSION="$v"
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
  # socat: acme.sh 的 standalone 验证需要一个能监听 80 端口的工具，缺它时申请证书只会
  # 在最后一步报错。若仓库里没有 socat，面板也会在申请前直接提示。
  # socat: acme.sh standalone validation needs a tool that can listen on port 80;
  # without it issuance only fails at the last step. The panel also checks first.
  local missing=()
  for cmd in curl openssl jq tar gzip socat; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    say "安装缺失依赖: ${missing[*]}" "Installing missing packages: ${missing[*]}"
    local pkgs=("${missing[@]}")
    pkg_install "${pkgs[@]}" || warn "$(say '部分依赖安装失败，请手动安装' 'some packages failed, install manually')"
  fi
  for cmd in curl openssl jq tar gzip socat; do
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
  local out="$1" srcdir
  srcdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$srcdir/go.mod" ] || { warn "$(say '未找到源码' 'source tree not found')"; return 1; }
  ensure_go
  say "正在从源码构建" "Building from source"
  ( cd "$srcdir" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o "$out" . ) || return 1
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
  sync_version_from_tree
  log "EasySB installer · ${OS_ID}/${ARCH} · pkg=${PKG_MGR} · v${VERSION}"

  ensure_runtime_deps
  install_binary

  printf '\n'
  ok "$(say '安装完成，运行 sb 启动' 'Installation complete, run sb to start')"
  dim "$(say '首次运行会检测内核与节点状态' 'The dashboard shows core and node state on first launch')"
}

main "$@"
