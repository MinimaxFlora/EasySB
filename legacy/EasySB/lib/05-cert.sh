# ------------------------------------------------------------------------------
# 五、域名证书管理 / Domain and certificate management (acme.sh standalone)
# ------------------------------------------------------------------------------
# 支持申请多个域名证书、纵向列表查看、切换激活、删除。
# 扫描 ~/.acme.sh 时会包含脚本之外用 acme.sh 申请的证书。
# 申请前检测 80/443 占用，必要时临时停止占用服务。
# ------------------------------------------------------------------------------

CERT_FULLCHAIN=''
CERT_KEYFILE=''

ensure_acme() {
  if [ -x "$ACME_SH" ]; then
    return 0
  fi
  log_info "$(text domain_installing_acme)"
  local email installer="$TEMP_DIR/acme-install.sh"
  email="$(read_default "$(text domain_email)" '')"
  if [ -z "$email" ]; then
    log_error "$(text domain_email_required)"; return 1
  fi
  local ok=''
  if have_cmd curl; then
    curl -fsSL --connect-timeout 10 -o "$installer" 'https://get.acme.sh' 2>/dev/null && ok='1'
  elif have_cmd wget; then
    wget -q --timeout=10 -O "$installer" 'https://get.acme.sh' 2>/dev/null && ok='1'
  fi
  [ -n "$ok" ] || { log_error 'download acme.sh failed'; return 1; }
  sh "$installer" email="$email" >/dev/null 2>&1 || true
  [ -x "$ACME_SH" ] || [ -x "${HOME:-/root}/.acme.sh/acme.sh" ] || { log_error "$(text domain_issue_failed)"; return 1; }
  [ -x "$ACME_SH" ] || ACME_SH="${HOME:-/root}/.acme.sh/acme.sh"
  return 0
}

# 计算证书文件路径 / Resolve cert file paths for a domain
cert_paths() {
  local domain="$1"
  if [ -s "${ACME_DIR}/${domain}_ecc/fullchain.cer" ]; then
    CERT_FULLCHAIN="${ACME_DIR}/${domain}_ecc/fullchain.cer"
    CERT_KEYFILE="${ACME_DIR}/${domain}_ecc/${domain}.key"
    return 0
  fi
  if [ -s "${ACME_DIR}/${domain}/fullchain.cer" ]; then
    CERT_FULLCHAIN="${ACME_DIR}/${domain}/fullchain.cer"
    CERT_KEYFILE="${ACME_DIR}/${domain}/${domain}.key"
    return 0
  fi
  return 1
}

