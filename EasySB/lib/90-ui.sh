#!/usr/bin/env bash
# =============================================================================
# EasySB — 90-ui.sh
# 交互层：主菜单 / 部署向导 / 证书管理 / 伪装站点 / 更新 / 客户端 / 状态 / 卸载
# 依赖：全部模块
# =============================================================================
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# 主菜单
# ---------------------------------------------------------------------------
ui_main() {
  local _ui_main_choice=""
  while :; do
    ui_title "EasySB · sing-box 一键部署管理面板 v${ESB_SCRIPT_VERSION}"
    sb_status_line
    ui_blank
    printf '  1) 一键部署 / 修改部署\n'
    printf '  2) 运行状态\n'
    printf '  3) 服务管理（启动 / 停止 / 重启 / 日志）\n'
    printf '  4) 证书管理（申请 / 列表 / 应用 / 删除）\n'
    printf '  5) 伪装站点\n'
    printf '  6) 客户端配置与分享链接\n'
    printf '  7) 更新（sing-box 内核 / EasySB 脚本）\n'
    printf '  8) 卸载 EasySB\n'
    printf '  0) 退出\n'
    ui_blank
    printf '请选择 [0-9]: '
    IFS= read -r _ui_main_choice || _ui_main_choice="0"
    _ui_main_choice="${_ui_main_choice%$'\r'}"
    case "$_ui_main_choice" in
      1) ui_deploy_wizard ;;
      2) ui_status_menu ;;
      3) ui_service_menu ;;
      4) ui_cert_menu ;;
      5) ui_web_menu ;;
      6) ui_clients_menu ;;
      7) ui_update_menu ;;
      8) ui_uninstall ;;
      0|q|Q|exit|quit) log_info "已退出"; return 0 ;;
      '') ;;
      *) log_warn "无效的选项：$_ui_main_choice" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
ui_status_menu() {
  ui_title "运行状态"
  sb_status_line
  ui_blank
  if [ -f "$ESB_STATE" ]; then
    render_summary
  else
    log_warn "尚未部署（找不到 $ESB_STATE）"
  fi
  ui_blank
  printf '  配置文件   : %s\n' "$ESB_CONFIG"
  printf '  客户端配置 : %s\n' "$ESB_CLIENT_DIR"
  printf '  日志文件   : %s\n' "$ESB_LOG"
  if [ -f "$ESB_DIR/capabilities.json" ]; then
    printf '  能力探测   : %s\n' "$(jq -c . "$ESB_DIR/capabilities.json" 2>/dev/null | head -c 200)"
  fi
  ui_blank
  fw_status 2>/dev/null || true
  if [ -f "$ESB_WEB_ROOT/index.html" ]; then
    ui_blank
    web_status 2>/dev/null || true
  fi
  pause
  return 0
}

ui_service_menu() {
  local _ui_service_choice=""
  while :; do
    ui_title "服务管理"
    sb_status_line
    ui_blank
    printf '  1) 启动　2) 停止　3) 重启　4) 重载配置　5) 查看实时日志　0) 返回\n'
    printf '请选择: '
    IFS= read -r _ui_service_choice || _ui_service_choice="0"
    _ui_service_choice="${_ui_service_choice%$'\r'}"
    case "$_ui_service_choice" in
      1) sb_service start && log_ok "已启动" ;;
      2) sb_service stop && log_ok "已停止" ;;
      3) sb_service restart && log_ok "已重启" ;;
      4) sb_service reload && log_ok "已重载" ;;
      5)
        log_info "按 Ctrl+C 退出日志查看"
        if [ "${ESB_INIT:-systemd}" = "systemd" ]; then
          journalctl -u sing-box -n 60 -f
        elif [ -f "$ESB_LOG" ]; then
          tail -n 60 -f "$ESB_LOG"
        else
          log_warn "没有可用的日志来源"
        fi
        ;;
      0|'') return 0 ;;
      *) log_warn "无效选项" ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# 部署向导
# ---------------------------------------------------------------------------
ui_prompt_domain() {
  local _ui_prompt_domain_val="" _ui_prompt_domain_cur _ui_prompt_domain_rc _ui_prompt_domain_try=0
  _ui_prompt_domain_cur="$(state_get .domain)"
  while :; do
    _ui_prompt_domain_try=$((_ui_prompt_domain_try + 1))
    if [ "$_ui_prompt_domain_try" -gt 5 ] || esb_input_exhausted; then
      error "未获得有效域名（stdin 已结束或连续输入无效），已中止"
      return 1
    fi
    ask_input _ui_prompt_domain_val "请输入部署域名（必填，需已解析到本机）" "$_ui_prompt_domain_cur"
    if ! validate_domain "$_ui_prompt_domain_val"; then continue; fi
    domain_resolves_to "$_ui_prompt_domain_val"
    _ui_prompt_domain_rc=$?
    case "$_ui_prompt_domain_rc" in
      0) log_ok "域名解析正常（指向本机）" ;;
      1) log_warn "该域名解析到别的 IP，证书申请将失败，请确认解析已指向本机 $(detect_local_ips)"
         ask_yesno "仍要使用该域名继续吗？" n || continue ;;
      2) log_warn "域名当前无法解析（可能还没生效），建议先完成解析"
         ask_yesno "忽略并继续吗？" n || continue ;;
      3) log_warn "本机缺少 DNS 查询工具，跳过域名解析检查" ;;
    esac
    state_set_str ".domain" "$_ui_prompt_domain_val" || return 1
    return 0
  done
}

ui_prompt_email() {
  local _ui_prompt_email_val="" _ui_prompt_email_cur
  _ui_prompt_email_cur="$(state_get .email)"
  while :; do
    ask_input _ui_prompt_email_val "请输入 ACME 证书申请邮箱（用于到期提醒）" "$_ui_prompt_email_cur"
    if validate_email "$_ui_prompt_email_val"; then
      state_set_str ".email" "$_ui_prompt_email_val" || return 1
      return 0
    fi
    ask_yesno "邮箱格式看起来不对，仍然使用吗？" n || continue
    state_set_str ".email" "$_ui_prompt_email_val" || return 1
    return 0
  done
}

ui_prompt_protocols() {
  local _ui_prompt_protocols_sel="" _ui_prompt_protocols_k
  local -a _ui_prompt_protocols_items=()
  # 必须用数组传参：协议标签里带空格，拼成字符串再展开会被词分割成乱码菜单
  for _ui_prompt_protocols_k in $(esb_proto_keys); do
    _ui_prompt_protocols_items+=("${_ui_prompt_protocols_k}|$(proto_label "$_ui_prompt_protocols_k" | tr -d '\n')|on")
  done
  ask_multi _ui_prompt_protocols_sel "请选择要部署的协议（默认全部五个）" "${_ui_prompt_protocols_items[@]}"
  if [ -z "$(trim "$_ui_prompt_protocols_sel")" ]; then
    log_warn "没有选择任何协议"
    return 1
  fi
  local _ui_prompt_protocols_p
  for _ui_prompt_protocols_p in $(esb_proto_keys); do
    case " $_ui_prompt_protocols_sel " in
      *" $_ui_prompt_protocols_p "*) state_proto_set_field "$_ui_prompt_protocols_p" ".enabled" "true" || return 1 ;;
      *) state_proto_set_field "$_ui_prompt_protocols_p" ".enabled" "false" || return 1 ;;
    esac
  done
  log_ok "已选择：$(proto_enabled_list)"
  return 0
}

