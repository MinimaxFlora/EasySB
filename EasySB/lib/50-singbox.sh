#!/usr/bin/env bash
# =============================================================================
# EasySB — 50-singbox.sh
# 内核管理：从本仓库 releases 下载/校验/安装/更新，systemd 服务，配置校验，脚本自更新
# 依赖：00-core.sh, 10-detect.sh, 20-state.sh
# =============================================================================
# shellcheck shell=bash

ESB_REPO="${ESB_REPO:-MinimaxFlora/EasySB}"
ESB_REPO_BRANCH="${ESB_REPO_BRANCH:-master}"

# ---------------------------------------------------------------------------
# 版本信息
# ---------------------------------------------------------------------------
version_norm() { printf '%s' "${1-}" | sed -e 's/^v//' -e 's/[[:space:]]*$//' | tr -d '\r'; }

# 0 = a > b, 1 = a < b, 2 = 相等
version_cmp() {
  local _version_cmp_a _version_cmp_b _version_cmp_top
  _version_cmp_a="$(version_norm "$1")"
  _version_cmp_b="$(version_norm "$2")"
  [ "$_version_cmp_a" = "$_version_cmp_b" ] && return 2
  _version_cmp_top="$(printf '%s\n%s\n' "$_version_cmp_a" "$_version_cmp_b" | sort -V | tail -1)"
  if [ "$_version_cmp_top" = "$_version_cmp_a" ]; then return 0; fi
  return 1
}

sb_installed() { [ -x "${ESB_BIN:-}" ]; }

sb_version() {
  sb_installed || return 0
  local _sb_version_out=""
  if [ "${ESB_GATE:-0}" = "1" ] && [ "${ESB_STUB_BIN:-0}" = "1" ]; then
    _sb_version_out="$("$ESB_BIN" version 2>/dev/null | head -1)"
  else
    _sb_version_out="$("$ESB_BIN" version 2>/dev/null | head -1)"
  fi
  printf '%s\n' "$_sb_version_out" | sed -n 's/.*version[[:space:]]\+\([0-9][0-9.]*\).*/\1/p' | tr -d '\r'
  return 0
}

_release_api_latest() { http_json "https://api.github.com/repos/${ESB_REPO}/releases/latest"; }
_release_api_tag()    { http_json "https://api.github.com/repos/${ESB_REPO}/releases/tags/v$(version_norm "$1")"; }

sb_latest_version() {
  local _slv_json _slv_tag=""
  _slv_json="$(_release_api_latest)"
  if [ -n "$_slv_json" ]; then
    _slv_tag="$(printf '%s' "$_slv_json" | jq -r '.tag_name // empty' 2>/dev/null | tr -d '\r')"
  fi
  if [ -z "$_slv_tag" ]; then
    # 兜底：跟随 releases/latest 的跳转（HTTP 头里的 location 大小写不固定，必须忽略大小写匹配）
    if cmd_exists curl; then
      _slv_tag="$(curl -fsSI --connect-timeout 10 "https://github.com/${ESB_REPO}/releases/latest" 2>/dev/null \
        | tr -d '\r' | awk -F'/' 'tolower($1) ~ /^location:/ {print $NF}' | tail -1)"
    fi
  fi
  version_norm "$_slv_tag"
  return 0
}

script_latest_version() {
  local _slv_url="https://raw.githubusercontent.com/${ESB_REPO}/${ESB_REPO_BRANCH}/EasySB/VERSION"
  if [ "${ESB_OFFLINE:-0}" = "1" ]; then printf '\n'; return 0; fi
  if cmd_exists curl; then
    curl -fsSL --connect-timeout 10 "$_slv_url" 2>/dev/null | tr -d '\r\n' | head -c 32
  fi
  printf '\n'
  return 0
}

sb_asset_name() {
  printf 'sing-box-%s-%s.tar.gz\n' "$(version_norm "$1")" "${ESB_ASSET:-linux-amd64}"
}

sb_asset_url() {
  printf 'https://github.com/%s/releases/download/v%s/%s\n' "$ESB_REPO" "$(version_norm "$1")" "$(sb_asset_name "$1")"
}

