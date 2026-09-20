# ------------------------------------------------------------------------------
# 十三、依赖与防火墙 / Dependencies and firewall
# ------------------------------------------------------------------------------
check_dependencies() {
  local DEPS=() DEPS_CHECK=() DEPS_INSTALL=()

  # 1. Alpine 特有处理：检查 BusyBox wget，设置 IS_PREFER_GO
  if [ "$SYSTEM" = 'Alpine' ]; then
    IS_PREFER_GO=true
    local CHECK_WGET=$(wget 2>&1 | sed -n 1p)
    grep -qi 'busybox' <<< "$CHECK_WGET" && DEPS+=("wget")

    DEPS_CHECK+=("bash" "rc-update")
    DEPS_INSTALL+=("bash" "openrc")
  else
    # 非 Alpine 系统，检查 systemd-resolved 状态，用于 DNS 配置里的 prefer_go 字段
    command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved && IS_PREFER_GO=false || IS_PREFER_GO=true
  fi

  # 2. 基础通用依赖（不含防火墙，防火墙仅端口跳跃时按需安装）
  DEPS_CHECK+=("wget" "tar" "ss"  "ip"        "bash" "openssl" "ping")
  DEPS_INSTALL+=("wget" "tar" "iproute2" "iproute2" "bash" "openssl" "iputils-ping")

  [ "$SYSTEM" != 'Alpine' ] && DEPS_CHECK+=("systemctl") && DEPS_INSTALL+=("systemctl")

  # CentOS7 需要 epel-release
  [ "$SYSTEM" = 'CentOS' ] && [ "$IS_CENTOS" = 'CentOS7' ] && \
    yum repolist 2>/dev/null | grep -q epel || { [ "$SYSTEM" = 'CentOS' ] && [ "$IS_CENTOS" = 'CentOS7' ] && DEPS+=("epel-release"); }

  for g in "${!DEPS_CHECK[@]}"; do
    ! command -v "${DEPS_CHECK[g]}" >/dev/null 2>&1 && DEPS+=("${DEPS_INSTALL[g]}")
  done

  # 3. 去重并安装
  DEPS=($(printf "%s\n" "${DEPS[@]}" | sort -u))
  if [ "${#DEPS[@]}" -gt 0 ]; then
    info "\n $(text 7) $(sed "s/ /,&/g" <<< "${DEPS[*]}") \n"
    [[ ! "$SYSTEM" =~ Alpine|CentOS ]] && ${PACKAGE_UPDATE[int]} >/dev/null 2>&1
    ${PACKAGE_INSTALL[int]} "${DEPS[@]}" >/dev/null 2>&1
  else
    info "\n $(text 8) \n"
  fi

  # 4. 对于 Alpine 系统，确保 OpenRC 服务已启动
  if [ "$SYSTEM" = 'Alpine' ]; then
    if ! rc-service --list | grep -q "^openrc"; then
      rc-update add openrc boot >/dev/null 2>&1
      rc-service openrc start >/dev/null 2>&1
    fi
  fi
}

# 生成 UFW PortHopping 备注
add_port_hopping_ufw_rules() {
  local PORT_HOPPING_START=$1
  local PORT_HOPPING_END=$2
  local PORT_HOPPING_TARGET=$3
  local TARGET_PORT="$3"
  local COMMENT="Sing-box Family Bucket UFW NAT ${PORT_HOPPING_START}:${PORT_HOPPING_END} -> ${TARGET_PORT}"

  [ -z "$PORT_HOPPING_START" ] && return 1
  [ -z "$PORT_HOPPING_END" ] && return 1
  [ -z "$TARGET_PORT" ] && return 1

  local UFW_BEFORE_RULES='/etc/ufw/before.rules'
  local UFW_BEFORE6_RULES='/etc/ufw/before6.rules'
  local UFW_IPV4_BLOCK_BEGIN="# ${COMMENT} IPv4 BEGIN"
  local UFW_IPV4_BLOCK_END="# ${COMMENT} IPv4 END"
  local UFW_IPV6_BLOCK_BEGIN="# ${COMMENT} IPv6 BEGIN"
  local UFW_IPV6_BLOCK_END="# ${COMMENT} IPv6 END"

  # 先清理所有历史残留规则，确保文件和 numbered 规则都干净
  del_port_hopping_ufw_rules >/dev/null 2>&1

  # 注意：这里必须用 TARGET_PORT，不能再用可能被下游函数改掉的 PORT_HOPPING_TARGET
  add_port_hopping_ufw_block "$UFW_BEFORE_RULES"  "$UFW_IPV4_BLOCK_BEGIN" "$UFW_IPV4_BLOCK_END" "$PORT_HOPPING_START" "$PORT_HOPPING_END" "$TARGET_PORT" "$COMMENT" || return 1
  add_port_hopping_ufw_block "$UFW_BEFORE6_RULES" "$UFW_IPV6_BLOCK_BEGIN" "$UFW_IPV6_BLOCK_END" "$PORT_HOPPING_START" "$PORT_HOPPING_END" "$TARGET_PORT" "$COMMENT" || return 1

  ufw delete allow ${PORT_HOPPING_START}:${PORT_HOPPING_END}/udp >/dev/null 2>&1 || true
  ufw allow ${PORT_HOPPING_START}:${PORT_HOPPING_END}/udp comment "$COMMENT" >/dev/null 2>&1 || return 1
  ufw reload >/dev/null 2>&1 || return 1

  [ "$(ufw status 2>/dev/null | awk '/^Status/{print $NF; exit}')" != 'active' ] && warning "\n $(text 145) \n"

  return 0
}