# 收集证书域名（含脚本外申请）/ Collect cert domains found in ACME_DIR
CERT_DOMAINS=()
collect_cert_domains() {
  CERT_DOMAINS=()
  [ -d "$ACME_DIR" ] || return 1
  local dir domain
  for dir in "$ACME_DIR"/*_ecc "$ACME_DIR"/*; do
    [ -d "$dir" ] || continue
    [ -s "$dir/fullchain.cer" ] || continue
    domain="$(basename "$dir")"; domain="${domain%_ecc}"
    [ -n "$domain" ] || continue
    CERT_DOMAINS+=("$domain")
  done
  [ "${#CERT_DOMAINS[@]}" -gt 0 ]
}

# 纵向编号列表 / Vertical numbered list
_print_cert_list() {
  local i d mark
  for i in "${!CERT_DOMAINS[@]}"; do
    d="${CERT_DOMAINS[$i]}"
    if [ "$d" = "$CERT_DOMAIN" ]; then
      mark=" ${C_GREEN}<-- $(text domain_active)${C_RESET}"
    else
      mark=''
    fi
    printf '   %b%d)%b %s%b\n' "$C_GREEN" "$((i+1))" "$C_RESET" "$d" "$mark"
  done
}

# 让用户选择一个证书域名 / Let the user pick one cert domain
select_cert_domain() {
  local out_var="$1" choice
  collect_cert_domains || { log_warn "$(text domain_empty)"; return 1; }
  printf '\n'
  _print_cert_list
  printf '\n%s [1-%d]: ' "$(text domain_select)" "${#CERT_DOMAINS[@]}"
  read -r choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#CERT_DOMAINS[@]}" ]; then
    log_warn "$(text invalid)"; return 1
  fi
  eval "$out_var='${CERT_DOMAINS[$((choice-1))]}'"
  return 0
}

list_certs() {
  if ! collect_cert_domains; then
    log_warn "$(text domain_empty)"; return 1
  fi
  printf '\n'
  _print_cert_list
}

# 临时释放 80/443 / Temporarily free ports 80 and 443
FREE_SING_BOX=''
FREE_NGINX=''
FREE_UNKNOWN=''
free_acme_ports() {
  FREE_SING_BOX=''; FREE_NGINX=''; FREE_UNKNOWN=''
  local port owner
  for port in 80 443; do
    port_in_use "$port" || continue
    owner="$(port_owners "$port")"
    log_warn "$(text domain_port_busy): ${port} (${owner:-unknown})"
    case "$owner" in
      *sing-box*) FREE_SING_BOX='1' ;;
      *nginx*)    FREE_NGINX='1' ;;
      '')         FREE_UNKNOWN='1' ;;
      *)          FREE_UNKNOWN='1' ;;
    esac
  done
  if [ -n "$FREE_UNKNOWN" ] && [ -z "$FREE_SING_BOX" ] && [ -z "$FREE_NGINX" ]; then
    confirm "$(text domain_stop_confirm)" || return 1
  elif [ -n "$FREE_SING_BOX" ] || [ -n "$FREE_NGINX" ]; then
    confirm "$(text domain_stop_confirm)" || return 1
    [ -n "$FREE_SING_BOX" ] && service_stop quiet
    [ -n "$FREE_NGINX" ] && service_nginx stop
    sleep 1
  fi
  return 0
}

restore_acme_services() {
  [ -n "$FREE_NGINX" ] && service_nginx start
  [ -n "$FREE_SING_BOX" ] && service_start quiet
}

# 激活证书后立即应用到节点配置 / Apply the active cert to the node config
apply_active_cert() {
  [ -x "$CORE_BIN" ] || return 0
  [ -s "$CONFIG_JSON" ] || return 0
  build_server_config
  service_restart quiet
  log_ok "$(text domain_applied)"
}

issue_cert() {
  log_step "$(text domain_issue)"
  ensure_acme || return 1
  local domain ip
  domain="$(read_default "$(text domain_prompt)" '')"
  [ -z "$domain" ] && { log_warn "$(text cancelled)"; return 1; }
  ip="${SERVER_IP:-$(detect_server_ip)}"
  if [ -n "$ip" ] && ! domain_points_here "$domain" "$ip"; then
    log_warn "$(text domain_not_resolves)"
    confirm "$(text domain_not_resolves)" || return 1
  else
    log_ok "$(text domain_resolves)"
  fi
  free_acme_ports || { log_warn "$(text cancelled)"; return 1; }
  log_info "$(text domain_issuing): ${domain}"
  # --force 覆盖已有域名密钥，保证重复申请 / 续期不会因旧密钥失败
  # --force overwrites an existing domain key so re-issue/renew always works
  "$ACME_SH" --issue --standalone -d "$domain" --keylength ec-256 --force >/dev/null 2>&1
  local rc=$?
  restore_acme_services
  if [ "$rc" -ne 0 ] || ! cert_paths "$domain"; then
    log_error "$(text domain_issue_failed)"; return 1
  fi
  DOMAIN="$domain"
  CERT_DOMAIN="$domain"
  save_state
  log_ok "$(text domain_issued): ${domain}"
  apply_active_cert
  return 0
}

switch_cert() {
  log_step "$(text domain_switch)"
  local domain
  select_cert_domain domain || return 1
  CERT_DOMAIN="$domain"
  DOMAIN="$domain"
  save_state
  log_ok "$(text domain_switched): ${CERT_DOMAIN}"
  apply_active_cert
  return 0
}

remove_cert() {
  log_step "$(text domain_remove)"
  local domain
  select_cert_domain domain || return 1
  confirm "$(printf "$(text domain_remove_confirm)" "$domain")" N || { log_warn "$(text cancelled)"; return 1; }
  if [ -x "$ACME_SH" ]; then
    "$ACME_SH" --remove -d "$domain" --ecc >/dev/null 2>&1 || true
  fi
  if [ "$CERT_DOMAIN" = "$domain" ]; then
    CERT_DOMAIN=''
    [ "$DOMAIN" = "$domain" ] && DOMAIN=''
    save_state
  fi
  log_ok "$(text domain_removed): ${domain}"
  return 0
}

domain_menu() {
  local choice
  while true; do
    clear 2>/dev/null || true
    ui_panel "$(text domain_title)"
    if [ -n "$CERT_DOMAIN" ]; then
      ui_frame_field "$(text domain_active)" "$CERT_DOMAIN"
    else
      ui_frame_field "$(text domain_active)" "$(text not_set)"
    fi
    printf '\n'
    ui_item 1 "$(text domain_issue)"
    ui_item 2 "$(text domain_list)"
    ui_item 3 "$(text domain_switch)"
    ui_item 4 "$(text domain_remove)"
    ui_item 0 "$(text back)"
    printf '%s [0-4]: ' "$(text select_prompt)"
    read -r choice
    case "$choice" in
      1) issue_cert; pause_enter ;;
      2) list_certs; pause_enter ;;
      3) switch_cert; pause_enter ;;
      4) remove_cert; pause_enter ;;
      0|'') return 0 ;;
      *) log_warn "$(text invalid)" ;;
    esac
  done
}

# 兼容旧名 / Backward-compatible alias
certificate_menu() { domain_menu; }
