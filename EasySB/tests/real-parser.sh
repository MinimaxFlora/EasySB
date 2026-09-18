#!/usr/bin/env bash
# =============================================================================
# EasySB — tests/real-parser.sh
# 用**真实 sing-box 二进制**校验脚本生成的配置（开发机不是 Linux 时最强的证据）
#
#   1. 在沙箱里生成"五协议全开"的服务端配置与全部客户端配置
#   2. 用多个版本的官方/本仓库二进制分别执行 sing-box check
#   3. 先跑两个控制探针：合法配置必须被接受、含未知字段的配置必须被拒绝
#      （否则说明是探针路径坏了，而不是"配置没问题"）
#
# 用法： bash tests/real-parser.sh [版本...]
#   默认取本仓库 releases 的最新 tag（本仓库编译的内核从 1.14 起）。
#   设 ESB_REALPARSER_EXTRA=1 时会额外尝试官方 SagerNet/sing-box 的旧版本
#   （仅用于"跨内核世代兼容性"的额外证据，安装路径永远只用本仓库的产物）。
# 退出码：0=全部通过；1=有失败；77=没有可用的真实二进制（跳过）
# =============================================================================
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
WORK="${ESB_REALPARSER_WORK:-${TESTS_DIR}/.work/real-parser}"
VERSIONS="${*:-}"

log()  { printf '[real-parser] %s\n' "$*"; }
fatal(){ printf '[real-parser][失败] %s\n' "$*" >&2; exit 1; }

# MSYS 下把路径转成 Windows 程序可读的原生形式（C:/...）
native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1" | tr -d '\r\n'
  else
    printf '%s\n' "$1"
  fi
}

# 关键：curl / sing-box.exe 都是原生程序，工作目录必须给原生路径，
# 否则原生程序收到 MSYS 风格路径（/d/...）会直接写失败（curl: (23)）。
WORK="$(native_path "$WORK")"

# 本机平台对应的下载资产
case "$(uname -m)" in
  x86_64|amd64)  OS_TAG="windows-amd64"; EXT="zip"; BIN_IN_ZIP="sing-box.exe" ;;
  aarch64|arm64) OS_TAG="windows-arm64"; EXT="zip"; BIN_IN_ZIP="sing-box.exe" ;;
  *)             OS_TAG="linux-amd64";   EXT="tar.gz"; BIN_IN_ZIP="sing-box" ;;
esac

# 1) 准备沙箱与 jq
mkdir -p "$WORK"
ROOT="$WORK/root"
rm -rf "$ROOT"; mkdir -p "$ROOT"
ESB_ROOT_NATIVE="$(native_path "$ROOT")"

# jq：优先用系统 jq；开发机（MSYS）上没有时用 tools/bin 里自带的
# 注意：PATH 里的目录必须是 MSYS 风格（/d/x/y），原生 exe 的 argv 才用 D:/x/y，
# 两者混用会让 Windows 程序"找不到文件"或 PATH 形同虚设。
if ! command -v jq >/dev/null 2>&1; then
  _tools_bin="${SUITE_DIR}/tools/bin"
  if command -v cygpath >/dev/null 2>&1; then _tools_bin="$(cygpath -u "${SUITE_DIR}/tools/bin" | tr -d '\r\n')"; fi
  if [ -x "${_tools_bin}/jq.exe" ] || [ -x "${_tools_bin}/jq" ]; then
    PATH="${_tools_bin}:${PATH}"; export PATH
  else
    fatal "找不到 jq（请把 jq 放到 tools/bin/）"
  fi
fi
log "使用 jq：$(command -v jq)"

# 2) 加载被测套件（复用入口的路径模型与模块加载，避免两处维护）
export ESB_ROOT="$ESB_ROOT_NATIVE"
export ESB_GATE=0 ESB_OFFLINE=1 ESB_NO_COLOR=1 ESB_NO_PAUSE=1
# shellcheck source=/dev/null
ESB_NO_MAIN=1 . "${SUITE_DIR}/easysb.sh"
esb_color_init
esb_tmp_init
mkdir -p "$ESB_CERT_DIR" "$ESB_CLIENT_DIR" "$ESB_CONF_DIR" "$ESB_BACKUP_DIR"
state_init || fatal "state_init 失败"