# 向指定的 UFW 规则文件写入 PortHopping NAT 规则块
add_port_hopping_ufw_block() {
  local RULES_FILE=$1
  local BLOCK_BEGIN=$2
  local BLOCK_END=$3
  local PORT_HOPPING_START=$4
  local PORT_HOPPING_END=$5
  local PORT_HOPPING_TARGET=$6
  local COMMENT=$7

  [ ! -e "$RULES_FILE" ] && return 0
  [ -z "$PORT_HOPPING_START" ] && return 1
  [ -z "$PORT_HOPPING_END" ] && return 1
  [ -z "$PORT_HOPPING_TARGET" ] && return 1
  [ -z "$COMMENT" ] && return 1

  awk \
    -v begin="$BLOCK_BEGIN" \
    -v end="$BLOCK_END" \
    -v start="$PORT_HOPPING_START" \
    -v finish="$PORT_HOPPING_END" \
    -v target="$PORT_HOPPING_TARGET" \
    -v comment="$COMMENT" '
    BEGIN { inserted=0 }
    {
      if ($0 ~ /^\*filter/ && inserted==0) {
        print begin
        print "*nat"
        print ":PREROUTING ACCEPT [0:0]"
        print "-A PREROUTING -p udp --dport " start ":" finish " -m comment --comment \"" comment "\" -j DNAT --to-destination :" target
        print "COMMIT"
        print end
        inserted=1
      }
      print
    }
    END {
      if (inserted==0) {
        print begin
        print "*nat"
        print ":PREROUTING ACCEPT [0:0]"
        print "-A PREROUTING -p udp --dport " start ":" finish " -m comment --comment \"" comment "\" -j DNAT --to-destination :" target
        print "COMMIT"
        print end
      }
    }
  ' "$RULES_FILE" > "${TEMP_DIR}/$(basename "$RULES_FILE")" && mv "${TEMP_DIR}/$(basename "$RULES_FILE")" "$RULES_FILE"
}

# 删除指定 UFW 规则文件中的 PortHopping NAT 规则块
del_port_hopping_ufw_block() {
  local RULES_FILE=$1
  local IP_VERSION=$2
  local TEMP_RULES_FILE

  [ ! -e "$RULES_FILE" ] && return 0

  TEMP_RULES_FILE="${TEMP_DIR}/$(basename "$RULES_FILE")"

  awk -v ip_version="$IP_VERSION" '
    BEGIN { in_block=0 }
    {
      if ($0 ~ "^# Sing-box Family Bucket UFW NAT .* " ip_version " BEGIN$") {
        in_block=1
        next
      }
      if (in_block==1 && $0 ~ "^# Sing-box Family Bucket UFW NAT .* " ip_version " END$") {
        in_block=0
        next
      }
      if (in_block==0) print
    }
  ' "$RULES_FILE" > "$TEMP_RULES_FILE" && mv "$TEMP_RULES_FILE" "$RULES_FILE"
}

# 删除 UFW PortHopping NAT 规则
del_port_hopping_ufw_rules() {
  local UFW_BEFORE_RULES='/etc/ufw/before.rules'
  local UFW_BEFORE6_RULES='/etc/ufw/before6.rules'
  local COMMENT_PREFIX='Sing-box Family Bucket UFW NAT'
  local RULE_NUM
  local OLD_START OLD_END

  check_port_hopping_ufw_rules
  OLD_START="$PORT_HOPPING_START"
  OLD_END="$PORT_HOPPING_END"

  del_port_hopping_ufw_block "$UFW_BEFORE_RULES" "IPv4" >/dev/null 2>&1
  del_port_hopping_ufw_block "$UFW_BEFORE6_RULES" "IPv6" >/dev/null 2>&1

  if [ -n "$OLD_START" ] && [ -n "$OLD_END" ]; then
    ufw delete allow ${OLD_START}:${OLD_END}/udp >/dev/null 2>&1 || true
  fi

  while read -r RULE_NUM; do
    [ -n "$RULE_NUM" ] && ufw --force delete "$RULE_NUM" >/dev/null 2>&1 || true
  done < <(
    ufw status numbered 2>/dev/null | \
    grep "$COMMENT_PREFIX" | \
    awk -F'[][]' '{print $2}' | sort -rn
  )

  ufw reload >/dev/null 2>&1 || return 1

  unset PORT_HOPPING_START PORT_HOPPING_END HY2_PORT_HOPPING_RANGE
  return 0
}

