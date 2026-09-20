# ------------------------------------------------------------------------------
# 十一、系统检测、服务管理与安装状态 / System check, service control and install state
# ------------------------------------------------------------------------------
check_root() {
  [ "$(id -u)" != 0 ] && error "\n $(text 43) \n"
}

# 判断处理器架构
check_arch() {
  [ "$SYSTEM" = 'Alpine' ] && local IS_MUSL='-musl'

  case "$(uname -m)" in
    aarch64|arm64 )
      SING_BOX_ARCH=arm64${IS_MUSL}; JQ_ARCH=arm64; QRENCODE_ARCH=arm64; ARGO_ARCH=arm64
      ;;
    x86_64|amd64 )
      SING_BOX_ARCH=amd64${IS_MUSL}; JQ_ARCH=amd64; QRENCODE_ARCH=amd64; ARGO_ARCH=amd64
      ;;
    armv7l )
      SING_BOX_ARCH=armv7${IS_MUSL}; JQ_ARCH=armhf; QRENCODE_ARCH=arm; ARGO_ARCH=arm
      ;;
    * )
      error " $(text 25) "
  esac
}

# 检查系统是否已经安装 tcp-brutal
check_brutal() {
  IS_BRUTAL=false && command -v lsmod >/dev/null 2>&1 && lsmod 2>/dev/null | grep -q 'brutal' && IS_BRUTAL=true
  [ "$IS_BRUTAL" = 'false' ] && command -v modprobe >/dev/null 2>&1 && modprobe brutal 2>/dev/null && IS_BRUTAL=true
}