# 没有显式给版本时，用本仓库 releases 的最新 tag（安装与验证都以本仓库产物为准）
if [ -z "$VERSIONS" ]; then
  VERSIONS="$(sb_latest_version 2>/dev/null || true)"
fi
if [ -z "$VERSIONS" ]; then
  fatal "无法获取本仓库最新版本（网络不可达？），请显式传入版本号，例如：bash tests/real-parser.sh 1.14.1"
fi
log "待校验内核版本：$VERSIONS"

# 3) 填充一个完整的部署状态（固定值，便于断言）
state_set_str ".domain" "node.example.com"
state_set_str ".email" "admin@example.com"
state_set_str ".server_ip" "203.0.113.10"
state_set_str ".secrets.vless_uuid" "11111111-2222-4333-8444-555555555555"
state_set_str ".secrets.vmess_uuid" "66666666-7777-4888-8999-000000000000"
state_set_str ".secrets.tuic_uuid"  "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
state_set_str ".secrets.tuic_password" "tuic-pass-0123456789"
state_set_str ".secrets.hysteria2_password" "hy2-pass-0123456789"
state_set_str ".secrets.anytls_password" "anytls-pass-0123456789"
state_set_str ".reality.private_key" "SCytw0AxhrG8S2HNArRWsXXM6xZup0HdSOa2OExE9Gc"
state_set_str ".reality.public_key" "jgcVPebui9A55ultlIF0VuESK8eMi9A0v24-wrYBpzU"
state_set_str ".reality.short_id" "5b6966df"
state_set_str ".reality.handshake_server" "www.microsoft.com"
state_set_str ".reality.server_name" "www.microsoft.com"
for _p in $(esb_proto_keys); do
  state_proto_set_field "$_p" ".enabled" "true" || fatal "启用协议失败：$_p"
done
state_proto_set_field hysteria2 ".hop.enabled" "true"

# 4) 自签证书（check 会读取证书文件，缺文件会被误判为"字段不支持"）
CRT="${ESB_CERT_DIR}/node.example.com.crt"
KEY="${ESB_CERT_DIR}/node.example.com.key"
openssl ecparam -genkey -name prime256v1 -out "$KEY" >/dev/null 2>&1 || fatal "生成私钥失败"
openssl req -new -x509 -key "$KEY" -out "$CRT" -days 3650 -subj "/CN=node.example.com" \
  -addext "subjectAltName=DNS:node.example.com" >/dev/null 2>&1 || fatal "生成证书失败"
state_set_str ".cert.domain" "node.example.com"
state_set_str ".cert.crt" "$CRT"
state_set_str ".cert.key" "$KEY"
state_set_str ".cert.source" "self-signed"

# 5) 生成配置
log "生成服务端配置与客户端配置"
render_config || fatal "render_config 失败"
render_clients || fatal "render_clients 失败"
CLIENT_FILES="$(ls -1 "$ESB_CLIENT_DIR"/*.json 2>/dev/null)"
[ -n "$CLIENT_FILES" ] || fatal "没有生成任何客户端配置"
log "服务端配置：$ESB_CONFIG"
log "客户端配置：$(printf '%s' "$CLIENT_FILES" | tr '\n' ' ')"

check_with() {
  # $1=binary  $2=config  → 0/1
  "$1" check -c "$2" >/dev/null 2>&1
}

FAILED=0
CHECKED=0