# 检查 UFW PortHopping NAT 规则
check_port_hopping_ufw_rules() {
  unset PORT_HOPPING_START PORT_HOPPING_END HY2_PORT_HOPPING_RANGE
  local DETECTED_TARGET
  local UFW_BEFORE_RULES='/etc/ufw/before.rules'
  local UFW_BEFORE6_RULES='/etc/ufw/before6.rules'
  local UFW_RULE

  DETECTED_TARGET=$(awk -F '[:,]' '/"listen_port"/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ${WORK_DIR}/conf/*${NODE_TAG[1]}_inbounds.json 2>/dev/null)

  if [ -s "$UFW_BEFORE_RULES" ]; then
    UFW_RULE=$(awk '
      /Sing-box Family Bucket UFW NAT .* IPv4 BEGIN/ { in_block=1; next }
      /Sing-box Family Bucket UFW NAT .* IPv4 END/   { in_block=0 }
      in_block && /-A PREROUTING -p udp/ { print; exit }
    ' "$UFW_BEFORE_RULES")
  fi

  if [ -z "$UFW_RULE" ] && [ -s "$UFW_BEFORE6_RULES" ]; then
    UFW_RULE=$(awk '
      /Sing-box Family Bucket UFW NAT .* IPv6 BEGIN/ { in_block=1; next }
      /Sing-box Family Bucket UFW NAT .* IPv6 END/   { in_block=0 }
      in_block && /-A PREROUTING -p udp/ { print; exit }
    ' "$UFW_BEFORE6_RULES")
  fi

  [ -z "$UFW_RULE" ] && {
    PORT_HOPPING_TARGET="$DETECTED_TARGET"
    return 0
  }

  if [[ "$UFW_RULE" =~ --dport[[:space:]]+([0-9]+):([0-9]+) ]]; then
    PORT_HOPPING_START="${BASH_REMATCH[1]}"
    PORT_HOPPING_END="${BASH_REMATCH[2]}"
    HY2_PORT_HOPPING_RANGE="${PORT_HOPPING_START}:${PORT_HOPPING_END}"
  fi

  if [[ "$UFW_RULE" =~ --to-destination[[:space:]]+:([0-9]+) ]]; then
    PORT_HOPPING_TARGET="${BASH_REMATCH[1]}"
  else
    PORT_HOPPING_TARGET="$DETECTED_TARGET"
  fi
}

# 检测防火墙后端
check_firewall_backend() {
  local UFW_STATUS

  if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS=$(ufw status 2>/dev/null | awk '/^Status/{print $NF; exit}')
    [ "$UFW_STATUS" = 'active' ] && {
      echo 'ufw'
      return
    }
  fi

  if [ "$SYSTEM" = 'Alpine' ]; then
    echo 'alpine-iptables'
  elif command -v firewall-cmd >/dev/null 2>&1 || [ "$SYSTEM" = 'CentOS' ]; then
    echo 'firewalld'
  else
    echo 'iptables'
  fi
}

# 兼容旧调用
check_port_hopping_firewall() {
  check_firewall_backend
}

# 初始化防火墙状态目录
init_firewall_state_dir() {
  [ ! -d "$FIREWALL_STATE_DIR" ] && mkdir -p "$FIREWALL_STATE_DIR"
}

# 读取上一次由脚本管理的普通端口规则
append_unique_port() {
  local ARRAY_NAME=$1
  local PORT=$2
  local -n ARRAY_REF="$ARRAY_NAME"

  [ -z "$PORT" ] && return 0
  [[ ! "$PORT" =~ ^[0-9]+$ ]] && return 0

  local ITEM
  for ITEM in "${ARRAY_REF[@]}"; do
    [ "$ITEM" = "$PORT" ] && return 0
  done

  ARRAY_REF+=("$PORT")
}

# UFW 普通端口规则备注
service_port_ufw_comment() {
  local PROTO=$1
  local PORT=$2
  echo "Sing-box Family Bucket UFW PORT ${PROTO} ${PORT}"
}

# 添加 UFW 普通端口规则
add_service_port_rule_ufw() {
  local PROTO=$1
  local PORT=$2
  local COMMENT
  COMMENT=$(service_port_ufw_comment "$PROTO" "$PORT")

  [ -z "$PROTO" ] || [ -z "$PORT" ] && return 1
  ufw allow ${PORT}/${PROTO} comment "$COMMENT" >/dev/null 2>&1
}

# 清理所有由脚本管理的 UFW 普通端口规则
purge_service_port_rules_ufw() {
  local RULE_NUM
  local COMMENT_PREFIX='Sing-box Family Bucket UFW PORT'

  while read -r RULE_NUM; do
    [ -n "$RULE_NUM" ] && ufw --force delete "$RULE_NUM" >/dev/null 2>&1 || true
  done < <(
    ufw status numbered 2>/dev/null | \
    grep "$COMMENT_PREFIX" | \
    awk -F'[][]' '{print $2}' | sort -rn
  )

  ufw reload >/dev/null 2>&1 || true
}

# 添加 firewalld 普通端口规则
add_service_port_rule_firewalld() {
  local PROTO=$1
  local PORT=$2
  [ -z "$PROTO" ] || [ -z "$PORT" ] && return 1
  firewall-cmd --zone=public --add-port=${PORT}/${PROTO} --permanent >/dev/null 2>&1
}

# 删除 firewalld 普通端口规则
del_service_port_rule_firewalld() {
  local PROTO=$1
  local PORT=$2
  [ -z "$PROTO" ] || [ -z "$PORT" ] && return 0
  firewall-cmd --zone=public --remove-port=${PORT}/${PROTO} --permanent >/dev/null 2>&1
}

# iptables 普通端口规则备注
add_service_port_rule_iptables() {
  local PROTO=$1
  local PORT=$2
  local COMMENT="Sing-box Family Bucket PORT ${PROTO} ${PORT}"

  [ -z "$PROTO" ] || [ -z "$PORT" ] && return 1

  iptables -C INPUT -p ${PROTO} --dport ${PORT} -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1 || \
  iptables -A INPUT -p ${PROTO} --dport ${PORT} -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1

  ip6tables -C INPUT -p ${PROTO} --dport ${PORT} -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1 || \
  ip6tables -A INPUT -p ${PROTO} --dport ${PORT} -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1
}

# 删除 iptables 普通端口规则
del_service_port_rule_iptables() {
  local PROTO=$1
  local PORT=$2
  local COMMENT="Sing-box Family Bucket PORT ${PROTO} ${PORT}"

  [ -z "$PROTO" ] || [ -z "$PORT" ] && return 0

  iptables -D INPUT -p ${PROTO} --dport ${PORT} -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1 || true
  ip6tables -D INPUT -p ${PROTO} --dport ${PORT} -m comment --comment "$COMMENT" -j ACCEPT >/dev/null 2>&1 || true
}

# 按后端保存 / 重载防火墙规则
reload_or_save_firewall_rules() {
  local FW_BACKEND
  FW_BACKEND=$(check_firewall_backend)

  case "$FW_BACKEND" in
    ufw )
      ufw reload >/dev/null 2>&1 || true
      ;;
    firewalld )
      firewall-cmd --reload >/dev/null 2>&1 || true
      ;;
    alpine-iptables )
      rc-service iptables save >/dev/null 2>&1 || true
      rc-service ip6tables save >/dev/null 2>&1 || true
      ;;
    * )
      [ "$(systemctl is-active netfilter-persistent 2>/dev/null)" = 'active' ] && netfilter-persistent save >/dev/null 2>&1 || true
      ;;
  esac
}