# 查安装及运行状态，下标0: sing-box，下标1: argo，下标2: nginx；状态码: 26 未安装， 27 已安装未运行， 28 运行中
check_install() {
  local PS_LIST=$(ps -eo pid,args | grep -E "$WORK_DIR.*([s]ing-box|[c]loudflared|[n]ginx)" | sed 's/^[ ]\+//g')

  [[ "$IS_SUB" = 'is_sub' || -s ${WORK_DIR}/subscribe/qr ]] && IS_SUB=is_sub || IS_SUB=no_sub
  if ls ${WORK_DIR}/conf/*${NODE_TAG[1]}_inbounds.json >/dev/null 2>&1; then
    check_port_hopping_nat
    [ -n "$PORT_HOPPING_END" ] && IS_HOPPING=is_hopping || IS_HOPPING=no_hopping
  fi

  if [ "$SYSTEM" = 'Alpine' ]; then
    # Alpine 系统使用 OpenRC 检查服务
    if [ -s ${SINGBOX_DAEMON_FILE} ]; then
      local OPENRC_EXECSTART=$(grep '^command=' ${SINGBOX_DAEMON_FILE})
      case "$OPENRC_EXECSTART" in
        *"${WORK_DIR}/sing-box"* )
          if rc-service sing-box status &>/dev/null; then
            STATUS[0]=$(text 28)
          else
            STATUS[0]=$(text 27)
          fi
          ;;
        * )
          SING_BOX_SCRIPT='Unknown or customized sing-box' && error "\n $(text 99) \n"
      esac
    else
      STATUS[0]=$(text 26)
    fi
  else
    # 非 Alpine 系统使用 systemd 检查服务
    if [ -s ${SINGBOX_DAEMON_FILE} ]; then
      SYSTEMD_EXECSTART=$(grep '^ExecStart=' ${SINGBOX_DAEMON_FILE})
      case "$SYSTEMD_EXECSTART" in
        "ExecStart=${WORK_DIR}/sing-box run -C ${WORK_DIR}/conf/" | "ExecStart=${WORK_DIR}/sing-box run -C ${WORK_DIR}/conf" )
          [ "$(systemctl is-active sing-box)" = 'active' ] && STATUS[0]=$(text 28) || STATUS[0]=$(text 27)
          ;;
        'ExecStart=/etc/v2ray-agent/sing-box/sing-box run -c /etc/v2ray-agent/sing-box/conf/config.json' )
          SING_BOX_SCRIPT='mack-a/v2ray-agent' && error "\n $(text 99) \n"
          ;;
        'ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json' )
          SING_BOX_SCRIPT='yonggekkk/sing-box_hysteria2_tuic_argo_reality' && error "\n $(text 99) \n"
          ;;
        'ExecStart=/usr/local/s-ui/bin/runSingbox.sh' )
          SING_BOX_SCRIPT='alireza0/s-ui' && error "\n $(text 99) \n"
          ;;
        'ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json' )
          SING_BOX_SCRIPT='FranzKafkaYu/sing-box-yes' && error "\n $(text 99) \n"
          ;;
        * )
          # 检查是否是自己的脚本安装的，但路径略有不同
          if [[ "$SYSTEMD_EXECSTART" =~ "ExecStart=${WORK_DIR}/sing-box run" ]]; then
            [ "$(systemctl is-active sing-box)" = 'active' ] && STATUS[0]=$(text 28) || STATUS[0]=$(text 27)
          else
            SING_BOX_SCRIPT='Unknown or customized sing-box' && error "\n $(text 99) \n"
          fi
      esac
    elif [ -s /lib/systemd/system/sing-box.service ]; then
      SYSTEMD_EXECSTART=$(grep '^ExecStart=' /lib/systemd/system/sing-box.service)
      case "$SYSTEMD_EXECSTART" in
        'ExecStart=/etc/sing-box/bin/sing-box run -c /etc/sing-box/config.json -C /etc/sing-box/conf' )
          SING_BOX_SCRIPT='233boy/sing-box' && error "\n $(text 99) \n"
          ;;
        * )
          # 检查是否是自己的脚本安装的，但路径略有不同
          if [[ "$SYSTEMD_EXECSTART" =~ "ExecStart=${WORK_DIR}/sing-box run" ]]; then
            [ "$(systemctl is-active sing-box)" = 'active' ] && STATUS[0]=$(text 28) || STATUS[0]=$(text 27)
          else
            SING_BOX_SCRIPT='Unknown or customized sing-box' && error "\n $(text 99) \n"
          fi
      esac
    else
      STATUS[0]=$(text 26)
    fi
  fi

  # 并发下载订阅模板 (clash, clash2, sing-box-template)，在新安装和更换协议时会用到
  {
    wget --no-check-certificate --continue --tries=2 --timeout=10 -qO $TEMP_DIR/clash ${GH_PROXY}${SUBSCRIBE_TEMPLATE}/clash 2>/dev/null &
    wget --no-check-certificate --continue --tries=2 --timeout=10 -qO $TEMP_DIR/clash2 ${GH_PROXY}${SUBSCRIBE_TEMPLATE}/clash2 2>/dev/null &
    wget --no-check-certificate --continue --tries=2 --timeout=10 -qO $TEMP_DIR/sing-box-template ${GH_PROXY}${SUBSCRIBE_TEMPLATE}/sing-box 2>/dev/null &
    wait
  } &

  # 如果有需要，后台静默下载 sing-box
  if [ "${STATUS[0]}" = "$(text 26)" ] && [ ! -s ${WORK_DIR}/sing-box ]; then
    # 任务 1: 下载 sing-box
    {
      local ONLINE=$(get_sing_box_version)
      local SB_DIR="$TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH"
      local SB_BIN="$SB_DIR/sing-box"
      wget --no-check-certificate --continue --tries=2 --timeout=10 \
        ${GH_PROXY}${PROJECT_SING_BOX_RELEASE}/download/v$ONLINE/sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz \
        -qO- | tar xz -C $TEMP_DIR 2>/dev/null
      [ -s "$SB_BIN" ] && [ -x "$SB_BIN" ] && mv "$SB_BIN" "$TEMP_DIR/sing-box" && chmod +x "$TEMP_DIR/sing-box"
    } &

    # 任务 2: 下载 jq
    {
      wget --no-check-certificate --continue --tries=2 --timeout=10 -qO $TEMP_DIR/jq \
        ${GH_PROXY}https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$JQ_ARCH 2>/dev/null \
        && chmod +x $TEMP_DIR/jq
    } &

    # 任务 3: 下载 qrencode
    {
      wget --no-check-certificate --continue --tries=2 --timeout=10 -qO $TEMP_DIR/qrencode \
        ${GH_PROXY}https://github.com/fscarmen/client_template/raw/main/qrencode-go/qrencode-go-linux-$QRENCODE_ARCH 2>/dev/null \
        && chmod +x $TEMP_DIR/qrencode
    } &

    # 任务 4: 注册 warp 账号（仅支持 TUN 时才有 warp-ep 出站，无 TUN 时不需注册）
    [ "$IS_TUN" = 'is_tun' ] &&
    {
      timeout 15 bash <(wget -qO- --timeout=5 --tries=1 "https://gitlab.com/fscarmen/warp/-/raw/main/api.sh") --register > $TEMP_DIR/warp_account.json 2>/dev/null
    } &
  elif [ "${STATUS[0]}" != "$(text 26)" ]; then
    # 查 sing-box 进程号，运行时长和内存占用，占用的端口
    SING_BOX_VERSION="Version: $(${WORK_DIR}/sing-box version | awk '/version/{print $NF}')"
    [ "${STATUS[0]}" = "$(text 28)" ] && SING_BOX_PID=$(awk '/sing-box run/{print $1}' <<< "$PS_LIST") && [[ "$SING_BOX_PID" =~ ^[0-9]+$ ]] && SING_BOX_MEMORY_USAGE="$(text 58): $(awk '/VmRSS/{printf "%.1f\n", $2/1024}' /proc/$SING_BOX_PID/status) MB"

    NOW_PORTS=$(awk -F ':|,' '/listen_port/{print $2}' ${WORK_DIR}/conf/*)
    NOW_START_PORT=$(awk 'NR == 1 { min = $0 } { if ($0 < min) min = $0; count++ } END {print min}' <<< "$NOW_PORTS")
    NOW_CONSECUTIVE_PORTS=$(awk 'END { print NR }' <<< "$NOW_PORTS")
  fi

  if [ "$NONINTERACTIVE_INSTALL" != 'noninteractive_install' ]; then
    # 检查 Argo 服务状态
    STATUS[1]=$(text 26) && IS_ARGO=no_argo
    [ -s ${ARGO_DAEMON_FILE} ] && IS_ARGO=is_argo && STATUS[1]=$(text 27)
    cmd_systemctl status argo &>/dev/null && STATUS[1]=$(text 28)
  fi

  # 检查 Argo 服务类型
  if [ "$SYSTEM" = 'Alpine' ]; then
    if [ -s ${ARGO_DAEMON_FILE} ]; then
      local ARGO_CONTENT=$(grep '^command_args=' ${ARGO_DAEMON_FILE})
      if grep -q '\--token' <<< "$ARGO_CONTENT"; then
        ARGO_TYPE=is_token_argo
      elif grep -q '\--config' <<< "$ARGO_CONTENT"; then
        ARGO_TYPE=is_json_argo
      elif grep -q '\--url' <<< "$ARGO_CONTENT"; then
        ARGO_TYPE=is_quicktunnel_argo
      fi
    fi
  else
    if [ -s ${ARGO_DAEMON_FILE} ]; then
      local ARGO_CONTENT=$(grep '^ExecStart' ${ARGO_DAEMON_FILE})
      if grep -q '\--token' <<< "$ARGO_CONTENT"; then
        ARGO_TYPE=is_token_argo
      elif grep -q '\--config' <<< "$ARGO_CONTENT"; then
        ARGO_TYPE=is_json_argo
      elif grep -q '\--url' <<< "$ARGO_CONTENT"; then
        ARGO_TYPE=is_quicktunnel_argo
      fi
    fi
  fi

  # 如果有需要，后台静默下载 cloudflared
  if [[ "${STATUS[1]}" = "$(text 26)" || "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]] && [ ! -s ${WORK_DIR}/cloudflared ]; then
    {
      wget --no-check-certificate --tries=2 --timeout=10 -qO $TEMP_DIR/cloudflared ${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARGO_ARCH >/dev/null 2>&1 && chmod +x $TEMP_DIR/cloudflared >/dev/null 2>&1
    }&
  elif [ "${STATUS[1]}" != "$(text 26)" ]; then
    # 查 Argo 进程号，运行时长和内存占用
    ARGO_VERSION=$(${WORK_DIR}/cloudflared -v | awk '{print $3}' | sed "s@^@Version: &@g")
    [ "${STATUS[1]}" = "$(text 28)" ] && ARGO_PID=$(awk '/cloudflared/{print $1}' <<< "$PS_LIST") && [[ "$ARGO_PID" =~ ^[0-9]+$ ]] && ARGO_MEMORY_USAGE="$(text 58): $(awk '/VmRSS/{printf "%.1f\n", $2/1024}' /proc/$ARGO_PID/status) MB"
  fi

  # 检查 Nginx 状态
  if ! command -v nginx >/dev/null 2>&1; then
    STATUS[2]=$(text 26)
  elif [ -s ${WORK_DIR}/nginx.conf ]; then
    # 查 Nginx 进程号，运行时长和内存占用
    NGINX_VERSION=$(nginx -v 2>&1 | sed "s#.*/##; s/ ([^)]*)//" | sed "s@^@Version: &@g")
    NGINX_PID=$(awk '/nginx/{print $1}' <<< "${PS_LIST}")
    if [[ "$NGINX_PID" =~ ^[0-9]+$ ]]; then
      STATUS[2]=$(text 28)
      NGINX_MEMORY_USAGE="$(text 58): $(awk '/VmRSS/{printf "%.1f\n", $2/1024}' /proc/$NGINX_PID/status) MB"
    else
      STATUS[2]=$(text 27)
    fi
  else
    STATUS[2]=$(text 27)
  fi
}

