# ------------------------------------------------------------------------------
# 四、sing-box 内核管理 / Core management
# ------------------------------------------------------------------------------
# 通道：stable（官方 latest release）/ alpha（官方 prerelease）。
# 行为：切换通道保留现有配置；"更新内核"只更新当前已安装的通道。
# ------------------------------------------------------------------------------

CORE_STABLE_VERSION=''
CORE_ALPHA_VERSION=''
CORE_STABLE_URL=''
CORE_ALPHA_URL=''

core_installed() { [ -x "$CORE_BIN" ]; }

local_core_version() {
  [ -x "$CORE_BIN" ] || { printf '%s' "$(text ver_not_installed)"; return 1; }
  "$CORE_BIN" version 2>/dev/null | head -n1 | sed -E 's/.*version[[:space:]]+([^[:space:]]+).*/\1/'
}

# 当前内核通道：优先状态记录，否则按版本号里的 alpha/beta/rc 推断
# Installed channel: state first, otherwise inferred from the version string.
installed_core_channel() {
  if [ -n "${CORE_CHANNEL:-}" ]; then
    printf '%s' "$CORE_CHANNEL"; return 0
  fi
  local v
  v="$(local_core_version 2>/dev/null || true)"
  case "$v" in
    *alpha*|*beta*|*rc*) printf 'alpha' ;;
    *) printf 'stable' ;;
  esac
}

channel_label() {
  if [ "$1" = 'alpha' ]; then
    text ver_channel_alpha
  else
    text ver_channel_stable
  fi
}

# 按官方命名惯例拼装资产地址 / Build asset URL by official naming convention
core_asset_url() {
  local tag="$1"
  printf 'https://github.com/%s/releases/download/%s/sing-box-%s-linux-%s.tar.gz' \
    "$SING_BOX_REPO" "$tag" "${tag#v}" "$ARCH"
}

# 首选 GitHub API / Try API first
_core_releases_api() {
  local json="$TEMP_DIR/releases.json" api="${SING_BOX_API}?per_page=40" prefix got=''
  for prefix in "${GITHUB_PROXY[@]}"; do
    if have_cmd curl && curl -fsSL -A 'EasySB' --connect-timeout 10 -o "$json" "${prefix}${api}" 2>/dev/null; then
      [ -s "$json" ] && got='1' && break
    fi
  done
  [ -z "$got" ] && return 1

  local asset_pat="linux-${ARCH}.tar.gz"
  if have_cmd jq; then
    CORE_STABLE_VERSION="$(jq -r '[.[]|select(.draft==false and .prerelease==false)][0].tag_name // empty' "$json")"
    CORE_STABLE_URL="$(jq -r --arg p "$asset_pat" '[.[]|select(.draft==false and .prerelease==false)][0].assets[]?|select(.name|endswith($p))|.browser_download_url // empty' "$json" | head -n1)"
    CORE_ALPHA_VERSION="$(jq -r '[.[]|select(.draft==false and .prerelease==true)][0].tag_name // empty' "$json")"
    CORE_ALPHA_URL="$(jq -r --arg p "$asset_pat" '[.[]|select(.draft==false and .prerelease==true)][0].assets[]?|select(.name|endswith($p))|.browser_download_url // empty' "$json" | head -n1)"
  else
    CORE_STABLE_VERSION="$(grep -o '"tag_name":[[:space:]]*"[^"]*"' "$json" | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')"
    CORE_STABLE_URL="$(grep -o 'https://[^"]*'"${asset_pat}" "$json" | head -n1)"
    CORE_ALPHA_VERSION="$(grep -o '"tag_name":[[:space:]]*"[^"]*"' "$json" | sed -n '2p' | sed -E 's/.*"([^"]+)"$/\1/')"
    CORE_ALPHA_URL="$(grep -o 'https://[^"]*'"${asset_pat}" "$json" | sed -n '2p')"
  fi
  CORE_STABLE_VERSION="${CORE_STABLE_VERSION#v}"
  CORE_ALPHA_VERSION="${CORE_ALPHA_VERSION#v}"
  [ -n "$CORE_STABLE_VERSION" ] || return 1
  return 0
}