# 清理上一次由脚本管理的普通端口规则
purge_service_firewall_rules() {
  local FW_BACKEND
  FW_BACKEND=$(check_firewall_backend)

  init_firewall_state_dir
  MANAGED_TCP_PORTS=()
  MANAGED_UDP_PORTS=()

  [ ! -s "$SERVICE_FIREWALL_STATE_FILE" ] || while read -r PROTO PORT; do
    case "$PROTO" in
      tcp ) MANAGED_TCP_PORTS+=("$PORT") ;;
      udp ) MANAGED_UDP_PORTS+=("$PORT") ;;
    esac
  done < "$SERVICE_FIREWALL_STATE_FILE"

  case "$FW_BACKEND" in
    ufw )
      purge_service_port_rules_ufw
      ;;
    firewalld )
      local PORT
      for PORT in "${MANAGED_TCP_PORTS[@]}"; do
        del_service_port_rule_firewalld tcp "$PORT"
      done
      for PORT in "${MANAGED_UDP_PORTS[@]}"; do
        del_service_port_rule_firewalld udp "$PORT"
      done
      ;;
    alpine-iptables|iptables )
      local PORT
      for PORT in "${MANAGED_TCP_PORTS[@]}"; do
        del_service_port_rule_iptables tcp "$PORT"
      done
      for PORT in "${MANAGED_UDP_PORTS[@]}"; do
        del_service_port_rule_iptables udp "$PORT"
      done
      ;;
  esac

  : > "$SERVICE_FIREWALL_STATE_FILE"
  reload_or_save_firewall_rules
}