# 从 API 取该资产的 sha256（形如 sha256:xxx），取不到输出空
sb_asset_digest() {
  local _sad_ver="$1" _sad_name="$2" _sad_json=""
  _sad_json="$(_release_api_tag "$_sad_ver")"
  [ -n "$_sad_json" ] || return 0
  printf '%s' "$_sad_json" | jq -r --arg n "$_sad_name" \
    '.assets[]? | select(.name==$n) | (.digest // "")' 2>/dev/null | tr -d '\r' | head -1
  return 0
}

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
sb_ensure_user() {
  if [ "${ESB_INIT:-systemd}" != "systemd" ]; then return 0; fi
  if ! id sing-box >/dev/null 2>&1; then
    log_info "创建 sing-box 系统用户"
    run_gate "创建 sing-box 用户" useradd -r -s /usr/sbin/nologin -d "$ESB_STATE_DIR" sing-box >/dev/null 2>&1 \
      || run_gate "创建 sing-box 用户(adduser)" adduser -S -D -H -s /sbin/nologin sing-box >/dev/null 2>&1 \
      || log_warn "无法创建 sing-box 用户，服务将以 root 运行"
  fi
  return 0
}

# 服务以 sing-box 用户运行（unit 里的 User=sing-box），而配置文件是 root 写的：
# 这里把配置与证书调成 root:sing-box 640/750，否则服务启动时会 permission denied。
sb_fix_perms() {
  local _sb_fp_grp="sing-box"
  if [ "${ESB_INIT:-systemd}" != "systemd" ]; then return 0; fi
  if ! id "$_sb_fp_grp" >/dev/null 2>&1; then return 0; fi
  if [ -d "$ESB_CONF_DIR" ]; then
    run_gate "设置配置目录属主" chown "root:${_sb_fp_grp}" "$ESB_CONF_DIR" >/dev/null 2>&1 || true
    run_gate "设置配置目录权限" chmod 750 "$ESB_CONF_DIR" >/dev/null 2>&1 || true
  fi
  if [ -f "$ESB_CONFIG" ]; then
    run_gate "设置配置属主" chown "root:${_sb_fp_grp}" "$ESB_CONFIG" >/dev/null 2>&1 || true
    run_gate "设置配置权限" chmod 640 "$ESB_CONFIG" >/dev/null 2>&1 || true
  fi
  if [ -d "$ESB_CERT_DIR" ]; then
    run_gate "设置证书属主" chown -R "root:${_sb_fp_grp}" "$ESB_CERT_DIR" >/dev/null 2>&1 || true
    chmod 750 "$ESB_CERT_DIR" 2>/dev/null || true
    find "$ESB_CERT_DIR" -maxdepth 1 -type f -name '*.key' -exec chmod 640 {} + 2>/dev/null || true
    find "$ESB_CERT_DIR" -maxdepth 1 -type f -name '*.crt' -exec chmod 644 {} + 2>/dev/null || true
  fi
  return 0
}

sb_ensure_dirs() {
  mkdir -p "$ESB_CONF_DIR" "$ESB_CERT_DIR" "$ESB_CLIENT_DIR" "$ESB_STATE_DIR" "$ESB_BACKUP_DIR" "$(dirname "$ESB_BIN")" 2>/dev/null || true
  chmod 750 "$ESB_CONF_DIR" "$ESB_STATE_DIR" 2>/dev/null || true
  chmod 700 "$ESB_DIR" "$ESB_SECRET_DIR" 2>/dev/null || true
  return 0
}