# Nginx 启动/停止函数（全局定义，供 cmd_systemctl() 和 change_config() 共用）
nginx_run() {
  $(command -v nginx) -c $WORK_DIR/nginx.conf
}

nginx_stop() {
  local NGINX_PID=$(ps -eo pid,args | awk -v work_dir="$WORK_DIR" '$0~(work_dir"/nginx.conf"){print $1;exit}')
  ss -nltp | sed -n "/pid=$NGINX_PID,/ s/,/ /gp" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u | xargs kill -9 >/dev/null 2>&1
}

# 让 nginx 进程与最终配置状态保持一致：需要则启动/热重载，不需要则停止
nginx_sync() {
  if [ -s ${WORK_DIR}/nginx.conf ]; then
    if ps -eo pid,args | grep -qE "[n]ginx.*${WORK_DIR}/nginx.conf" 2>/dev/null; then
      nginx -s reload -c ${WORK_DIR}/nginx.conf 2>/dev/null || true
    else
      nginx_run
    fi
  else
    nginx_stop
  fi
}

# 为了适配 alpine，定义 cmd_systemctl 的函数
cmd_systemctl() {

  if [ "$SYSTEM" = 'Alpine' ]; then
    case "$1" in
      enable )
        rc-update add "$2" default >/dev/null 2>&1
        rc-service "$2" start >/dev/null 2>&1
        ;;
      disable )
        rc-service "$2" stop >/dev/null 2>&1
        rc-update del "$2" default >/dev/null 2>&1
        ;;
      restart )
        rc-service "$2" restart >/dev/null 2>&1
        ;;
      reload )
        rc-service "$2" reload >/dev/null 2>&1 || rc-service "$2" restart >/dev/null 2>&1
        [ -s ${WORK_DIR}/nginx.conf ] && nginx_sync
        local MAINPID=$(cat /var/run/sing-box.pid 2>/dev/null)
        [ -n "$MAINPID" ] && info "\n $(text 95) \n"
        ;;
      status )
        rc-service "$2" status
        ;;
    esac
  else
    systemctl daemon-reload
    case "$1" in
      enable | disable )
        systemctl "$1" --now "$2" >/dev/null 2>&1
        ;;
      restart )
        systemctl restart "$2" >/dev/null 2>&1
        ;;
      reload )
        systemctl reload sing-box >/dev/null 2>&1 || systemctl restart sing-box >/dev/null 2>&1
        [ -s ${WORK_DIR}/nginx.conf ] && nginx_sync
        local MAINPID=$(systemctl show -p MainPID sing-box 2>/dev/null | awk -F= '{print $2}')
        [ -n "$MAINPID" ] && [ "$MAINPID" -gt 0 ] 2>/dev/null && info "\n $(text 95) \n"
        ;;
      status )
        systemctl is-active "$2"
        ;;
      * )
        systemctl "$@" >/dev/null 2>&1
        ;;
    esac
  fi
}