# 端口冲突检查（本工具内部 + 系统占用）
ui_check_ports() {
  local _ui_check_ports_p _ui_check_ports_port _ui_check_ports_proto _ui_check_ports_seen="" _ui_check_ports_bad=0
  for _ui_check_ports_p in $(proto_enabled_list); do
    _ui_check_ports_port="$(proto_port "$_ui_check_ports_p")"
    case "$_ui_check_ports_p" in
      hysteria2|tuic) _ui_check_ports_proto="udp" ;;
      *) _ui_check_ports_proto="tcp" ;;
    esac
    case "$_ui_check_ports_seen" in
      *"$_ui_check_ports_proto/$_ui_check_ports_port"*)
        log_warn "端口冲突：${_ui_check_ports_proto}/${_ui_check_ports_port} 被多个协议使用"
        _ui_check_ports_bad=1
        ;;
    esac
    _ui_check_ports_seen="$_ui_check_ports_seen $_ui_check_ports_proto/$_ui_check_ports_port"
    if port_in_use "$_ui_check_ports_port" "$_ui_check_ports_proto" && [ ! -x "$ESB_BIN" ]; then
      log_warn "${_ui_check_ports_proto}/${_ui_check_ports_port} 已被系统上的其它程序占用（${_ui_check_ports_p}）"
      _ui_check_ports_bad=1
    fi
  done
  return "$_ui_check_ports_bad"
}

ui_prompt_ports() {
  local _ui_prompt_ports_ans="" _ui_prompt_ports_p _ui_prompt_ports_val
  ui_blank
  printf '  默认端口组合（互不冲突）：\n'
  for _ui_prompt_ports_p in $(proto_enabled_list); do
    printf '      %-22s %s/%s\n' "$_ui_prompt_ports_p" \
      "$(case "$_ui_prompt_ports_p" in hysteria2|tuic) echo UDP ;; *) echo TCP ;; esac)" "$(proto_port "$_ui_prompt_ports_p")"
  done
  if ask_yesno "是否修改端口？" n; then
    for _ui_prompt_ports_p in $(proto_enabled_list); do
      while :; do
        ask_input _ui_prompt_ports_val "  ${_ui_prompt_ports_p} 端口" "$(proto_port "$_ui_prompt_ports_p")"
        if validate_port "$_ui_prompt_ports_val"; then
          state_proto_set_field "$_ui_prompt_ports_p" ".port" "$_ui_prompt_ports_val" || return 1
          break
        fi
      done
    done
    ask_input _ui_prompt_ports_ans "是否修改端口跳跃范围（当前 $(state_get '.protocols.hysteria2.hop.range')）？留空保持不变" ""
    if [ -n "$_ui_prompt_ports_ans" ] && validate_port_range "$_ui_prompt_ports_ans" >/dev/null; then
      local _ui_prompt_ports_range
      _ui_prompt_ports_range="$(validate_port_range "$_ui_prompt_ports_ans")"
      state_set_str ".protocols.hysteria2.hop.range" "$_ui_prompt_ports_range"
    fi
  fi
  if proto_enabled hysteria2; then
    if ask_yesno "是否为 Hysteria2 启用端口跳跃（服务端 DNAT 重定向，抗封锁更强）？" y; then
      state_proto_set_field hysteria2 ".hop.enabled" "true" || return 1
      local _ui_prompt_ports_hop
      ask_input _ui_prompt_ports_hop "  端口跳跃范围" "$(state_get '.protocols.hysteria2.hop.range')"
      if validate_port_range "$_ui_prompt_ports_hop" >/dev/null 2>&1; then
        state_set_str ".protocols.hysteria2.hop.range" "$(validate_port_range "$_ui_prompt_ports_hop")" || return 1
      else
        log_warn "范围格式不正确，保持默认 $(state_get '.protocols.hysteria2.hop.range')"
      fi
    else
      state_proto_set_field hysteria2 ".hop.enabled" "false" || return 1
    fi
  fi
  return 0
}

# 生成密钥（已有则保留）
ui_gen_secrets() {
  log_info "生成 / 校验节点密钥…"
  local _ui_gen_secrets_key _ui_gen_secrets_val _ui_gen_secrets_kp
  for _ui_gen_secrets_key in vless_uuid vmess_uuid tuic_uuid tuic_password hysteria2_password anytls_password; do
    _ui_gen_secrets_val="$(secret_get "$_ui_gen_secrets_key")"
    if [ -z "$_ui_gen_secrets_val" ]; then
      case "$_ui_gen_secrets_key" in
        *_uuid) _ui_gen_secrets_val="$(gen_uuid)" ;;
        *)      _ui_gen_secrets_val="$(gen_secret 16)" ;;
      esac
      secret_set "$_ui_gen_secrets_key" "$_ui_gen_secrets_val" || return 1
      log_debug "已生成 $_ui_gen_secrets_key：$(mask_secret "$_ui_gen_secrets_val")"
    fi
  done
  if [ -z "$(state_get .reality.private_key)" ]; then
    _ui_gen_secrets_kp="$(reality_keypair)" || return 1
    state_set_str ".reality.private_key" "${_ui_gen_secrets_kp%% *}" || return 1
    state_set_str ".reality.public_key" "${_ui_gen_secrets_kp##* }" || return 1
    state_set_str ".reality.short_id" "$(gen_hex 4)" || return 1
    log_debug "已生成 REALITY 密钥对"
  fi
  state_set_str ".reality.server_name" "$(state_get .reality.handshake_server)" >/dev/null 2>&1 || true
  return 0
}

ui_install_kernel() {
  local _ui_install_kernel_ver="${1:-latest}"
  if sb_installed; then
    log_ok "已安装 sing-box v$(sb_version)"
    if ! ask_yesno "是否重新安装/切换版本？" n; then return 0; fi
    ask_input _ui_install_kernel_ver "输入版本号（留空=最新）" "latest"
  fi
  sb_install "${_ui_install_kernel_ver:-latest}" || return 1
  return 0
}