# 同步普通服务端口规则
# 同步所有防火墙规则
sync_firewall_rules() {
  local FW_BACKEND
  local PORT
  local HY2_FILE="${WORK_DIR}/conf/*${NODE_TAG[1]}_inbounds.json"
  local HY2_TARGET DESIRED_START DESIRED_END
  local EXISTING_START EXISTING_END EXISTING_TARGET
  local FILE BASENAME NGINX_PORT HAS_NGINX=false

  EXPOSED_TCP_PORTS=()
  EXPOSED_UDP_PORTS=()

  if [ -s "${WORK_DIR}/nginx.conf" ]; then
    HAS_NGINX=true
    NGINX_PORT=$(awk '
      /listen[[:space:]]+[0-9]+[[:space:]]*;/ && $2 !~ /^\[/ {
        gsub(/;/, "", $2)
        print $2
        exit
      }
    ' "${WORK_DIR}/nginx.conf")
    append_unique_port EXPOSED_TCP_PORTS "$NGINX_PORT"
  fi

  for FILE in ${WORK_DIR}/conf/*_inbounds.json; do
    [ ! -s "$FILE" ] && continue
    BASENAME=$(basename "$FILE")
    PORT=$(awk -F '[:,]' '/"listen_port"/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$FILE")
    [ -z "$PORT" ] && continue

    case "$BASENAME" in
      *hysteria2_inbounds.json|*tuic_inbounds.json )
        append_unique_port EXPOSED_UDP_PORTS "$PORT"
        ;;
      *naive_inbounds.json )
        append_unique_port EXPOSED_TCP_PORTS "$PORT"
        append_unique_port EXPOSED_UDP_PORTS "$PORT"
        ;;
      *vmess-ws_inbounds.json|*vless-ws-tls_inbounds.json )
        [ "$HAS_NGINX" = false ] && append_unique_port EXPOSED_TCP_PORTS "$PORT"
        ;;
      * )
        append_unique_port EXPOSED_TCP_PORTS "$PORT"
        ;;
    esac
  done

  FW_BACKEND=$(check_firewall_backend)

  init_firewall_state_dir
  MANAGED_TCP_PORTS=()
  MANAGED_UDP_PORTS=()
  if [ -s "$SERVICE_FIREWALL_STATE_FILE" ]; then
    while read -r PROTO PORT; do
      case "$PROTO" in
        tcp ) MANAGED_TCP_PORTS+=("$PORT") ;;
        udp ) MANAGED_UDP_PORTS+=("$PORT") ;;
      esac
    done < "$SERVICE_FIREWALL_STATE_FILE"
  fi

  case "$FW_BACKEND" in
    ufw )
      purge_service_port_rules_ufw
      ;;
    firewalld )
      for PORT in "${MANAGED_TCP_PORTS[@]}"; do
        del_service_port_rule_firewalld tcp "$PORT"
      done
      for PORT in "${MANAGED_UDP_PORTS[@]}"; do
        del_service_port_rule_firewalld udp "$PORT"
      done
      ;;
    alpine-iptables|iptables )
      for PORT in "${MANAGED_TCP_PORTS[@]}"; do
        del_service_port_rule_iptables tcp "$PORT"
      done
      for PORT in "${MANAGED_UDP_PORTS[@]}"; do
        del_service_port_rule_iptables udp "$PORT"
      done
      ;;
  esac

  : > "$SERVICE_FIREWALL_STATE_FILE"
  reload_or_save_firewall_rules

  case "$FW_BACKEND" in
    ufw )
      for PORT in "${EXPOSED_TCP_PORTS[@]}"; do
        add_service_port_rule_ufw tcp "$PORT"
      done
      for PORT in "${EXPOSED_UDP_PORTS[@]}"; do
        add_service_port_rule_ufw udp "$PORT"
      done
      ;;
    firewalld )
      for PORT in "${EXPOSED_TCP_PORTS[@]}"; do
        add_service_port_rule_firewalld tcp "$PORT"
      done
      for PORT in "${EXPOSED_UDP_PORTS[@]}"; do
        add_service_port_rule_firewalld udp "$PORT"
      done
      ;;
    alpine-iptables|iptables )
      for PORT in "${EXPOSED_TCP_PORTS[@]}"; do
        add_service_port_rule_iptables tcp "$PORT"
      done
      for PORT in "${EXPOSED_UDP_PORTS[@]}"; do
        add_service_port_rule_iptables udp "$PORT"
      done
      ;;
  esac

  : > "$SERVICE_FIREWALL_STATE_FILE"
  for PORT in "${EXPOSED_TCP_PORTS[@]}"; do
    [ -n "$PORT" ] && echo "tcp $PORT" >> "$SERVICE_FIREWALL_STATE_FILE"
  done
  for PORT in "${EXPOSED_UDP_PORTS[@]}"; do
    [ -n "$PORT" ] && echo "udp $PORT" >> "$SERVICE_FIREWALL_STATE_FILE"
  done
  reload_or_save_firewall_rules

  HY2_TARGET=$(awk -F '[:,]' '/"listen_port"/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ${HY2_FILE} 2>/dev/null)

  check_port_hopping_nat
  EXISTING_START="$PORT_HOPPING_START"
  EXISTING_END="$PORT_HOPPING_END"
  EXISTING_TARGET="$PORT_HOPPING_TARGET"

  DESIRED_START="${PORT_HOPPING_START:-$EXISTING_START}"
  DESIRED_END="${PORT_HOPPING_END:-$EXISTING_END}"

  if [ -z "$HY2_TARGET" ]; then
    [ -n "$EXISTING_START" ] && [ -n "$EXISTING_END" ] && del_port_hopping_nat
    unset PORT_HOPPING_START PORT_HOPPING_END HY2_PORT_HOPPING_RANGE PORT_HOPPING_TARGET
    return 0
  fi

  if [ -z "$DESIRED_START" ] || [ -z "$DESIRED_END" ]; then
    [ -n "$EXISTING_START" ] && [ -n "$EXISTING_END" ] && del_port_hopping_nat
    unset PORT_HOPPING_START PORT_HOPPING_END HY2_PORT_HOPPING_RANGE
    PORT_HOPPING_TARGET="$HY2_TARGET"
    return 0
  fi

  if [ "$EXISTING_START" != "$DESIRED_START" ] ||      [ "$EXISTING_END" != "$DESIRED_END" ] ||      [ "$EXISTING_TARGET" != "$HY2_TARGET" ]; then
    [ -n "$EXISTING_START" ] && [ -n "$EXISTING_END" ] && del_port_hopping_nat
    PORT_HOPPING_START="$DESIRED_START"
    PORT_HOPPING_END="$DESIRED_END"
    HY2_PORT_HOPPING_RANGE="${DESIRED_START}:${DESIRED_END}"
    PORT_HOPPING_TARGET="$HY2_TARGET"
    add_port_hopping_nat "$PORT_HOPPING_START" "$PORT_HOPPING_END" "$PORT_HOPPING_TARGET"
  fi
}
export_argo_json_file() {
  local FILE_PATH=$1
  [[ -z "$PORT_NGINX" && -s ${WORK_DIR}/nginx.conf ]] && local PORT_NGINX=$(awk '/listen/{print $2; exit}' ${WORK_DIR}/nginx.conf)
  [ ! -s $FILE_PATH/tunnel.json ] && echo $ARGO_JSON > $FILE_PATH/tunnel.json
  [ ! -s $FILE_PATH/tunnel.yml ] && cat > $FILE_PATH/tunnel.yml << EOF
tunnel: $(awk -F '"' '{print $12}' <<< "$ARGO_JSON")
credentials-file: ${WORK_DIR}/tunnel.json

ingress:
  - hostname: ${ARGO_DOMAIN}
    service: http://localhost:${PORT_NGINX}
  - service: http_status:404
EOF
}

# 生成自签证书，区分使用 IPv4 / IPv6 / 域名
# 默认同时更新 cert.pem(36500天) 和 cert_200.pem(200天)
# 传参 naive_only 时，仅检测 cert_200.pem 是否缺失 / 过期 / SNI 不一致，符合条件才更新
ssl_certificate() {
  local TLS_SERVER="$1"
  local CERT_MODE="$2"
  local CERT_200_FILE="${WORK_DIR}/cert/cert_200.pem"
  local CERT_200_SNI

  [ ! -d ${WORK_DIR}/cert ] && mkdir -p ${WORK_DIR}/cert

  if [ "$CERT_MODE" != 'naive_only' ]; then
    openssl ecparam -genkey -name prime256v1 -out ${WORK_DIR}/cert/private.key
  elif [ ! -s ${WORK_DIR}/cert/private.key ] || [ ! -s ${WORK_DIR}/cert/cert.pem ]; then
    CERT_MODE=''
    openssl ecparam -genkey -name prime256v1 -out ${WORK_DIR}/cert/private.key
  fi

  cat > ${WORK_DIR}/cert/cert.conf << EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $(awk -F . '{print $(NF-1)"."$NF}' <<< "$TLS_SERVER")

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS = ${TLS_SERVER}
EOF

  if [ "$CERT_MODE" != 'naive_only' ]; then
    openssl req -new -x509 -days 36500 -key ${WORK_DIR}/cert/private.key -out ${WORK_DIR}/cert/cert.pem -config ${WORK_DIR}/cert/cert.conf -extensions v3_req
    openssl req -new -x509 -days 200 -key ${WORK_DIR}/cert/private.key -out ${WORK_DIR}/cert/cert_200.pem -config ${WORK_DIR}/cert/cert.conf -extensions v3_req
  else
    CERT_200_SNI=$(openssl x509 -noout -ext subjectAltName -in "$CERT_200_FILE" 2>/dev/null | awk -F 'DNS:' '/DNS:/{gsub(/,.*/, "", $2); print $2}')
    if [ ! -s "$CERT_200_FILE" ] || ! openssl x509 -checkend 0 -noout -in "$CERT_200_FILE" >/dev/null 2>&1 || [ "$CERT_200_SNI" != "$TLS_SERVER" ]; then
      openssl req -new -x509 -days 200 -key ${WORK_DIR}/cert/private.key -out ${WORK_DIR}/cert/cert_200.pem -config ${WORK_DIR}/cert/cert.conf -extensions v3_req
    fi
  fi

  rm -f ${WORK_DIR}/cert/cert.conf
}