# sb_install <version|latest> [--no-service]
sb_install() {
  local _sb_install_req="${1:-latest}"
  local _sb_install_ver="" _sb_install_asset _sb_install_url _sb_install_dir
  local _sb_install_tmp _sb_install_tgz _sb_install_bin _sb_install_old=""

  if [ "${ESB_GATE:-0}" = "1" ] && [ "${ESB_STUB_BIN:-0}" = "1" ]; then
    log_warn "沙箱模式：跳过真实下载"
    return 0
  fi

  _sb_install_ver="$(version_norm "$_sb_install_req")"
  if [ -z "$_sb_install_ver" ] || [ "$_sb_install_ver" = "latest" ]; then
    log_info "查询最新版本…"
    _sb_install_ver="$(sb_latest_version)"
  fi
  if [ -z "$_sb_install_ver" ]; then
    error "无法获取最新版本号（网络不可达？）。可手动指定版本号重试"
    return 1
  fi

  # 版本下限提示：本仓库编译的内核从 1.14 起，AnyTLS 从 1.12 起才存在
  version_cmp "$_sb_install_ver" "1.12.0"
  if [ "$?" = "1" ]; then
    log_warn "所选内核 v${_sb_install_ver} 低于 1.12：AnyTLS 协议不可用（本仓库提供的内核从 1.14 起）"
  fi

  _sb_install_asset="$(sb_asset_name "$_sb_install_ver")"
  _sb_install_url="$(sb_asset_url "$_sb_install_ver")"
  _sb_install_dir="${ESB_TMP}/kernel-${_sb_install_ver}"
  rm -rf "$_sb_install_dir"; mkdir -p "$_sb_install_dir" || return 1
  _sb_install_tgz="${_sb_install_dir}/${_sb_install_asset}"

  log_info "下载 sing-box v${_sb_install_ver}（${ESB_ASSET}）"
  log_debug "URL: $_sb_install_url"
  if ! http_get "$_sb_install_url" "$_sb_install_tgz"; then
    error "下载失败：$_sb_install_url"
    log_info "说明：内核只从本仓库 releases 安装（本仓库编译的内核从 1.14 起），指定更旧的版本会 404"
    log_info "可先手动下载后放到 $ESB_TMP 再重试，或检查服务器网络/代理"
    return 1
  fi

  # 校验 sha256（以 API 提供的 digest 为准）
  local _sb_install_digest _sb_install_sum
  _sb_install_digest="$(sb_asset_digest "$_sb_install_ver" "$_sb_install_asset")"
  _sb_install_sum="$(sha256_of "$_sb_install_tgz")" || { error "无法计算下载文件校验和"; return 1; }
  if [ -n "$_sb_install_digest" ]; then
    if [ "${_sb_install_digest#sha256:}" != "$_sb_install_sum" ]; then
      error "校验和与官方发布不一致，已中止安装"
      log_err "期望：${_sb_install_digest#sha256:}"
      log_err "实际：$_sb_install_sum"
      return 1
    fi
    log_ok "校验和匹配：$_sb_install_sum"
  else
    log_warn "未能从 API 获取官方校验和，已计算本地校验和：$_sb_install_sum"
  fi

  # 解压（独立目录，避免解到别的版本）
  tar -xzf "$_sb_install_tgz" -C "$_sb_install_dir" || { error "解压失败"; return 1; }
  _sb_install_bin="$(find "$_sb_install_dir" -type f -name sing-box -perm -u+x | head -1)"
  if [ -z "$_sb_install_bin" ]; then
    _sb_install_bin="$(find "$_sb_install_dir" -type f -name 'sing-box' | head -1)"
  fi
  [ -n "$_sb_install_bin" ] || { error "压缩包中未找到 sing-box 可执行文件"; return 1; }
  chmod 755 "$_sb_install_bin" || true

  # 自证版本（防止装到错误的版本）
  local _sb_install_report
  _sb_install_report="$("$_sb_install_bin" version 2>/dev/null | head -1 | tr -d '\r')"
  if ! printf '%s' "$_sb_install_report" | grep -q "$_sb_install_ver"; then
    error "下载的二进制版本与请求不符：期望 $_sb_install_ver，实际 [$_sb_install_report]"
    return 1
  fi

  # 备份旧内核
  if sb_installed; then
    _sb_install_old="$(sb_version)"
    if [ -n "$_sb_install_old" ] && [ "$_sb_install_old" != "$_sb_install_ver" ]; then
      mkdir -p "$ESB_BACKUP_DIR" 2>/dev/null || true
      cp -p "$ESB_BIN" "${ESB_BACKUP_DIR}/sing-box.${_sb_install_old}" 2>/dev/null \
        && log_info "已备份旧内核：${ESB_BACKUP_DIR}/sing-box.${_sb_install_old}"
    fi
  fi

  sb_ensure_dirs
  sb_ensure_user
  if ! run_gate "安装内核" install -m 0755 "$_sb_install_bin" "${ESB_BIN}.new"; then
    # 沙箱/无 install 时用 cp
    cp -f "$_sb_install_bin" "${ESB_BIN}.new" || { error "拷贝内核失败"; return 1; }
    chmod 755 "${ESB_BIN}.new" 2>/dev/null || true
  fi
  mv -f "${ESB_BIN}.new" "$ESB_BIN" || { error "替换内核失败"; return 1; }
  log_ok "sing-box v${_sb_install_ver} 已安装到 $ESB_BIN"

  unit_install
  sb_fix_perms >/dev/null 2>&1 || true
  sb_service enable >/dev/null 2>&1 || true

  state_set_str ".kernel.version" "$_sb_install_ver" || true
  state_set_str ".kernel.arch_asset" "$ESB_ASSET" || true
  state_set_str ".kernel.binary" "$ESB_BIN" || true
  state_set_str ".kernel.installed_at" "$(esb_now)" || true
  state_set_str ".kernel.checksum" "sha256:$_sb_install_sum" || true
  return 0
}