check_system_info() {
  [ -s /etc/os-release ] && SYS="$(awk -F '"' 'tolower($0) ~ /pretty_name/{print $2}' /etc/os-release)"
  [ -s /etc/os-release ] && OS_ID="$(awk -F '=' 'tolower($1) == "id" {gsub(/"/, "", $2); print tolower($2)}' /etc/os-release)"
  [ -s /etc/os-release ] && OS_LIKE="$(awk -F '=' 'tolower($1) == "id_like" {gsub(/"/, "", $2); print tolower($2)}' /etc/os-release)"
  [[ -z "$SYS" ]] && command -v hostnamectl >/dev/null 2>&1 && SYS="$(hostnamectl | awk -F ': ' 'tolower($0) ~ /operating system/{print $2}')"
  [[ -z "$SYS" ]] && command -v lsb_release >/dev/null 2>&1 && SYS="$(lsb_release -sd)"
  [[ -z "$SYS" && -s /etc/lsb-release ]] && SYS="$(awk -F '"' 'tolower($0) ~ /distrib_description/{print $2}' /etc/lsb-release)"
  [[ -z "$SYS" && -s /etc/redhat-release ]] && SYS="$(cat /etc/redhat-release)"
  [[ -z "$SYS" && -s /etc/issue ]] && SYS="$(sed -E '/^$|^\\/d' /etc/issue | awk -F '\\' '{print $1}' | sed 's/[ ]*$//g')"

  REGEX=("debian" "ubuntu" "centos|red hat|kernel|alma|rocky" "arch linux" "alpine" "fedora")
  RELEASE=("Debian" "Ubuntu" "CentOS" "Arch" "Alpine" "Fedora")
  EXCLUDE=("")
  MAJOR=("9" "16" "7" "3" "" "37")
  PACKAGE_UPDATE=("apt -y update" "apt -y update" "yum -y update --skip-broken" "pacman -Sy" "apk update -f" "dnf -y update")
  PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "pacman -S --noconfirm" "apk add --no-cache" "dnf -y install")
  PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "yum -y autoremove" "pacman -Rcnsu --noconfirm" "apk del -f" "dnf -y autoremove")

  if [ "$OS_ID" = 'armbian' ]; then
    if [[ "$OS_LIKE" =~ ubuntu ]]; then
      SYSTEM='Ubuntu'
      int=1
    else
      SYSTEM='Debian'
      int=0
    fi
    SYS="${SYS:-Armbian}"
  else
    for int in "${!REGEX[@]}"; do
      [[ "${SYS,,}" =~ ${REGEX[int]} ]] && SYSTEM="${RELEASE[int]}" && break
    done
  fi

  # 针对各厂商的订制系统
  if [ -z "$SYSTEM" ]; then
    command -v yum >/dev/null 2>&1 && int=2 && SYSTEM='CentOS' || error " $(text 5) "
  fi

  # 先排除 EXCLUDE 里包括的特定系统，其他系统需要作大发行版本的比较
  for ex in "${EXCLUDE[@]}"; do [[ ! "{$SYS,,}"  =~ $ex ]]; done &&
  [[ "$(sed -E 's/[^0-9.]//g; s/\..*//' <<< "$SYS")" -lt "${MAJOR[int]}" ]] && error " $(text 6) "

  # 针对部分系统作特殊处理，CentOS7 使用 yum，以上使用 dnf
  ARGO_DAEMON_FILE='/etc/systemd/system/argo.service'; SINGBOX_DAEMON_FILE='/etc/systemd/system/sing-box.service'
  if [ "$SYSTEM" = 'CentOS' ]; then
    IS_CENTOS="CentOS$(sed -E 's/[^0-9.]//g; s/\..*//' <<< "$SYS")"
    [ "$IS_CENTOS" != 'CentOS7' ] && int=5
  elif [ "$SYSTEM" = 'Alpine' ]; then
    ARGO_DAEMON_FILE='/etc/init.d/argo'; SINGBOX_DAEMON_FILE='/etc/init.d/sing-box'
  fi

  # 判断虚拟化
  if [ "$SYSTEM" = 'Alpine' ]; then
    command -v virt-what >/dev/null 2>&1 || ${PACKAGE_INSTALL[int]} virt-what >/dev/null 2>&1
    command -v virt-what >/dev/null 2>&1 && VIRT=$(virt-what | sed -n 1p) || VIRT=unknown
  elif command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT=$(systemd-detect-virt)
  elif command -v hostnamectl >/dev/null 2>&1; then
    VIRT=$(hostnamectl | awk '/Virtualization/{print $NF}')
  elif grep -qa container= /proc/1/environ 2>/dev/null; then
    VIRT=$(tr '\0' '\n' </proc/1/environ | awk -F= '/container=/{print $2; exit}')
  elif grep -Eq '(lxc|docker|kubepods|containerd)' /proc/1/cgroup 2>/dev/null; then
    VIRT=$(grep -Eo '(lxc|docker|kubepods|containerd)' /proc/1/cgroup | sed -n 1p)
  else
    VIRT=unknown
  fi

  # 判断是否支持 TUN（无 TUN 的 Hax / OpenVZ / 部分 LXC、Docker 容器无法创建 wireguard 出站，
  # 需跳过 WARP 相关功能，避免 sing-box 启动失败）
  if [ -c /dev/net/tun ] || cat /dev/net/tun 2>&1 | grep -q "in bad state\|处于错误状态"; then
    IS_TUN='is_tun'
  else
    IS_TUN='no_tun'
  fi
}