# Nginx 配置文件
export_nginx_conf_file() {
  # 在添加协议，需要用到 nginx 的时候，先检测是否已经安装
  if ! command -v nginx >/dev/null 2>&1; then
    info "\n $(text 7) nginx"
    ${PACKAGE_INSTALL[int]} nginx >/dev/null 2>&1
  fi

  NGINX_CONF="user  root;
worker_processes  auto;

error_log  /dev/null;
pid        /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
"
  [ "$IS_SUB" = 'is_sub' ] && NGINX_CONF+="
  map \$http_user_agent \$path1 {
    default                    /;               # 默认路径
    ~*v2rayN                   /v2rayn;         # 匹配 V2rayN 客户端
    ~*clash                    /clash;          # 匹配 Clash 客户端
    ~*Throne|Neko              /throne;         # 匹配 Throne / Neko 客户端
    ~*ShadowRocket             /shadowrocket;   # 匹配 ShadowRocket 客户端
    ~*SFM|SFI|SFA              /sing-box;       # 匹配 Sing-box 官方客户端
#   ~*Chrome|Firefox|Mozilla   /;               # 添加更多的分流规则
  }
  map \$http_user_agent \$path2 {
    default                    /;               # 默认路径
    ~*v2rayN                   /v2rayn;         # 匹配 V2rayN 客户端
    ~*clash                    /clash2;         # 匹配 Clash 客户端
    ~*Throne|Neko              /throne;         # 匹配 Throne / Neko 客户端
    ~*ShadowRocket             /shadowrocket;   # 匹配 ShadowRocket 客户端
    ~*SFM|SFI|SFA              /sing-box;       # 匹配 Sing-box 官方客户端
#   ~*Chrome|Firefox|Mozilla   /;               # 添加更多的分流规则
  }"

  [ "$IS_SUB" = 'is_sub' ] && NGINX_CONF+="
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';
"

  NGINX_CONF+="
    access_log  /dev/null;

    sendfile        on;
    #tcp_nopush     on;

    keepalive_timeout  65;

    #gzip  on;

    #include /etc/nginx/conf.d/*.conf;

  server {
    listen $PORT_NGINX ;  # ipv4
    listen [::]:$PORT_NGINX ;  # ipv6
    server_name localhost;
"

  [[ -n "$PORT_VMESS_WS" && "$IS_ARGO" = 'is_argo' ]] && NGINX_CONF+="
    # 反代 sing-box vmess websocket
    location /${UUID_CONFIRM}-vmess {
      if (\$http_upgrade != "websocket") {
         return 404;
      }
      proxy_pass                          http://127.0.0.1:${PORT_VMESS_WS};
      proxy_http_version                  1.1;
      proxy_set_header Upgrade            \$http_upgrade;
      proxy_set_header Connection         "upgrade";
      proxy_set_header X-Real-IP          \$remote_addr;
      proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
      proxy_set_header Host               \$host;
      proxy_redirect                      off;
    }
"

  [[ -n "$PORT_VLESS_WS" && "$IS_ARGO" = 'is_argo' ]] && NGINX_CONF+="
    # 反代 sing-box vless websocket
    location /${UUID_CONFIRM}-vless {
      if (\$http_upgrade != "websocket") {
         return 404;
      }
      proxy_http_version                  1.1;
      proxy_pass                          https://127.0.0.1:${PORT_VLESS_WS};
      proxy_ssl_protocols                 TLSv1.3;
      proxy_set_header Upgrade            \$http_upgrade;
      proxy_set_header Connection         "upgrade";
      proxy_set_header X-Real-IP          \$remote_addr;
      proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
      proxy_set_header Host               \$host;
      proxy_redirect                      off;
    }
"

  [ "$IS_SUB" = 'is_sub' ] && NGINX_CONF+="
    # 来自 /auto2 的分流
    location ~ ^/${UUID_CONFIRM}/auto2 {
      default_type 'text/plain; charset=utf-8';
      alias ${WORK_DIR}/subscribe/\$path2;
    }

    # 来自 /auto 的分流
    location ~ ^/${UUID_CONFIRM}/auto {
      default_type 'text/plain; charset=utf-8';
      alias ${WORK_DIR}/subscribe/\$path1;
    }

    location ~ ^/${UUID_CONFIRM}/(.*) {
      autoindex on;
      proxy_set_header X-Real-IP \$proxy_protocol_addr;
      default_type 'text/plain; charset=utf-8';
      alias ${WORK_DIR}/subscribe/\$1;
    }
"

  NGINX_CONF+="  }
}"

  echo "$NGINX_CONF" > ${WORK_DIR}/nginx.conf
}