sb_update() {
  local _sb_update_cur _sb_update_new
  _sb_update_cur="$(sb_version)"
  log_info "当前内核版本：${_sb_update_cur:-未安装}"
  log_info "查询仓库最新版本…"
  _sb_update_new="$(sb_latest_version)"
  if [ -z "$_sb_update_new" ]; then
    error "无法获取最新版本（网络不可达）"
    return 1
  fi
  if [ -n "$_sb_update_cur" ] && [ "$_sb_update_cur" = "$_sb_update_new" ]; then
    log_ok "已是最新版本（v${_sb_update_new}），无需更新"
    return 0
  fi
  log_info "准备更新：${_sb_update_cur:-无} → ${_sb_update_new}"
  sb_install "$_sb_update_new" || return 1
  if [ -f "$ESB_CONFIG" ]; then
    if sb_check_config "$ESB_CONFIG"; then
      sb_service restart || log_warn "服务重启失败，请检查 systemctl status sing-box"
    else
      log_warn "新内核校验配置未通过，请检查配置与版本兼容性"
    fi
  fi
  log_ok "内核更新完成：v${_sb_update_new}"
  return 0
}

# ---------------------------------------------------------------------------
# 配置校验 / 能力探测
# ---------------------------------------------------------------------------
sb_check_config() {
  local _sbcc_file="${1:-$ESB_CONFIG}" _sbcc_err
  [ -f "$_sbcc_file" ] || { error "配置文件不存在：$_sbcc_file"; return 1; }
  sb_installed || { log_warn "未安装 sing-box，跳过配置校验"; return 0; }
  if _sbcc_err="$("$ESB_BIN" check -c "$_sbcc_file" 2>&1)"; then
    log_debug "配置校验通过：$_sbcc_file"
    return 0
  fi
  log_err "sing-box check 失败："
  printf '%s\n' "$_sbcc_err" | sed 's/^/    /' >&2
  esb_log_raw "[CHECK] $_sbcc_err"
  return 1
}

# 生成探针用的临时证书（TLS inbound 探针需要真实文件，否则会被误判为不支持）
_probe_tls_files() {
  local _ptf_dir="$1"
  [ -f "${_ptf_dir}/probe.crt" ] && [ -f "${_ptf_dir}/probe.key" ] && return 0
  cmd_exists openssl || return 1
  openssl ecparam -genkey -name prime256v1 -out "${_ptf_dir}/probe.key" >/dev/null 2>&1 || return 1
  openssl req -new -x509 -key "${_ptf_dir}/probe.key" -out "${_ptf_dir}/probe.crt" -days 1 \
    -subj "/CN=probe.local" >/dev/null 2>&1 || return 1
  return 0
}