# 证书准备（部署过程中调用）
# 让用户选择证书来源：申请 Let's Encrypt 域名证书（推荐）或生成自签证书（无需域名解析）
ui_prepare_cert() {
  local _ui_prepare_cert_need=0 _ui_prepare_cert_p
  for _ui_prepare_cert_p in $(proto_enabled_list); do
    if proto_needs_cert "$_ui_prepare_cert_p"; then _ui_prepare_cert_need=1; break; fi
  done
  [ "$_ui_prepare_cert_need" = "1" ] || { log_info "所选协议均无需证书（REALITY 免证书）"; return 0; }

  local _ui_prepare_cert_domain; _ui_prepare_cert_domain="$(state_get .domain)"
  if [ "$(state_get .cert.domain)" = "$_ui_prepare_cert_domain" ] && render_cert_ready; then
    log_ok "已有可用证书：$(state_get .cert.crt)（来源：$(state_get .cert.source)）"
    log_info "如需换一种证书来源，可在菜单【证书管理】里重新申请或生成自签证书"
    return 0
  fi
  if render_cert_ready; then
    log_info "当前已应用证书域名：$(state_get .cert.domain)（与部署域名 $_ui_prepare_cert_domain 不一致）"
  fi

  # --- 选择证书来源 -------------------------------------------------------
  local _ui_prepare_cert_source=""
  ui_blank
  log_info "需要为 $_ui_prepare_cert_domain 准备证书（用于 VMess-WS-TLS / Hysteria2 / TUIC / AnyTLS）"
  ask_single _ui_prepare_cert_source "请选择证书来源" \
    "acme|申请域名证书（Let's Encrypt，浏览器与客户端都认可，需域名已解析到本机）" \
    "self-signed|生成自签证书（不需要域名解析，客户端必须跳过证书校验）"

  if [ "$_ui_prepare_cert_source" = "self-signed" ]; then
    log_info "生成自签证书（有效期 3650 天，仅用于加密通道，客户端将自动配置为跳过校验）"
    cert_self_signed "$_ui_prepare_cert_domain" || { error "生成自签证书失败"; return 1; }
    cert_use "$_ui_prepare_cert_domain" >/dev/null 2>&1 || { error "应用自签证书失败"; return 1; }
    log_ok "已应用自签证书：$(state_get .cert.crt)"
    log_info "提示：分享链接与订阅里已写入 insecure=1 / skip-cert-verify，客户端无需手工设置"
    return 0
  fi

  # --- ACME ---------------------------------------------------------------
  if ! cert_tool_installed; then
    log_warn "尚未安装证书申请工具 acme.sh"
    ask_yesno "现在安装 acme.sh 吗？" y || { error "没有证书无法部署需要证书的协议"; return 1; }
    cert_tool_install || return 1
  fi

  local _ui_prepare_cert_mode=""
  if [ "$(state_get .web.enabled)" = "true" ]; then
    log_info "已开启伪装站点，推荐使用 webroot 方式申请证书（不影响 80 端口服务）"
    ask_single _ui_prepare_cert_mode "请选择证书申请方式" \
      "webroot|Webroot（借用伪装站点的 80 端口）" \
      "standalone|Standalone（临时占用 80 端口）" \
      "dns|DNS API（无需 80 端口，适合已占用 80 的情况）"
  else
    ask_single _ui_prepare_cert_mode "请选择证书申请方式" \
      "standalone|Standalone（临时占用 80 端口）" \
      "webroot|Webroot（自己指定网站根目录）" \
      "dns|DNS API（无需 80 端口）"
  fi
  local _ui_prepare_cert_arg="$_ui_prepare_cert_mode"
  if [ "$_ui_prepare_cert_mode" = "dns" ]; then
    local _ui_prepare_cert_prov
    local -a _ui_prepare_cert_prov_items=()
    while IFS="|" read -r _k _v; do
      [ -n "$_k" ] && _ui_prepare_cert_prov_items+=("${_k}|${_v}")
    done <<EOF
$(dns_provider_list)
EOF
    ask_single _ui_prepare_cert_prov "请选择 DNS 服务商" "${_ui_prepare_cert_prov_items[@]}"
    _ui_prepare_cert_arg="dns:$_ui_prepare_cert_prov"
    ui_dns_env_tip "$_ui_prepare_cert_prov"
  fi
  if ! cert_apply "$_ui_prepare_cert_domain" "$_ui_prepare_cert_arg"; then
    log_warn "域名证书申请失败（常见原因：域名未解析到本机 / 80 端口不可达 / 触发 CA 频率限制）"
    if ask_yesno "改用自签证书继续部署吗？" y; then
      cert_self_signed "$_ui_prepare_cert_domain" || { error "生成自签证书失败"; return 1; }
      cert_use "$_ui_prepare_cert_domain" >/dev/null 2>&1 || { error "应用自签证书失败"; return 1; }
      log_ok "已应用自签证书（客户端将自动跳过证书校验）"
      return 0
    fi
    return 1
  fi
  cert_use "$_ui_prepare_cert_domain" >/dev/null 2>&1 || true
  return 0
}

ui_dns_env_tip() {
  local _ui_dns_env_tip_prov="$1" _ui_dns_env_tip_file="$ESB_SECRET_DIR/dns.env"
  ui_blank
  log_info "DNS API 凭据文件：$_ui_dns_env_tip_file（权限 600，每行 KEY=value）"
  case "$_ui_dns_env_tip_prov" in
    dns_cf) printf '  例如：CF_Token=你的Cloudflare_API_Token\n' ;;
    dns_dp) printf '  例如：DP_Id=你的DNSPod_ID\\nDP_Key=你的DNSPod_Key\n' ;;
    dns_ali) printf '  例如：Ali_Key=你的AccessKeyId\\nAli_Secret=你的AccessKeySecret\n' ;;
    dns_gd) printf '  例如：GD_Key=你的GoDaddy_Key\\nGD_Secret=你的GoDaddy_Secret\n' ;;
    dns_huaweicloud) printf '  例如：HUAWEICLOUD_Username=账号\\nHUAWEICLOUD_Password=密码\\nHUAWEICLOUD_ProjectID=项目ID\n' ;;
  esac
  if [ ! -f "$_ui_dns_env_tip_file" ]; then
    log_warn "凭据文件还不存在，请先创建并填入凭据（方式：菜单【证书管理】外的 shell 里手动创建，或现在输入）"
    if ask_yesno "现在输入凭据（写入 600 文件）？" n; then
      local _ui_dns_env_tip_line=""
      printf '请输入 KEY=value（可多行，直接回车结束）：\n'
      : >"$_ui_dns_env_tip_file"
      chmod 600 "$_ui_dns_env_tip_file" 2>/dev/null || true
      while :; do
        IFS= read -r _ui_dns_env_tip_line || break
        _ui_dns_env_tip_line="${_ui_dns_env_tip_line%$'\r'}"
        [ -n "$_ui_dns_env_tip_line" ] || break
        printf '%s\n' "$_ui_dns_env_tip_line" >>"$_ui_dns_env_tip_file"
      done
      log_ok "凭据已保存到 $_ui_dns_env_tip_file"
    fi
  fi
  return 0
}