# ==================== 流量统计 ====================
# 流量与单位换算：四舍五入保留 1 位小数
format_traffic() {
  local BYTES=$1
  [ "$BYTES" -lt 1024 ] && { echo "${BYTES} B"; return; }
  local DIV UNIT
  if [ "$BYTES" -lt $((1024 * 1024)) ]; then
    DIV=1024; UNIT=KB
  elif [ "$BYTES" -lt $((1024 * 1024 * 1024)) ]; then
    DIV=$((1024 * 1024)); UNIT=MB
  elif [ "$BYTES" -lt $((1024 * 1024 * 1024 * 1024)) ]; then
    DIV=$((1024 * 1024 * 1024)); UNIT=GB
  else
    DIV=$((1024 * 1024 * 1024 * 1024)); UNIT=TB
  fi
  local IDX=$((BYTES / DIV))
  local REM=$(( ((BYTES % DIV) * 10 + DIV / 2) / DIV ))
  [ "$REM" -ge 10 ] && { IDX=$((IDX + 1)); REM=0; }
  echo "${IDX}.${REM} ${UNIT}"
}

# 检测端口是否被系统占用（严格匹配端口号，避免 1111 误命中 11111）
is_port_in_use() {
  local _PORT="$1"
  ss -nltup 2>/dev/null | grep -qE "([[:space:]]|^)[^[:space:]]*:${_PORT}([[:space:]]|$)"
}