# 探针配置片段（inbounds 数组）
_probe_prog() {
  case "$1" in
    anytls_inbound)
      printf '%s' '[{"type":"anytls","listen":"127.0.0.1","listen_port":1,
        "users":[{"password":"probe"}],
        "tls":{"enabled":true,"certificate_path":"CERT","key_path":"KEY"}}]' ;;
    tuic_inbound)
      printf '%s' '[{"type":"tuic","listen":"127.0.0.1","listen_port":2,
        "users":[{"uuid":"00000000-0000-0000-0000-000000000000","password":"probe"}],
        "zero_rtt_handshake":false,
        "tls":{"enabled":true,"certificate_path":"CERT","key_path":"KEY"}}]' ;;
    hysteria2_inbound)
      printf '%s' '[{"type":"hysteria2","listen":"127.0.0.1","listen_port":3,
        "users":[{"password":"probe"}],
        "tls":{"enabled":true,"certificate_path":"CERT","key_path":"KEY"}}]' ;;
    vmess_ws_transport)
      printf '%s' '[{"type":"vmess","listen":"127.0.0.1","listen_port":4,
        "users":[{"uuid":"00000000-0000-0000-0000-000000000000","alterId":0}],
        "transport":{"type":"ws","path":"/vmess","max_early_data":2048,
                     "early_data_header_name":"Sec-WebSocket-Protocol"},
        "tls":{"enabled":true,"certificate_path":"CERT","key_path":"KEY"}}]' ;;
    vless_reality_inbound)
      printf '%s' '[{"type":"vless","listen":"127.0.0.1","listen_port":5,
        "users":[{"uuid":"00000000-0000-0000-0000-000000000000","flow":"xtls-rprx-vision"}],
        "tls":{"enabled":true,"server_name":"probe.local",
               "reality":{"enabled":true,
                          "handshake":{"server":"probe.local","server_port":443},
                          "private_key":"SCytw0AxhrG8S2HNArRWsXXM6xZup0HdSOa2OExE9Gc",
                          "short_id":["01234567"]}}}]' ;;
    legacy_sniff_field)
      printf '%s' '[{"type":"mixed","listen":"127.0.0.1","listen_port":6,"sniff":true}]' ;;
    *) return 1 ;;
  esac
  return 0
}

# probe_inbound <名字> → true / false / unknown
probe_inbound() {
  local _pi_name="$1" _pi_dir="${ESB_TMP}/probe"
  mkdir -p "$_pi_dir" || { printf 'unknown\n'; return 0; }
  local _pi_prog; _pi_prog="$(_probe_prog "$_pi_name")" || { printf 'unknown\n'; return 0; }
  local _pi_crt="" _pi_key=""
  if printf '%s' "$_pi_prog" | grep -q 'CERT'; then
    if _probe_tls_files "$_pi_dir"; then
      _pi_crt="$_pi_dir/probe.crt"; _pi_key="$_pi_dir/probe.key"
    else
      printf 'unknown\n'; return 0
    fi
  fi
  printf '%s' "$_pi_prog" | jq --arg c "$_pi_crt" --arg k "$_pi_key" \
    'map(if .tls then .tls.certificate_path=$c | .tls.key_path=$k else . end)' \
    >"${_pi_dir}/in.json" 2>/dev/null || { printf 'unknown\n'; return 0; }
  jq -n --slurpfile inb "${_pi_dir}/in.json" \
    '{log:{level:"warn"}, inbounds:$inb[0], outbounds:[{type:"direct",tag:"direct"}]}' \
    >"${_pi_dir}/cfg.json" 2>/dev/null || { printf 'unknown\n'; return 0; }
  if "$ESB_BIN" check -c "${_pi_dir}/cfg.json" >/dev/null 2>&1; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
  return 0
}

probe_capabilities() {
  sb_installed || { log_warn "未安装 sing-box，跳过能力探测"; return 1; }
  jq_ok || { log_warn "缺少 jq，跳过能力探测"; return 1; }
  local _pc_dir="${ESB_TMP}/probe" _pc_cap="${ESB_DIR}/capabilities.json"
  rm -rf "$_pc_dir"; mkdir -p "$_pc_dir" || return 1

  # 控制探针一：最小合法配置必须被接受
  jq -n '{log:{level:"warn"}, outbounds:[{type:"direct",tag:"direct"}]}' >"${_pc_dir}/valid.json"
  if ! "$ESB_BIN" check -c "${_pc_dir}/valid.json" >/dev/null 2>&1; then
    log_warn "控制探针失败：最小合法配置被拒绝（探针路径/二进制有问题），放弃能力探测"
    return 1
  fi
  # 控制探针二：含未知字段的配置必须被拒绝
  jq -n '{log:{level:"warn"}, outbounds:[{type:"direct",tag:"direct"}], easysb_bogus:true}' >"${_pc_dir}/invalid.json"
  if "$ESB_BIN" check -c "${_pc_dir}/invalid.json" >/dev/null 2>&1; then
    log_warn "控制探针失败：非法配置被接受（check 未在真正校验），放弃能力探测"
    return 1
  fi

  local _pc_out='{}' _pc_name _pc_val
  for _pc_name in anytls_inbound tuic_inbound hysteria2_inbound vmess_ws_transport \
                  vless_reality_inbound legacy_sniff_field; do
    _pc_val="$(probe_inbound "$_pc_name")"
    _pc_out="$(printf '%s' "$_pc_out" | jq --arg k "$_pc_name" --arg v "$_pc_val" '. + {($k):$v}')"
  done
  _pc_out="$(printf '%s' "$_pc_out" | jq --arg v "$(sb_version)" '. + {version:$v, probed_at:(now|todate)}')"
  printf '%s\n' "$_pc_out" | json_write "$_pc_cap" 600 && log_ok "能力探测结果已写入：$_pc_cap"
  return 0
}