ui_deploy_wizard() {
  ui_title "EasySB 一键部署向导"
  detect_all
  printf '  系统：%s　架构：%s　包管理器：%s　服务管理：%s\n' "$ESB_OS_PRETTY" "$ESB_ARCH" "$ESB_PKG" "$ESB_INIT"
  ESB_PUBLIC_IP="${ESB_PUBLIC_IP:-$(detect_public_ip)}"
  [ -n "$ESB_PUBLIC_IP" ] && state_set_str ".server_ip" "$ESB_PUBLIC_IP" >/dev/null 2>&1
  printf '  本机 IP：%s　公网 IP：%s\n' "$(detect_local_ips)" "${ESB_PUBLIC_IP:-未知}"

  if ! deps_check; then
    log_err "依赖不满足，无法继续"
    pause
    return 1
  fi

  ui_step "第一步：域名与邮箱（强制域名部署）"
  ui_prompt_domain || return 1
  ui_prompt_email || return 1

  ui_step "第二步：选择协议"
  ui_prompt_protocols || return 1
  ui_prompt_ports || return 1

  ui_step "第三步：伪装站点"
  local _ui_deploy_wizard_web_sel="" _ui_deploy_wizard_web_tpl=""
  if ask_yesno "是否部署伪装站点（推荐，配合证书申请与域名访问更自然）？" y; then
    web_templates >"${ESB_TMP}/web_templates.tsv" 2>/dev/null || true
    local -a _ui_deploy_wizard_items=()
    while IFS="$(printf '\t')" read -r _ui_deploy_wizard_k _ui_deploy_wizard_l; do
      [ -n "$_ui_deploy_wizard_k" ] || continue
      _ui_deploy_wizard_items+=("${_ui_deploy_wizard_k}|${_ui_deploy_wizard_l}")
    done <"${ESB_TMP}/web_templates.tsv"
    if [ "${#_ui_deploy_wizard_items[@]}" -gt 0 ]; then
      ask_single _ui_deploy_wizard_web_tpl "请选择伪装站点模板" "${_ui_deploy_wizard_items[@]}"
    else
      _ui_deploy_wizard_web_tpl="blog"
    fi
    if [ "$_ui_deploy_wizard_web_tpl" = "proxy" ]; then
      ask_input _ui_deploy_wizard_web_sel "请输入要反代的真实站点（如 https://www.example.org）" "$(state_get .web.proxy_target)"
      state_set_str ".web.proxy_target" "$_ui_deploy_wizard_web_sel"
    fi
    state_set ".web.enabled" "true"
    state_set_str ".web.template" "$_ui_deploy_wizard_web_tpl"
    local _ui_deploy_wizard_webcert="n"
    if ask_yesno "是否为伪装站点启用 HTTPS（443，需要证书且端口未被协议占用）？" y; then
      state_set ".web.tls" "true"
    else
      state_set ".web.tls" "false"
    fi
    _ui_deploy_wizard_webcert=""
  else
    state_set ".web.enabled" "false"
  fi

  ui_step "第四步：安装 sing-box 内核（来自本仓库 releases）"
  ui_install_kernel latest || { log_err "内核安装失败，已中止部署"; pause; return 1; }
  probe_capabilities >/dev/null 2>&1 || log_warn "能力探测未完成（不影响使用）"

  ui_step "第五步：生成节点密钥"
  ui_gen_secrets || { log_err "密钥生成失败"; pause; return 1; }

  ui_step "第六步：证书"
  if [ "$(state_get .web.enabled)" = "true" ]; then
    web_install || log_warn "nginx 安装失败，伪装站点与 webroot 证书申请可能不可用"
    web_deploy "$(state_get .web.template)" || log_warn "伪装站点部署失败，可稍后在菜单中重试"
  fi
  ui_prepare_cert || { log_err "证书准备失败，无法完成需要证书的协议部署"; pause; return 1; }

  ui_step "第七步：生成配置并启动服务"
  local _ui_deploy_wizard_backup
  _ui_deploy_wizard_backup="$(esb_backup "deploy")" || true
  render_config || { log_err "配置生成失败，已中止"; pause; return 1; }
  if ! sb_check_config "$ESB_CONFIG"; then
    log_err "配置校验未通过，已中止部署（原配置未被破坏）"
    pause
    return 1
  fi
  ui_check_ports || log_warn "存在端口冲突或占用，请确认后再启动服务"
  if [ "$(state_get .web.enabled)" = "true" ] && [ "$(state_get .web.tls)" = "true" ]; then
    web_apply_cert || log_warn "伪装站点 HTTPS 未启用（原因见上），站点仍可通过 80 端口访问"
  fi
  fw_apply_all || log_warn "防火墙规则同步失败，请检查防火墙状态"
  state_set_str ".installed_at" "$(esb_now)" >/dev/null 2>&1
  state_set_str ".script_version" "$ESB_SCRIPT_VERSION" >/dev/null 2>&1
  sb_service enable >/dev/null 2>&1 || true
  if ! sb_service restart; then
    log_err "服务启动失败：请查看日志（journalctl -u sing-box -n 50），修复后可在【服务管理】里重启"
    log_info "配置与客户端产物不受影响，继续生成客户端配置与订阅"
  else
    sleep 1
    if sb_running; then
      log_ok "sing-box 已启动"
    else
      log_warn "服务未处于运行状态，请查看日志排查"
    fi
  fi

  ui_step "第八步：生成客户端配置与订阅"
  render_clients || log_warn "客户端配置生成失败"
  cert_reloadcmd_setup >/dev/null 2>&1 || true
  if ask_yesno "是否同时启用订阅（一个链接导入全部节点，自动跟随配置变化）？" y; then
    if sub_enable; then
      ui_blank
      printf '%s订阅地址：%s%s\n' "$C_BOLD" "$(sub_url)" "$C_RESET"
      printf '%s（在客户端里粘贴即可；也可用下面的二维码直接扫）%s\n' "$C_DIM" "$C_RESET"
      ui_show_qr "$(sub_url)" >/dev/null 2>&1 || log_info "（未安装 qrencode，跳过二维码）"
    fi
  fi

  ui_blank
  ui_title "部署完成"
  render_summary
  ui_blank
  log_info "客户端配置目录：$ESB_CLIENT_DIR"
  ui_show_links
  pause
  return 0
}

# ---------------------------------------------------------------------------
# 证书管理
# ---------------------------------------------------------------------------
ui_cert_menu() {
  local _ui_cert_menu_choice=""
  while :; do
    ui_title "证书管理"
    local _ui_cert_menu_applied_domain; _ui_cert_menu_applied_domain="$(state_get .cert.domain)"
    printf '  当前已应用证书：%s\n' "${_ui_cert_menu_applied_domain:-无}"
    if [ -n "$_ui_cert_menu_applied_domain" ]; then
      printf '  证书来源　　　：%s\n' "$(state_get .cert.source)"
      printf '  剩余有效期　　：%s 天\n' "$(cert_expiring_days "$_ui_cert_menu_applied_domain")"
    fi
    ui_blank
    printf '  1) 申请域名证书（Let'"'"'s Encrypt）\n'
    printf '  2) 生成自签证书\n'
    printf '  9) 配置证书模式（按协议切换）\n'
    printf '  3) 证书列表\n'
    printf '  4) 应用证书到 sing-box\n'
    printf '  5) 删除证书\n'
    printf '  6) 续期（全部）\n'
    printf '  7) 查看证书详情\n'
    printf '  8) 续期后自动重载服务\n'
    printf '  0) 返回\n'
    printf '请选择 [0-8]: '
    IFS= read -r _ui_cert_menu_choice || _ui_cert_menu_choice="0"
    _ui_cert_menu_choice="${_ui_cert_menu_choice%$'\r'}"
    case "$_ui_cert_menu_choice" in
      1) ui_cert_apply_flow ;;
      2) ui_cert_self_signed_flow ;;
      9) ui_cert_mode_menu ;;
      3) ui_cert_list_flow ;;
      4) ui_cert_use_flow ;;
      5) ui_cert_delete_flow ;;
      6) ui_cert_renew_flow ;;
      7) ui_cert_detail_flow ;;
      8) cert_reloadcmd_setup && log_ok "已设置续期后自动重载" ;;
      0|'') return 0 ;;
      *) log_warn "无效选项" ;;
    esac
    pause
  done
}