for V in $VERSIONS; do
  DIR="$WORK/sb-$V"
  BIN="$DIR/$BIN_IN_ZIP"
  if [ ! -x "$BIN" ]; then
    rm -rf "$DIR"; mkdir -p "$DIR"
    # 本仓库的 release 与官方 release 都试（1.14.1 优先用本仓库，验证用户自己的产物）
    # 内核只从本仓库 releases 取；ESB_REALPARSER_EXTRA=1 时才补测官方旧版本
    REPOS="$ESB_REPO"
    if [ "${ESB_REALPARSER_EXTRA:-0}" = "1" ]; then REPOS="$REPOS SagerNet/sing-box"; fi
    OK=0
    for R in $REPOS; do
      if [ "$OS_TAG" = "windows-amd64" ] || [ "$OS_TAG" = "windows-arm64" ]; then
        ASSET="sing-box-$V-$OS_TAG.zip"
      else
        ASSET="sing-box-$V-$OS_TAG.tar.gz"
      fi
      URL="https://github.com/$R/releases/download/v$V/$ASSET"
      log "下载 $URL"
      if curl -fsSL --connect-timeout 20 --retry 1 -o "$DIR/pkg" "$URL" 2>"$DIR/curl.err"; then
        if [ "$EXT" = "zip" ]; then unzip -q -o "$DIR/pkg" -d "$DIR" >/dev/null 2>&1
        else tar -xzf "$DIR/pkg" -C "$DIR" >/dev/null 2>&1; fi
        FOUND="$(find "$DIR" -type f -name "$BIN_IN_ZIP" | head -1)"
        if [ -n "$FOUND" ] && [ "$FOUND" != "$BIN" ]; then mv -f "$FOUND" "$BIN"; fi
        [ -x "$BIN" ] && chmod 755 "$BIN" 2>/dev/null
        if [ -x "$BIN" ] && "$BIN" version 2>/dev/null | grep -q "$V"; then OK=1; break; fi
      fi
    done
    if [ "$OK" != "1" ]; then
      log "跳过 v$V（下载或解压失败）"
      [ -s "$DIR/curl.err" ] && sed 's/^/        /' "$DIR/curl.err"
      continue
    fi
  fi
  log "===== 用 v$V 校验（$("$BIN" version 2>/dev/null | head -1 | tr -d '\r')） ====="

  # 控制探针
  POS="$DIR/control-valid.json"
  jq -n '{log:{level:"warn"}, outbounds:[{type:"direct",tag:"direct"}]}' >"$POS"
  check_with "$BIN" "$POS" || { log "控制探针失败：合法配置被拒绝，跳过 v$V"; FAILED=$((FAILED+1)); continue; }
  NEG="$DIR/control-invalid.json"
  jq -n '{log:{level:"warn"}, outbounds:[{type:"direct",tag:"direct"}], easysb_bogus:true}' >"$NEG"
  if check_with "$BIN" "$NEG"; then
    log "控制探针失败：非法配置被接受（check 没有真正校验），跳过 v$V"
    FAILED=$((FAILED+1)); continue
  fi
  log "控制探针通过（合法接受 / 非法拒绝）"

  if check_with "$BIN" "$ESB_CONFIG"; then
    log "PASS  服务端配置 v$V"
  else
    log "FAIL  服务端配置 v$V"
    "$BIN" check -c "$ESB_CONFIG" 2>&1 | sed 's/^/        /'
    FAILED=$((FAILED+1))
  fi
  CHECKED=$((CHECKED+1))
  for CFG in $CLIENT_FILES; do
    if check_with "$BIN" "$CFG"; then
      log "PASS  客户端配置 v$V $(basename "$CFG")"
    else
      log "FAIL  客户端配置 v$V $(basename "$CFG")"
      "$BIN" check -c "$CFG" 2>&1 | sed 's/^/        /'
      FAILED=$((FAILED+1))
    fi
  done
done

if [ "$CHECKED" = "0" ]; then
  log "没有任何真实二进制可用于校验（离线或无网络）——跳过（77）"
  exit 77
fi

if [ "$FAILED" = "0" ]; then
  log "全部通过：$CHECKED 个内核版本 × $(printf '%s' "$CLIENT_FILES" | wc -l | tr -d ' ') 个客户端配置"
  exit 0
fi
log "存在 $FAILED 处失败"
exit 1