# ---------------------------------------------------------------------------
# systemd unit / 服务
# ---------------------------------------------------------------------------
# 判断某个 unit / 配置文件是不是 EasySB 自己写的。
# 依据是 EasySB 写入的标记（unit 里是注释行，配置目录里是侧车标记文件），
# 这样即使用户把 unit 换成别的脚本的版本也能识别出来（真机踩过：sb.sh 覆盖了同一个 unit）。
ESB_UNIT_MARKER="EasySB-MANAGED"

unit_is_easysb() {
  local _uie_file="$1"
  [ -f "$_uie_file" ] || return 1
  grep -q "$ESB_UNIT_MARKER" "$_uie_file" 2>/dev/null
}

# 打印检测到的"外部 sing-box 部署"细节；没有则返回 1
foreign_singbox_report() {
  local _fsr_found=0 _fsr_unit _fsr_cfg _fsr_pid _fsr_cmd
  _fsr_unit="${ESB_UNIT_DIR}/sing-box.service"
  if [ -f "$_fsr_unit" ] && ! unit_is_easysb "$_fsr_unit"; then
    _fsr_found=1
    log_warn "检测到非 EasySB 管理的 systemd unit：$_fsr_unit"
    printf '        ExecStart: %s\n' "$(grep -m1 '^ExecStart=' "$_fsr_unit" 2>/dev/null | cut -d= -f2-)" >&2
    printf '        处理建议：先备份该 unit 与它的配置，再用 ESB_TAKEOVER=1 重新运行本脚本接管\n' >&2
  fi
  _fsr_cfg="${ESB_CONFIG}"
  if [ -f "$_fsr_cfg" ] && [ ! -f "${ESB_CONF_DIR}/.easysb-managed" ]; then
    _fsr_found=1
    log_warn "检测到非 EasySB 生成的配置：$_fsr_cfg（缺少 EasySB 标记文件）"
  fi
  _fsr_pid="$(pgrep -x sing-box 2>/dev/null | head -1)"
  if [ -n "$_fsr_pid" ]; then
    _fsr_cmd="$(cat "/proc/${_fsr_pid}/cmdline" 2>/dev/null | tr '\0' ' ')"
    case "$_fsr_cmd" in
      *"$ESB_CONF_DIR"*) ;;
      *)
        _fsr_found=1
        log_warn "正在运行的 sing-box 用的不是 EasySB 的配置目录：${_fsr_cmd:-未知}"
        ;;
    esac
  fi
  [ "$_fsr_found" = "1" ]
}

foreign_singbox_detected() { foreign_singbox_report >/dev/null 2>&1; }
foreign_singbox_detected_quiet() {
  local _fsrq_found=0 _fsrq_unit="${ESB_UNIT_DIR}/sing-box.service"
  if [ -f "$_fsrq_unit" ] && ! unit_is_easysb "$_fsrq_unit"; then _fsrq_found=1; fi
  if [ -f "$ESB_CONFIG" ] && [ ! -f "${ESB_CONF_DIR}/.easysb-managed" ]; then _fsrq_found=1; fi
  [ "$_fsrq_found" = "1" ]
}

# 是否允许接管外部部署：ESB_TAKEOVER=1（并在交互式运行时再确认一次）
unit_takeover_allowed() {
  [ "${ESB_TAKEOVER:-0}" = "1" ] || return 1
  if [ -t 0 ] && [ "${ESB_ASSUME_YES:-0}" != "1" ]; then
    log_warn "ESB_TAKEOVER=1：将覆盖上面列出的外部 sing-box 部署"
    ask_yesno "确认接管吗？（原文件会被备份到 $ESB_BACKUP_DIR）" n || return 1
  fi
  return 0
}