# 菜单入口：生成自签证书（可选立即应用）
# ---------------------------------------------------------------------------
# 证书模式配置：按协议逐个查看/切换（REALITY 换握手域名；VMess 可开关 TLS；
# Hysteria2 / TUIC / AnyTLS 可在自签证书与域名证书之间切换）
# ---------------------------------------------------------------------------
ui_cert_mode_label() {
  local _ucml_p="$1" _ucml_mode
  _ucml_mode="$(proto_cert_mode "$_ucml_p")"
  case "$_ucml_p" in
    vless-vision-reality)
      printf 'VLESS-Vision-REALITY 协议：REALITY 握手域名 %s（免证书，不支持证书域名）' \
        "$(state_get .reality.server_name)"
      ;;
    vmess-ws-tls)
      if [ "$(proto_tls_enabled vmess-ws-tls)" != "true" ]; then
        printf 'VMess-WS 协议：当前已关闭 TLS（开启 TLS 需选择证书模式）'
      else
        printf '%s 协议：证书模式 %s' "$(vmess_display_name)" "$(_ui_cert_mode_cn "$_ucml_mode")"
      fi
      ;;
    hysteria2) printf 'Hysteria2 协议：证书模式 %s' "$(_ui_cert_mode_cn "$_ucml_mode")" ;;
    tuic)      printf 'TUIC 协议：证书模式 %s' "$(_ui_cert_mode_cn "$_ucml_mode")" ;;
    anytls)    printf 'AnyTLS 协议：证书模式 %s' "$(_ui_cert_mode_cn "$_ucml_mode")" ;;
    *)         printf '%s 协议：证书模式 %s' "$_ucml_p" "$(_ui_cert_mode_cn "$_ucml_mode")" ;;
  esac
  return 0
}

_ui_cert_mode_cn() {
  case "${1-}" in
    self-signed) printf '自签证书（客户端跳过校验）' ;;
    acme)        printf '域名证书（Let'"'"'s Encrypt：%s）' "$(state_get .domain)" ;;
    *)           printf '%s' "${1-未知}" ;;
  esac
  return 0
}

ui_cert_mode_menu() {
  local _ucmm_choice="" _ucmm_p _ucmm_i=0
  local -a _ucmm_items=() _ucmm_protos=()
  for _ucmm_p in $(proto_enabled_list); do
    _ucmm_i=$((_ucmm_i + 1))
    _ucmm_items+=("${_ucmm_i}|$(ui_cert_mode_label "$_ucmm_p")")
    _ucmm_protos+=("$_ucmm_p")
  done
  [ "$_ucmm_i" -gt 0 ] || { log_warn "当前没有已启用的协议"; return 1; }

  ui_title "配置证书模式（按协议）"
  printf '  当前已应用证书：%s（%s）\n' "$(state_get .cert.domain)" "$(state_get .cert.source)"
  ui_blank
  ask_single _ucmm_choice "请选择要切换证书模式的协议" "${_ucmm_items[@]}" "0|返回"
  [ "$_ucmm_choice" = "0" ] && return 0
  case "$_ucmm_choice" in
    vless-vision-reality) ui_cert_mode_reality_flow ;;
    vmess-ws-tls)         ui_cert_mode_vmess_flow ;;
    hysteria2|tuic|anytls) ui_cert_mode_tls_flow "$_ucmm_choice" ;;
    *) : ;;
  esac
  return 0
}

# REALITY：只换握手域名（第三方站点，需要 TLS1.3 + H2），不能用自己的证书域名
ui_cert_mode_reality_flow() {
  local _ucmr_new=""
  ui_blank
  log_info "REALITY 不申请证书：它借用第三方站点的 TLS 握手（如 www.microsoft.com / apple.com）"
  log_info "当前握手域名：$(state_get .reality.server_name):$(state_get .reality.handshake_port)"
  ask_input _ucmr_new "请输入新的 REALITY 握手域名（留空保持不变）" ""
  [ -n "$_ucmr_new" ] || return 0
  validate_domain "$_ucmr_new" || { error "域名格式不正确"; return 1; }
  if [ "$_ucmr_new" = "$(state_get .domain)" ]; then
    error "REALITY 握手域名不能使用自己的证书域名（$(_ucmr_new)）"
    return 1
  fi
  if ! ui_reality_probe "$_ucmr_new"; then
    log_warn "$_ucmr_new 不符合 REALITY 要求（需要 TLS1.3 + HTTP/2，且不重定向）"
    ask_yesno "仍要使用该域名吗？" n || return 0
  fi
  state_set_str ".reality.handshake_server" "$_ucmr_new" || return 1
  state_set_str ".reality.server_name" "$_ucmr_new" || return 1
  apply_change "切换 REALITY 握手域名 -> $_ucmr_new" || return 1
  log_ok "已切换 REALITY 握手域名：$_ucmr_new"
  log_info "记得让客户端重新导入订阅（节点链接已更新）"
  return 0
}

# 探测第三方域名是否适合做 REALITY 握手目标
ui_reality_probe() {
  local _ucrp_d="$1"
  cmd_exists openssl || { log_warn "缺少 openssl，跳过探测"; return 0; }
  local _ucrp_out
  _ucrp_out="$(printf '' | timeout 10 openssl s_client -connect "${_ucrp_d}:443" -servername "$_ucrp_d" \
      -tls1_3 -alpn h2 2>/dev/null | head -30)" || true
  printf '%s' "$_ucrp_out" | grep -q 'TLSv1.3' || return 1
  printf '%s' "$_ucrp_out" | grep -qi 'ALPN protocol: h2' || return 1
  return 0
}

# VMess：开启/关闭 TLS（开启时选证书模式）
ui_cert_mode_vmess_flow() {
  local _ucmv_choice=""
  ui_blank
  if [ "$(proto_tls_enabled vmess-ws-tls)" = "true" ]; then
    log_info "当前：VMess-WS-TLS（TLS 已开启，证书模式 $(_ui_cert_mode_cn "$(proto_cert_mode vmess-ws-tls)")）"
    ask_single _ucmv_choice "请选择要切换到的模式" \
      "tls-acme|开启 TLS，使用域名证书（$(state_get .domain)）" \
      "tls-self|开启 TLS，使用自签证书（客户端跳过校验）" \
      "no-tls|关闭 TLS（纯 VMess-WS，无需证书）" \
      "0|返回"
  else
    log_info "当前：VMess-WS（TLS 已关闭）"
    ask_single _ucmv_choice "请选择要切换到的模式" \
      "tls-acme|开启 TLS，使用域名证书（$(state_get .domain)）" \
      "tls-self|开启 TLS，使用自签证书（客户端跳过校验）" \
      "0|返回"
  fi
  case "$_ucmv_choice" in
    0|"") return 0 ;;
    tls-acme)
      proto_tls_set vmess-ws-tls true || return 1
      proto_cert_mode_set vmess-ws-tls acme || return 1
      cert_files_for_proto vmess-ws-tls >/dev/null || { error "没有可用的域名证书，请先在【证书管理】申请"; return 1; }
      ;;
    tls-self)
      proto_tls_set vmess-ws-tls true || return 1
      proto_cert_mode_set vmess-ws-tls self-signed || return 1
      ;;
    no-tls)
      proto_tls_set vmess-ws-tls false || return 1
      ;;
  esac
  apply_change "切换 VMess-WS 的 TLS 模式 -> $_ucmv_choice" || return 1
  log_ok "已切换：$(ui_cert_mode_label vmess-ws-tls)"
  log_info "记得让客户端重新导入订阅（节点链接与端口参数已更新）"
  return 0
}