# API 不可用时的兜底：latest 跳转取稳定版，releases.atom 取 alpha
_core_releases_fallback() {
  have_cmd curl || return 1
  local latest_url tag
  latest_url="$(curl -sI -A 'EasySB' --connect-timeout 10 -o /dev/null -w '%{redirect_url}' \
    "https://github.com/${SING_BOX_REPO}/releases/latest" 2>/dev/null)"
  tag="${latest_url##*/}"
  if [ -n "$tag" ] && [ "$tag" != 'latest' ]; then
    CORE_STABLE_VERSION="${tag#v}"
    CORE_STABLE_URL="$(core_asset_url "$tag")"
  fi

  local atom="$TEMP_DIR/releases.atom"
  if curl -fsSL -A 'EasySB' --connect-timeout 10 -o "$atom" \
    "https://github.com/${SING_BOX_REPO}/releases.atom" 2>/dev/null; then
    local atag
    atag="$(grep -oE '<title>[0-9][^<]*(alpha|beta|rc)[^<]*</title>' "$atom" | head -n1 | sed -E 's/<\/?title>//g')"
    if [ -n "$atag" ]; then
      CORE_ALPHA_VERSION="${atag#v}"
      CORE_ALPHA_URL="$(core_asset_url "v${atag#v}")"
    fi
  fi
  [ -n "$CORE_STABLE_VERSION" ] || [ -n "$CORE_ALPHA_VERSION" ]
}

# 输出全局：CORE_<STABLE|ALPHA>_VERSION / _URL
fetch_core_releases() {
  _core_releases_api || true
  if [ -z "$CORE_STABLE_VERSION" ] || [ -z "$CORE_ALPHA_VERSION" ]; then
    local saved_stable="$CORE_STABLE_VERSION" saved_alpha="$CORE_ALPHA_VERSION"
    _core_releases_fallback || true
    [ -n "$saved_stable" ] && CORE_STABLE_VERSION="$saved_stable"
    [ -n "$saved_alpha" ] && CORE_ALPHA_VERSION="$saved_alpha"
  fi
  [ -n "$CORE_STABLE_VERSION" ] && [ -z "$CORE_STABLE_URL" ] && CORE_STABLE_URL="$(core_asset_url "v${CORE_STABLE_VERSION}")"
  [ -n "$CORE_ALPHA_VERSION" ] && [ -z "$CORE_ALPHA_URL" ] && CORE_ALPHA_URL="$(core_asset_url "v${CORE_ALPHA_VERSION}")"
  [ -n "$CORE_STABLE_VERSION" ] || [ -n "$CORE_ALPHA_VERSION" ]
}

# 下载并安装内核二进制 / Download and install the core binary
core_fetch_binary() {
  local channel="$1" version url tgz
  if [ "$channel" = 'alpha' ]; then
    version="$CORE_ALPHA_VERSION"; url="$CORE_ALPHA_URL"
  else
    version="$CORE_STABLE_VERSION"; url="$CORE_STABLE_URL"
  fi
  if [ -z "$version" ] || [ -z "$url" ]; then
    log_error "$(text kernel_no_version)"; return 1
  fi
  tgz="$TEMP_DIR/sing-box-${version}-linux-${ARCH}.tar.gz"
  log_info "$(text kernel_downloading): ${channel} ${version}"
  if ! download "$url" "$tgz"; then
    log_error "$(text kernel_downloading) ${version}"; return 1
  fi
  mkdir -p "$TEMP_DIR/core"
  tar -xzf "$tgz" -C "$TEMP_DIR/core" 2>/dev/null || { log_error 'extract failed'; return 1; }
  local bin
  bin="$(find "$TEMP_DIR/core" -maxdepth 2 -type f -name 'sing-box' | head -n1)"
  [ -n "$bin" ] || { log_error 'binary not found in archive'; return 1; }
  install -m 0755 "$bin" "$CORE_BIN" || { log_error 'install binary failed'; return 1; }
  printf '%s' "$version"
  return 0
}

# 切换内核通道（保留配置）/ Switch channel, keep the existing config
core_switch() {
  local channel="$1"
  local cur
  cur="$(installed_core_channel)"
  if core_installed && [ "$cur" = "$channel" ]; then
    log_info "$(text kernel_already): $(channel_label "$channel")"
    return 0
  fi
  if ! fetch_core_releases; then
    log_warn "$(text ver_offline)"
  fi
  core_installed && service_stop quiet
  local version
  version="$(core_fetch_binary "$channel")" || return 1
  CORE_CHANNEL="$channel"
  save_state
  write_service_unit
  service_enable quiet
  mkdir -p "$SUBSCRIBE_DIR"
  create_shortcut
  [ -s "$CONFIG_JSON" ] && service_restart quiet
  log_ok "$(text kernel_installed): $(channel_label "$channel") ${version}"
  return 0
}

# 更新当前通道 / Update the currently installed channel only
core_update_current() {
  core_installed || { log_error "$(text svc_not_installed)"; return 1; }
  local channel
  channel="$(installed_core_channel)"
  if ! fetch_core_releases; then
    log_warn "$(text ver_offline)"; return 1
  fi
  core_installed && service_stop quiet
  local version
  version="$(core_fetch_binary "$channel")" || return 1
  CORE_CHANNEL="$channel"
  save_state
  service_start quiet
  log_ok "$(text kernel_updated): $(channel_label "$channel") ${version}"
  return 0
}

# 兼容旧 CLI：--install / --replace
install_core() {
  local channel="${CORE_CHANNEL:-${1:-$CORE_CHANNEL_DEFAULT}}"
  core_switch "$channel"
}

replace_core() {
  core_installed || { log_error "$(text svc_not_installed)"; return 1; }
  local channel="${CORE_CHANNEL:-$(installed_core_channel)}"
  confirm "$(printf "$(text kernel_keep_confirm)" "$(channel_label "$channel")")" || { log_warn "$(text cancelled)"; return 1; }
  CORE_CHANNEL="$channel"
  core_update_current
}

uninstall_core() {
  log_step "$(text svc_stop)"
  core_installed || { log_error "$(text svc_not_installed)"; return 1; }
  service_stop quiet
  service_disable quiet
  rm -f "$CORE_BIN"
  remove_service_unit
  log_ok "$(text done)"
  return 0
}

# 生成 Reality 密钥对 / Generate Reality keypair (requires core)
core_reality_keypair() {
  [ -x "$CORE_BIN" ] || return 1
  local out priv pub
  out="$("$CORE_BIN" generate reality-keypair 2>/dev/null)"
  priv="$(printf '%s\n' "$out" | awk -F': ' '/PrivateKey/{print $2}')"
  pub="$(printf '%s\n' "$out" | awk -F': ' '/PublicKey/{print $2}')"
  [ -n "$priv" ] && [ -n "$pub" ] || return 1
  REALITY_PRIVATE="$priv"
  REALITY_PUBLIC="$pub"
  return 0
}

core_generate_uuid() {
  if [ -x "$CORE_BIN" ]; then
    "$CORE_BIN" generate uuid 2>/dev/null && return 0
  fi
  rand_uuid
}

# 配置校验 / Validate server config with the core
core_config_check() {
  [ -x "$CORE_BIN" ] || return 0
  [ -s "$CONFIG_JSON" ] || return 1
  "$CORE_BIN" check -c "$CONFIG_JSON" >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# 内核管理菜单 / Kernel menu
# ------------------------------------------------------------------------------
kernel_menu() {
  local choice cur ver
  while true; do
    clear 2>/dev/null || true
    ui_panel "$(text kernel_title)"
    if core_installed; then
      cur="$(installed_core_channel)"
      ver="$(local_core_version 2>/dev/null || true)"
      ui_frame_field "$(text kernel_current)" "${ver:-?}  [$(channel_label "$cur")]"
    else
      ui_frame_field "$(text kernel_current)" "$(text kernel_none)"
    fi
    ui_note "$(text kernel_source)"
    printf '\n'
    ui_item 1 "$(text kernel_stable)"
    ui_item 2 "$(text kernel_alpha)"
    ui_item 3 "$(text kernel_update)"
    ui_item 0 "$(text back)"
    printf '%s [0-3]: ' "$(text select_prompt)"
    read -r choice
    case "$choice" in
      1) core_switch stable; save_state; pause_enter ;;
      2) core_switch alpha; save_state; pause_enter ;;
      3) core_update_current; save_state; pause_enter ;;
      0|'') return 0 ;;
      *) log_warn "$(text invalid)" ;;
    esac
  done
}