unit_install() {
  if [ "${ESB_INIT:-systemd}" = "systemd" ]; then
    mkdir -p "$ESB_UNIT_DIR" || return 1
    local _unit_file="${ESB_UNIT_DIR}/sing-box.service"
    if [ -f "$_unit_file" ] && ! unit_is_easysb "$_unit_file"; then
      if ! unit_takeover_allowed; then
        error "拒绝覆盖非 EasySB 管理的 unit：$_unit_file"
        printf '  %s\n' "该 unit 由别的脚本安装（例如 sb.sh 等一键脚本），直接覆盖会中断它正在运行的服务。" >&2
        printf '  %s\n' "可选做法：① 在别的脚本里卸载它；② 备份后用 ESB_TAKEOVER=1 重新运行本脚本接管。" >&2
        return 1
      fi
      mkdir -p "$ESB_BACKUP_DIR" 2>/dev/null || true
      cp -a "$_unit_file" "${ESB_BACKUP_DIR}/sing-box.service.foreign.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
      log_warn "已备份外部 unit 到 $ESB_BACKUP_DIR（继续接管）"
    fi
    cat <<EOF | file_write "$_unit_file" 644
# ${ESB_UNIT_MARKER} (由 EasySB 一键部署脚本生成与管理，请勿手工编辑；改动会在下次部署时被覆盖)
[Unit]
Description=sing-box service (EasySB)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
User=sing-box
StateDirectory=sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=${ESB_BIN} -D ${ESB_STATE_DIR} -C ${ESB_CONF_DIR} run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    run_gate "systemctl daemon-reload" systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
  fi
  # openrc / sysvinit 兜底
  local _init_dir="${ESB_ROOT:-}/etc/init.d"
  mkdir -p "$_init_dir" 2>/dev/null || return 1
  cat <<EOF | file_write "${_init_dir}/sing-box" 755
#!/bin/sh
### BEGIN INIT INFO
# Provides:          sing-box
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: sing-box service (EasySB)
### END INIT INFO
DAEMON="${ESB_BIN}"
ARGS="-D ${ESB_STATE_DIR} -C ${ESB_CONF_DIR} run"
PIDFILE="/var/run/sing-box.pid"
case "\$1" in
  start)   "\$DAEMON" \$ARGS & echo \$! >"\$PIDFILE" ;;
  stop)    [ -f "\$PIDFILE" ] && kill "\$(cat "\$PIDFILE")" && rm -f "\$PIDFILE" ;;
  restart) "\$0" stop; sleep 1; "\$0" start ;;
  status)  [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null ;;
  *)       echo "用法: \$0 {start|stop|restart|status}"; exit 2 ;;
esac
exit 0
EOF
  log_info "已安装 init.d 脚本：${_init_dir}/sing-box"
  return 0
}

unit_remove() {
  if [ "${ESB_INIT:-systemd}" = "systemd" ]; then
    # 只删自己写的 unit：别的脚本装的 unit 不碰（避免卸载本工具把别人的服务删掉）
    if [ -f "${ESB_UNIT_DIR}/sing-box.service" ] && ! unit_is_easysb "${ESB_UNIT_DIR}/sing-box.service"; then
      log_warn "跳过删除非 EasySB 管理的 unit：${ESB_UNIT_DIR}/sing-box.service"
      return 0
    fi
    rm -f "${ESB_UNIT_DIR}/sing-box.service" 2>/dev/null || true
    run_gate "systemctl daemon-reload" systemctl daemon-reload >/dev/null 2>&1 || true
  else
    rm -f "${ESB_ROOT:-}/etc/init.d/sing-box" 2>/dev/null || true
  fi
  return 0
}

sb_service() { service_mgr sing-box "${1:-status}"; }

sb_running() { sb_service status; }