# Hysteria2 / TUIC / AnyTLS：自签 <-> 域名证书
ui_cert_mode_tls_flow() {
  local _ucmt_p="$1" _ucmt_choice=""
  ui_blank
  log_info "当前：$(ui_cert_mode_label "$_ucmt_p")"
  ask_single _ucmt_choice "请选择该协议的证书模式" \
    "acme|切换到域名证书（$(state_get .domain)，Let's Encrypt）" \
    "self-signed|切换到自签证书（无需域名解析，客户端跳过校验）" \
    "0|返回"
  case "$_ucmt_choice" in
    0|"") return 0 ;;
    acme)
      proto_cert_mode_set "$_ucmt_p" acme || return 1
      if ! cert_files_for_proto "$_ucmt_p" >/dev/null; then
        proto_cert_mode_set "$_ucmt_p" auto >/dev/null 2>&1 || true
        error "没有可用的域名证书（$_ucmt_p），请先在【证书管理】申请域名证书"
        return 1
      fi
      ;;
    self-signed)
      proto_cert_mode_set "$_ucmt_p" self-signed || return 1
      cert_selfsigned_paths "$(state_get .domain)" >/dev/null || { error "生成自签证书失败"; return 1; }
      ;;
  esac
  apply_change "切换 $_ucmt_p 的证书模式 -> $_ucmt_choice" || return 1
  log_ok "已切换：$(ui_cert_mode_label "$_ucmt_p")"
  log_info "记得让客户端重新导入订阅（链接里的 insecure / skip-cert-verify 已更新）"
  return 0
}

ui_cert_self_signed_flow() {
  local _ui_ss_domain=""
  ask_input _ui_ss_domain "请输入证书域名（自签证书，需与部署域名一致）" "$(state_get .domain)"
  validate_domain "$_ui_ss_domain" || { error "域名格式不正确"; return 1; }
  if [ "$(state_get .cert.domain)" = "$_ui_ss_domain" ] && render_cert_ready; then
    ask_yesno "当前已应用的就是这个域名的证书，仍要重新生成自签证书吗？" n || return 0
  fi
  cert_self_signed "$_ui_ss_domain" || return 1
  if ask_yesno "现在把该自签证书应用到 sing-box（并重启服务）吗？" y; then
    cert_use "$_ui_ss_domain" || return 1
    log_ok "已应用自签证书：$_ui_ss_domain"
    log_info "订阅与分享链接会自动带上 insecure=1 / skip-cert-verify（客户端无需手工设置）"
    apply_change "应用自签证书 $_ui_ss_domain" || return 1
  fi
  return 0
}

ui_cert_apply_flow() {
  local _ui_cert_apply_flow_domain _ui_cert_apply_flow_mode _ui_cert_apply_flow_arg
  ask_input _ui_cert_apply_flow_domain "请输入证书域名" "$(state_get .domain)"
  validate_domain "$_ui_cert_apply_flow_domain" || return 1
  if ! cert_tool_installed; then
    ask_yesno "尚未安装 acme.sh，现在安装？" y || return 1
    cert_tool_install || return 1
  fi
  if [ "$(state_get .web.enabled)" = "true" ]; then
    ask_single _ui_cert_apply_flow_mode "选择申请方式" \
      "webroot|Webroot（借用伪装站点的 80 端口）" \
      "standalone|Standalone（临时占用 80 端口）" \
      "dns|DNS API（无需 80 端口）"
  else
    ask_single _ui_cert_apply_flow_mode "选择申请方式" \
      "standalone|Standalone（临时占用 80 端口）" \
      "webroot|Webroot（网站根目录）" \
      "dns|DNS API（无需 80 端口）"
  fi
  _ui_cert_apply_flow_arg="$_ui_cert_apply_flow_mode"
  if [ "$_ui_cert_apply_flow_mode" = "dns" ]; then
    local _ui_cert_apply_flow_prov
    local -a _ui_cert_apply_flow_prov_items=()
    while IFS="|" read -r _k _v; do
      [ -n "$_k" ] && _ui_cert_apply_flow_prov_items+=("${_k}|${_v}")
    done <<EOF
$(dns_provider_list)
EOF
    ask_single _ui_cert_apply_flow_prov "选择 DNS 服务商" "${_ui_cert_apply_flow_prov_items[@]}"
    _ui_cert_apply_flow_arg="dns:$_ui_cert_apply_flow_prov"
    ui_dns_env_tip "$_ui_cert_apply_flow_prov"
  fi
  cert_apply "$_ui_cert_apply_flow_domain" "$_ui_cert_apply_flow_arg" || return 1
  log_ok "证书申请成功"
  if ask_yesno "是否立即应用到 sing-box？" y; then
    cert_use "$_ui_cert_apply_flow_domain" || log_warn "应用失败，请检查配置校验输出"
  fi
  return 0
}

ui_cert_list_flow() {
  local _ui_cert_list_flow_line
  ui_blank
  printf '  %-28s %-12s %-8s %s\n' "域名" "来源" "剩余天数" "是否已应用"
  ui_hr
  cert_list >"${ESB_TMP}/certs.tsv" 2>/dev/null || true
  if [ ! -s "${ESB_TMP}/certs.tsv" ]; then
    log_info "暂无证书，请先申请"
    return 0
  fi
  while IFS="$(printf '\t')" read -r _ui_cert_list_flow_line _ _ _ui_cert_list_flow_days _ui_cert_list_flow_src _ui_cert_list_flow_applied; do
    [ -n "$_ui_cert_list_flow_line" ] || continue
    printf '  %-28s %-12s %-8s %s\n' "$_ui_cert_list_flow_line" "$_ui_cert_list_flow_src" "$_ui_cert_list_flow_days" \
      "$([ "$_ui_cert_list_flow_applied" = "1" ] && echo '是' || echo '否')"
  done <"${ESB_TMP}/certs.tsv"
  return 0
}

ui_cert_use_flow() {
  local _ui_cert_use_flow_domain="" _ui_cert_use_flow_line
  local -a _ui_cert_use_flow_items=()
  cert_list >"${ESB_TMP}/certs.tsv" 2>/dev/null || true
  if [ ! -s "${ESB_TMP}/certs.tsv" ]; then log_info "暂无证书"; return 0; fi
  while IFS="$(printf '\t')" read -r _ui_cert_use_flow_line _ _ _ui_cert_use_flow_domain _ _; do
    [ -n "$_ui_cert_use_flow_line" ] || continue
    _ui_cert_use_flow_items+=("${_ui_cert_use_flow_line}|${_ui_cert_use_flow_line}（剩余 ${_ui_cert_use_flow_domain:-?} 天）")
  done <"${ESB_TMP}/certs.tsv"
  local _ui_cert_use_flow_pick
  ask_single _ui_cert_use_flow_pick "请选择要应用的证书" "${_ui_cert_use_flow_items[@]}"
  cert_use "$_ui_cert_use_flow_pick" || return 1
  log_ok "已应用证书：$_ui_cert_use_flow_pick"
  return 0
}