# 校验服务器地址：IPv4 / IPv6 / 域名（域名须含至少一个点，NAT 场景可用 DDNS 域名）
is_valid_server_addr() {
  local _ADDR="$1"
  [[ "$_ADDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
  [[ "$_ADDR" =~ ^[0-9a-fA-F:]+$ && "$_ADDR" =~ : ]] && return 0
  [[ "$_ADDR" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]] && return 0
  return 1
}

# 在脚本限制的端口范围内（MIN_PORT-MAX_PORT）随机找一个未被系统占用的端口。
# 逻辑统一为数组承载候选端口：一次性随机生成 16 个端口装入数组，
# 逐个用 ss -nltp 探测占用情况，返回第一个空闲端口；全部占用则返回 1。
# 用两次 RANDOM 组合成 0-65535 的随机值再取模，避免单次 RANDOM(0-32767) 无法覆盖完整范围。
# 供 nginx 默认端口（input_nginx_port）与 clash_api 端口（find_free_api_port）共用。
find_free_port() {
  local CAND=() SPAN=$((MAX_PORT - MIN_PORT + 1)) IDX PORT
  for IDX in $(seq 1 16); do
    CAND+=("$((MIN_PORT + ((RANDOM * 2) + (RANDOM % 2)) % SPAN))")
  done
  for PORT in "${CAND[@]}"; do
    if ! is_port_in_use "$PORT"; then
      echo "$PORT"; return 0
    fi
  done
  return 1
}

# 在脚本限制的端口范围内随机找一个未被占用的空闲端口，供 clash_api 监听（复用 find_free_port）。
find_free_api_port() {
  local PORT
  PORT=$(find_free_port) || PORT=10000   # 探测失败则回退默认值
  echo "$PORT"
}

# 获取 /connections 流量数据并缓存到全局变量 STATS_JSON（静默降级：任一前置不满足即返回 1）
# clash_api 由官方二进制默认编译（with_clash_api），无需版本门控；
# /connections 返回 { downloadTotal, uploadTotal, connections: [...] }，
# downloadTotal / uploadTotal 为进程生命周期累计值
ensure_stats_data() {
  [ -n "$STATS_JSON" ] && return 0
  [ "${STATUS[0]}" != "$(text 28)" ] && return 1   # Sing-box 未运行
  [ ! -x "$WORK_DIR/sing-box" ] && return 1

  local API_PORT
  # 从 04_experimental.json 解析 clash_api 监听端口（external_controller 形如 127.0.0.1:<port>）。
  # 单条 sed 正则提取（排除 // 注释行），不依赖 jq / 多段管道。
  API_PORT=$(sed -n '/^[[:space:]]*\/\//!s/.*"external_controller"[[:space:]]*:[[:space:]]*"127\.0\.0\.1:\([0-9][0-9]*\)".*/\1/p' "$WORK_DIR/conf/04_experimental.json" 2>/dev/null | head -1)
  [ -z "$API_PORT" ] && return 1

  # curl 优先，wget 兜底（脚本安装时已依赖 wget，必存在）
  if command -v curl >/dev/null 2>&1; then
    STATS_JSON=$(curl -fsS --max-time 3 "http://127.0.0.1:${API_PORT}/connections" 2>/dev/null) || return 1
  else
    STATS_JSON=$(wget -qO- --timeout=3 "http://127.0.0.1:${API_PORT}/connections" 2>/dev/null) || return 1
  fi
  [ -n "$STATS_JSON" ] || return 1
}