sb_status_line() {
  local _ssl_state="未运行" _ssl_ver _ssl_enabled
  if sb_running; then _ssl_state="${C_GREEN}运行中${C_RESET}"; else _ssl_state="${C_RED}未运行${C_RESET}"; fi
  _ssl_ver="$(sb_version)"; [ -n "$_ssl_ver" ] || _ssl_ver="未安装"
  printf '  sing-box                 : %b（内核 %s）\n' "$_ssl_state" "$_ssl_ver"
  local _ssl_p _ssl_ports=""
  for _ssl_p in $(proto_enabled_list); do
    _ssl_ports="$_ssl_ports ${_ssl_p}:$(proto_port "$_ssl_p")"
  done
  printf '  已启用协议               :%s\n' "${_ssl_ports:- 无}"
  _ssl_enabled="$(state_get .domain)"
  printf '  域名                     : %s\n' "${_ssl_enabled:-未设置}"
  return 0
}

# ---------------------------------------------------------------------------
# 卸载内核
# ---------------------------------------------------------------------------
sb_uninstall() {
  sb_service stop >/dev/null 2>&1 || true
  sb_service disable >/dev/null 2>&1 || true
  unit_remove
  if sb_installed; then
    local _sb_uninstall_ver; _sb_uninstall_ver="$(sb_version)"
    mkdir -p "$ESB_BACKUP_DIR" 2>/dev/null || true
    [ -n "$_sb_uninstall_ver" ] && cp -p "$ESB_BIN" "${ESB_BACKUP_DIR}/sing-box.${_sb_uninstall_ver}" 2>/dev/null
    rm -f "$ESB_BIN" 2>/dev/null || true
    log_ok "内核已卸载（备份保留在 ${ESB_BACKUP_DIR}）"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 脚本自更新
# ---------------------------------------------------------------------------
esb_self_path() {
  local _esp="${ESB_SELF:-}"
  if [ -z "$_esp" ] && [ -n "${BASH_SOURCE[0]:-}" ]; then
    _esp="${BASH_SOURCE[0]}"
  fi
  [ -n "$_esp" ] || return 1
  case "$_esp" in
    /dev/fd/*|/proc/*) return 1 ;;
  esac
  [ -f "$_esp" ] || return 1
  printf '%s\n' "$_esp"
  return 0
}

script_update() {
  local _su_url="https://raw.githubusercontent.com/${ESB_REPO}/${ESB_REPO_BRANCH}/EasySB/dist/easysb.sh"
  local _su_tmp="${ESB_TMP}/easysb.sh.new" _su_self="" _su_newver
  log_info "检查脚本更新…"
  _su_newver="$(script_latest_version)"
  if [ -n "$_su_newver" ]; then
    log_info "仓库脚本版本：v${_su_newver}　当前版本：v${ESB_SCRIPT_VERSION}"
    if [ "$(version_norm "$_su_newver")" = "$(version_norm "$ESB_SCRIPT_VERSION")" ]; then
      log_ok "脚本已是最新版本"
      return 0
    fi
  else
    log_warn "无法从仓库读取版本号，将直接尝试下载最新脚本"
  fi
  if ! http_get "$_su_url" "$_su_tmp"; then
    error "下载脚本失败：$_su_url"
    return 1
  fi
  if ! bash -n "$_su_tmp"; then
    error "下载的脚本语法校验未通过，已中止更新（保留原脚本）"
    rm -f "$_su_tmp"
    return 1
  fi
  _su_self="$(esb_self_path || true)"
  if [ -z "$_su_self" ]; then
    log_warn "当前以管道方式运行（$(printf '%s' "${BASH_SOURCE[0]:-未知}")），无法原地替换"
    log_info "新版脚本已保存到：$_su_tmp"
    return 0
  fi
  mkdir -p "$ESB_BACKUP_DIR" 2>/dev/null || true
  cp -p "$_su_self" "${ESB_BACKUP_DIR}/easysb.sh.$(esb_ts)" 2>/dev/null || true
  if ! run_gate "替换脚本" install -m 0755 "$_su_tmp" "${_su_self}.new"; then
    cp -f "$_su_tmp" "${_su_self}.new" || { error "写入新脚本失败"; return 1; }
    chmod 755 "${_su_self}.new" 2>/dev/null || true
  fi
  mv -f "${_su_self}.new" "$_su_self" || { error "替换脚本失败"; return 1; }
  log_ok "脚本已更新到 v${_su_newver:-最新}，旧版本备份在 ${ESB_BACKUP_DIR}"
  log_info "请重新运行脚本以使用新版本"
  return 0
}