ui_cert_delete_flow() {
  local _ui_cert_delete_flow_domain="" _ui_cert_delete_flow_line _ui_cert_delete_flow_pick
  local -a _ui_cert_delete_flow_items=()
  cert_list >"${ESB_TMP}/certs.tsv" 2>/dev/null || true
  if [ ! -s "${ESB_TMP}/certs.tsv" ]; then log_info "暂无证书"; return 0; fi
  while IFS="$(printf '\t')" read -r _ui_cert_delete_flow_line _ _ _ui_cert_delete_flow_domain _ _; do
    [ -n "$_ui_cert_delete_flow_line" ] || continue
    _ui_cert_delete_flow_items+=("${_ui_cert_delete_flow_line}|${_ui_cert_delete_flow_line}（剩余 ${_ui_cert_delete_flow_domain:-?} 天）")
  done <"${ESB_TMP}/certs.tsv"
  ask_single _ui_cert_delete_flow_pick "请选择要删除的证书" "${_ui_cert_delete_flow_items[@]}"
  ui_blank
  if [ "$_ui_cert_delete_flow_pick" = "$(state_get .cert.domain)" ]; then
    log_warn "该证书正在被 sing-box 使用，删除后需要重新申请并应用，否则服务会启动失败"
    ask_yesno "确认强制删除？" n || return 0
    cert_delete "$_ui_cert_delete_flow_pick" --force || return 1
  else
    ask_yesno "确认删除证书 $_ui_cert_delete_flow_pick？" n || return 0
    cert_delete "$_ui_cert_delete_flow_pick" || return 1
  fi
  log_ok "已删除"
  return 0
}

ui_cert_renew_flow() {
  ui_blank
  log_info "开始续期全部证书…"
  cert_renew_all || log_warn "部分证书续期失败，请查看输出"
  return 0
}

ui_cert_detail_flow() {
  local _ui_cert_detail_flow_domain="" _ui_cert_detail_flow_line _ui_cert_detail_flow_pick
  local -a _ui_cert_detail_flow_items=()
  cert_list >"${ESB_TMP}/certs.tsv" 2>/dev/null || true
  if [ ! -s "${ESB_TMP}/certs.tsv" ]; then log_info "暂无证书"; return 0; fi
  while IFS="$(printf '\t')" read -r _ui_cert_detail_flow_line _ _ _ui_cert_detail_flow_domain _ _; do
    [ -n "$_ui_cert_detail_flow_line" ] || continue
    _ui_cert_detail_flow_items+=("${_ui_cert_detail_flow_line}|${_ui_cert_detail_flow_line}")
  done <"${ESB_TMP}/certs.tsv"
  ask_single _ui_cert_detail_flow_pick "请选择证书" "${_ui_cert_detail_flow_items[@]}"
  ui_blank
  cert_detail "$_ui_cert_detail_flow_pick" || log_warn "无法读取证书详情"
  return 0
}

# ---------------------------------------------------------------------------
# 伪装站点
# ---------------------------------------------------------------------------
ui_web_menu() {
  local _ui_web_menu_choice=""
  while :; do
    ui_title "伪装站点"
    web_status 2>/dev/null || log_info "未部署伪装站点"
    ui_blank
    printf '  1) 部署 / 更换模板\n'
    printf '  2) 仅更新证书配置（HTTPS）\n'
    printf '  3) 关闭伪装站点\n'
    printf '  0) 返回\n'
    printf '请选择 [0-3]: '
    IFS= read -r _ui_web_menu_choice || _ui_web_menu_choice="0"
    _ui_web_menu_choice="${_ui_web_menu_choice%$'\r'}"
    case "$_ui_web_menu_choice" in
      1)
        if ! web_installed; then
          ask_yesno "未安装 nginx，现在安装？" y || return 0
          web_install || return 1
        fi
        local _ui_web_menu_line _ui_web_menu_label _ui_web_menu_tpl
        local -a _ui_web_menu_items=()
        web_templates >"${ESB_TMP}/web_templates.tsv" 2>/dev/null || true
        while IFS="$(printf '\t')" read -r _ui_web_menu_line _ui_web_menu_label; do
          [ -n "$_ui_web_menu_line" ] || continue
          _ui_web_menu_items+=("${_ui_web_menu_line}|${_ui_web_menu_label}")
        done <"${ESB_TMP}/web_templates.tsv"
        ask_single _ui_web_menu_tpl "请选择模板" "${_ui_web_menu_items[@]}"
        if [ "$_ui_web_menu_tpl" = "proxy" ]; then
          local _ui_web_menu_target
          ask_input _ui_web_menu_target "请输入反代目标（如 https://www.example.org）" "$(state_get .web.proxy_target)"
          state_set_str ".web.proxy_target" "$_ui_web_menu_target"
        fi
        state_set ".web.enabled" "true"
        state_set_str ".web.template" "$_ui_web_menu_tpl"
        web_deploy "$_ui_web_menu_tpl" || return 1
        if [ "$(state_get .web.tls)" = "true" ]; then web_apply_cert || true; fi
        ;;
      2)
        state_set ".web.tls" "true"
        web_apply_cert || log_warn "启用 HTTPS 失败"
        ;;
      3)
        ask_yesno "确认关闭伪装站点（保留站点根目录文件）？" n || { pause; continue; }
        web_disable || true
        state_set ".web.enabled" "false"
        fw_apply_all >/dev/null 2>&1 || true
        ;;
      0|'') return 0 ;;
      *) log_warn "无效选项" ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# 客户端配置与分享链接
# ---------------------------------------------------------------------------
ui_show_links() {
  local _ui_show_links_link
  if [ -z "$(proto_enabled_list)" ]; then
    log_warn "尚未启用任何协议"
    return 1
  fi
  ui_blank
  printf '%s分享链接（可直接导入客户端）%s\n' "$C_BOLD" "$C_RESET"
  ui_hr
  render_links | while IFS= read -r _ui_show_links_link; do
    [ -n "$_ui_show_links_link" ] || continue
    printf '%s\n\n' "$_ui_show_links_link"
  done
  return 0
}

ui_show_qr() {
  local _ui_show_qr_link="$1"
  if ! cmd_exists qrencode; then
    log_warn "未安装 qrencode（用于生成终端二维码）"
    if ask_yesno "现在安装 qrencode？" y; then
      deps_install qrencode || { log_warn "安装失败"; return 1; }
    else
      return 1
    fi
  fi
  qrencode -t ANSIUTF8 "$_ui_show_qr_link" || return 1
  return 0
}