# 获取 sing-box 最新版本
get_sing_box_version() {
  # FORCE_VERSION 用于在 sing-box 某个主程序出现 bug 时，强制为指定版本，以防止运行出错
  local FORCE_VERSION=$(wget --no-check-certificate --tries=2 --timeout=3 -qO- ${GH_PROXY}${PROJECT_FORCE_VERSION_URL} | sed 's/^[vV]//g; s/\r//g')
  if grep -q '.' <<< "$FORCE_VERSION"; then
    local RESULT_VERSION="$FORCE_VERSION"
  else
    # 先判断 github api 返回 http 状态码是否为 200，有时候 IP 会被限制，导致获取不到最新版本
    local API_RESPONSE=$(wget --no-check-certificate --server-response --tries=2 --timeout=3 -qO- "${GH_PROXY}${PROJECT_SING_BOX_API}" 2>&1 | grep -E '^[ ]+HTTP/|tag_name')
    if grep -q 'HTTP.* 200' <<< "$API_RESPONSE"; then
      # 只接受形如 x.y.z 的语义化版本标签，忽略脚本自身等非版本标签（如 easysb）
      local VERSION_LATEST=$(awk -F '["v-]' '/tag_name/{print $5}' <<< "$API_RESPONSE" | grep -E '^[0-9]' | sort -Vr | sed -n '1p')
      local RESULT_VERSION=$(awk -F '["v]' -v var="tag_name.*$VERSION_LATEST" '$0 ~ var {print $5; exit}' <<< "$API_RESPONSE")
    else
      local RESULT_VERSION="$DEFAULT_NEWEST_VERSION"
    fi
  fi
  echo "$RESULT_VERSION"
}