ui_clients_menu() {
  local _ui_clients_menu_choice=""
  while :; do
    ui_title "客户端配置与分享链接"
    ui_blank
    sub_status 2>/dev/null || true
    ui_blank
    printf '  1) 查看全部节点链接\n'
    printf '  2) 节点二维码\n'
    printf '  3) 订阅链接（生成 / 查看 / 二维码）\n'
    printf '  4) 重新生成客户端配置与订阅文件\n'
    printf '  5) 查看客户端配置文件路径\n'
    printf '  6) 关闭订阅\n'
    printf '  0) 返回\n'
    printf '请选择 [0-6]: '
    IFS= read -r _ui_clients_menu_choice || _ui_clients_menu_choice="0"
    _ui_clients_menu_choice="${_ui_clients_menu_choice%$'\r'}"
    case "$_ui_clients_menu_choice" in
      1) ui_show_links ;;
      2)
        local _ui_clients_menu_p _ui_clients_menu_line
        local -a _ui_clients_menu_items=()
        for _ui_clients_menu_p in $(proto_enabled_list); do
          _ui_clients_menu_items+=("${_ui_clients_menu_p}|$(proto_label "$_ui_clients_menu_p" | tr -d '\n')")
        done
        ask_single _ui_clients_menu_line "请选择协议" "${_ui_clients_menu_items[@]}"
        ui_show_qr "$(client_link_for "$_ui_clients_menu_line")"
        ;;
      3) ui_sub_menu ;;
      4)
        render_clients || log_warn "客户端配置生成失败"
        sub_refresh
        log_ok "已重新生成客户端配置与订阅文件"
        ;;
      5)
        printf '  目录：%s\n' "$ESB_CLIENT_DIR"
        ls -1 "$ESB_CLIENT_DIR" 2>/dev/null | sed 's/^/      /'
        ;;
      6) sub_disable ;;
      0|'') return 0 ;;
      *) log_warn "无效选项" ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# 订阅
# ---------------------------------------------------------------------------
ui_sub_menu() {
  local _ui_sub_menu_choice="" _ui_sub_menu_url
  while :; do
    ui_title "订阅链接"
    sub_status
    ui_blank
    printf '  1) 生成 / 刷新订阅文件\n'
    printf '  2) 显示订阅地址与二维码\n'
    printf '  3) 显示全部格式的订阅地址\n'
    printf '  4) 重新生成订阅 token（旧地址立即失效）\n'
    printf '  5) 启用独立订阅站点（不用伪装站点时）\n'
    printf '  0) 返回\n'
    printf '请选择 [0-5]: '
    IFS= read -r _ui_sub_menu_choice || _ui_sub_menu_choice="0"
    _ui_sub_menu_choice="${_ui_sub_menu_choice%$'\r'}"
    case "$_ui_sub_menu_choice" in
      1) sub_enable ;;
      2)
        state_set ".sub.enabled" "true" >/dev/null 2>&1 || true
        _ui_sub_menu_url="$(sub_url)"
        ui_blank
        printf '%s%s%s\n' "$C_BOLD" "$_ui_sub_menu_url" "$C_RESET"
        ui_blank
        ui_show_qr "$_ui_sub_menu_url"
        ;;
      3) sub_url_list | while IFS="$(printf '\t')" read -r _ui_sub_menu_k _ui_sub_menu_v; do
           printf '  %-9s %s\n' "$_ui_sub_menu_k" "$_ui_sub_menu_v"
         done ;;
      4)
        ask_yesno "重新生成后旧订阅地址会立刻失效，确认继续？" n || { pause; continue; }
        sub_token_regen >/dev/null && sub_enable
        ;;
      5)
        if [ "$(state_get .web.enabled)" = "true" ]; then
          log_info "当前已开启伪装站点，订阅会自动复用它（无需独立站点）"
          ask_yesno "仍然改为使用独立订阅站点？" n || { pause; continue; }
          state_set ".sub.serve_via_site" "false" >/dev/null 2>&1 || true
        fi
        if ! web_installed; then
          ask_yesno "未安装 nginx，现在安装？" y || { pause; continue; }
          web_install || { pause; continue; }
        fi
        sub_site_deploy || log_warn "订阅站点部署失败"
        sub_write_files >/dev/null 2>&1 || true
        state_set ".sub.enabled" "true" >/dev/null 2>&1 || true
        fw_open "$(state_get .sub.port)" tcp >/dev/null 2>&1 || true
        log_ok "订阅站点已启用：$(sub_url)"
        ;;
      0|'') return 0 ;;
      *) log_warn "无效选项" ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# 更新
# ---------------------------------------------------------------------------
ui_update_menu() {
  local _ui_update_menu_choice=""
  while :; do
    ui_title "更新"
    printf '  sing-box 内核：当前 %s　仓库最新 %s\n' \
      "$(sb_version | sed 's/^$/未安装/')" "$(sb_latest_version | sed 's/^$/未知/')"
    printf '  EasySB 脚本　：当前 %s　仓库最新 %s\n' \
      "$ESB_SCRIPT_VERSION" "$(script_latest_version | sed 's/^$/未知/')"
    ui_blank
    printf '  1) 更新 sing-box 内核\n'
    printf '  2) 更新 EasySB 脚本\n'
    printf '  3) 安装 / 切换指定内核版本\n'
    printf '  0) 返回\n'
    printf '请选择 [0-3]: '
    IFS= read -r _ui_update_menu_choice || _ui_update_menu_choice="0"
    _ui_update_menu_choice="${_ui_update_menu_choice%$'\r'}"
    case "$_ui_update_menu_choice" in
      1) sb_update ;;
      2) script_update ;;
      3)
        local _ui_update_menu_ver
        ask_input _ui_update_menu_ver "请输入要安装的版本号（如 1.14.1）" ""
        if [ -n "$_ui_update_menu_ver" ]; then sb_install "$_ui_update_menu_ver"; fi
        ;;
      0|'') return 0 ;;
      *) log_warn "无效选项" ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
ui_uninstall() {
  ui_title "卸载 EasySB"
  log_warn "将停止服务、删除 systemd unit、回收防火墙规则、关闭伪装站点，并删除 sing-box 内核"
  log_info "保留内容：$ESB_DIR（状态与客户端配置）、$ESB_BACKUP_DIR（备份）、$ESB_WEB_ROOT（站点文件）"
  if ! esb_confirm_or_die "确认卸载 EasySB？"; then return 1; fi
  sb_service stop >/dev/null 2>&1 || true
  sb_service disable >/dev/null 2>&1 || true
  if [ "$(state_get .web.enabled)" = "true" ]; then
    web_disable >/dev/null 2>&1 || true
    state_set ".web.enabled" "false" >/dev/null 2>&1 || true
  fi
  fw_revert_all >/dev/null 2>&1 || log_warn "防火墙规则回收失败，请手动检查"
  unit_remove
  rm -f "$ESB_CONFIG" 2>/dev/null || true
  sb_uninstall
  log_ok "卸载完成（备份与状态保留在 $ESB_DIR）"
  if ask_yesno "是否同时删除状态目录 $ESB_DIR（含客户端配置，不可恢复）？" n; then
    rm -rf "$ESB_DIR" 2>/dev/null || log_warn "删除失败，请手动处理"
    log_ok "已删除 $ESB_DIR"
  fi
  pause
  return 0
}
