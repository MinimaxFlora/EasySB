# ------------------------------------------------------------------------------
# 五、网络与运行环境探测 / Network and runtime detection
# ------------------------------------------------------------------------------
# 检测是否需要启用 Github CDN，raw 与 releases 两个下载域都直连可达才不使用
check_cdn() {
  local PROXY CODE PID CMD _url P1 P2 CODE_RAW CODE_REL
  local PIDS=()
  # 探测点1：raw 域（脚本及订阅模板文件下载路径）
  local RAW_URL="${PROJECT_FORCE_VERSION_URL}"
  # 探测点2：github releases 域（sing-box / jq / cloudflared 等二进制真实下载路径，
  # latest 指向永远有效）。修复 IPv6-only / 部分封锁场景：raw 域可达 ≠ releases 域可达，任一域失败都必须走代理
  local REL_URL='https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64'

  # 确定下载工具：优先 wget，次选 curl
  if command -v wget >/dev/null 2>&1; then
    CMD='wget'
  elif command -v curl >/dev/null 2>&1; then
    CMD='curl'
  else
    GH_PROXY=''
    return
  fi

  # 获取 HTTP 状态码（HEAD 探测：只取响应头，不下载 body；--tries=1 避免被墙时 wget 默认 20 次重试放大延迟）
  get_code() {
    local url=$1
    if [ "$CMD" = 'wget' ]; then
      wget -q --spider --tries=1 -T5 -O /dev/null --server-response "$url" 2>&1 | awk '/HTTP\//{code=$2} END{print code}'
    else
      curl -skL -I --connect-timeout 3 --max-time 5 -o /dev/null -w '%{http_code}' "$url"
    fi
  }

  # 直连检测：raw 与 releases 两个下载域并行 HEAD 探测，必须全部可达才可直连
  get_code "$RAW_URL" > "${TEMP_DIR}/cdn_raw" &
  P1=$!
  get_code "$REL_URL" > "${TEMP_DIR}/cdn_rel" &
  P2=$!
  wait "$P1" "$P2" 2>/dev/null
  CODE_RAW=$(cat "${TEMP_DIR}/cdn_raw" 2>/dev/null)
  CODE_REL=$(cat "${TEMP_DIR}/cdn_rel" 2>/dev/null)
  rm -f "${TEMP_DIR}/cdn_raw" "${TEMP_DIR}/cdn_rel"
  if [ "$CODE_RAW" = '200' ] && [ "$CODE_REL" = '200' ]; then
    GH_PROXY=''
    return
  fi

  # 直连失败 → 并发探测代理镜像（对两个下载域都要求可达，与直连判定标准一致）
  for PROXY in "${GITHUB_PROXY[@]}"; do
    {
      # 两个下载域都经代理可达才认定该镜像可用（Bash 异步子壳中不能用 return，用短路逻辑）
      for _url in "$RAW_URL" "$REL_URL"; do
        CODE=$(get_code "${PROXY}${_url}")
        [ "$CODE" = '200' ] || { CODE=; break; }
      done
      [ "$CODE" = '200' ] && [ ! -e "${TEMP_DIR}/cdn_proxy" ] && printf '%s' "$PROXY" > "${TEMP_DIR}/cdn_proxy"
    } &
    PIDS+=("$!")
  done

  # wait -n 等首个返回 200 的代理（Bash 4.3+），老版本兜底 sleep 1，避免无限等待卡死
  [ "${#PIDS[@]}" -gt 0 ] && { wait -n 2>/dev/null || sleep 1; }

  [ -e "${TEMP_DIR}/cdn_proxy" ] && GH_PROXY=$(cat "${TEMP_DIR}/cdn_proxy") || GH_PROXY=''

  # 清理后台任务和临时文件
  for PID in "${PIDS[@]}"; do kill "$PID" >/dev/null 2>&1 || true; done
  for PID in "${PIDS[@]}"; do wait "$PID" 2>/dev/null || true; done
  rm -f "${TEMP_DIR}/cdn_proxy"
}

# 检测是否解锁 chatGPT，以决定是否使用 warp 链式代理或者是 direct out，此处判断改编自 https://github.com/lmc999/RegionRestrictionCheck
check_chatgpt() {
  local CHECK_STACK=$1
  local UA_BROWSER="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
  local UA_SEC_CH_UA='"Google Chrome";v="125", "Chromium";v="125", "Not.A/Brand";v="24"'
  wget --help | grep -q '\-\-ciphers' && local IS_CIPHERS=is_ciphers

  # 首先检查API访问
  local CHECK_RESULT1=$(wget --timeout=2 --tries=2 --retry-connrefused --waitretry=5 ${CHECK_STACK} -qO- --content-on-error --header='authority: api.openai.com' --header='accept: */*' --header='accept-language: en-US,en;q=0.9' --header='authorization: Bearer null' --header='content-type: application/json' --header='origin: https://platform.openai.com' --header='referer: https://platform.openai.com/' --header="sec-ch-ua: ${UA_SEC_CH_UA}" --header='sec-ch-ua-mobile: ?0' --header='sec-ch-ua-platform: "Windows"' --header='sec-fetch-dest: empty' --header='sec-fetch-mode: cors' --header='sec-fetch-site: same-site' --user-agent="${UA_BROWSER}" 'https://api.openai.com/compliance/cookie_requirements')

  [ -z "$CHECK_RESULT1" ] && grep -qw is_ciphers <<< "$IS_CIPHERS" && local CHECK_RESULT1=$(wget --timeout=2 --tries=2 --retry-connrefused --waitretry=5 ${CHECK_STACK} --ciphers=DEFAULT@SECLEVEL=1 --no-check-certificate -qO- --content-on-error --header='authority: api.openai.com' --header='accept: */*' --header='accept-language: en-US,en;q=0.9' --header='authorization: Bearer null' --header='content-type: application/json' --header='origin: https://platform.openai.com' --header='referer: https://platform.openai.com/' --header="sec-ch-ua: ${UA_SEC_CH_UA}" --header='sec-ch-ua-mobile: ?0' --header='sec-ch-ua-platform: "Windows"' --header='sec-fetch-dest: empty' --header='sec-fetch-mode: cors' --header='sec-fetch-site: same-site' --user-agent="${UA_BROWSER}" 'https://api.openai.com/compliance/cookie_requirements')

  # 如果API检测失败或者检测到unsupported_country,直接返回ban
  if [ -z "$CHECK_RESULT1" ] || grep -qi 'unsupported_country' <<< "$CHECK_RESULT1"; then
    echo "ban"
    return
  fi

  # API检测通过后,继续检查网页访问
  local CHECK_RESULT2=$(wget --timeout=2 --tries=2 --retry-connrefused --waitretry=5 ${CHECK_STACK} -qO- --content-on-error --header='authority: ios.chat.openai.com' --header='accept: */*;q=0.8,application/signed-exchange;v=b3;q=0.7' --header='accept-language: en-US,en;q=0.9' --header="sec-ch-ua: ${UA_SEC_CH_UA}" --header='sec-ch-ua-mobile: ?0' --header='sec-ch-ua-platform: "Windows"' --header='sec-fetch-dest: document' --header='sec-fetch-mode: navigate' --header='sec-fetch-site: none' --header='sec-fetch-user: ?1' --header='upgrade-insecure-requests: 1' --user-agent="${UA_BROWSER}" https://ios.chat.openai.com/)

  [ -z "$CHECK_RESULT2" ] && grep -qw is_ciphers <<< "$IS_CIPHERS" && local CHECK_RESULT2=$(wget --timeout=2 --tries=2 --retry-connrefused --waitretry=5 ${CHECK_STACK} --ciphers=DEFAULT@SECLEVEL=1 --no-check-certificate -qO- --content-on-error --header='authority: ios.chat.openai.com' --header='accept: */*;q=0.8,application/signed-exchange;v=b3;q=0.7' --header='accept-language: en-US,en;q=0.9' --header="sec-ch-ua: ${UA_SEC_CH_UA}" --header='sec-ch-ua-mobile: ?0' --header='sec-ch-ua-platform: "Windows"' --header='sec-fetch-dest: document' --header='sec-fetch-mode: navigate' --header='sec-fetch-site: none' --header='sec-fetch-user: ?1' --header='upgrade-insecure-requests: 1' --user-agent="${UA_BROWSER}" https://ios.chat.openai.com/)

  # 检查第二个结果
  if [ -z "$CHECK_RESULT2" ] || grep -qi 'VPN' <<< "$CHECK_RESULT2"; then
    echo "ban"
  else
    echo "unlock"
  fi
}

# 脚本当天及累计运行次数统计
statistics_of_run_times() {
  local UPDATE_OR_GET=$1
  local SCRIPT=$2
  # 未配置统计接口时直接跳过：不上报数据，也不显示统计行
  [ -n "$STATISTICS_API" ] || return 0
  if grep -q 'update' <<< "$UPDATE_OR_GET"; then
    { wget --no-check-certificate -qO- --timeout=3 "${STATISTICS_API}?script=${SCRIPT}" > $TEMP_DIR/statistics 2>/dev/null || true; }&
  elif grep -q 'get' <<< "$UPDATE_OR_GET"; then
    [ -s $TEMP_DIR/statistics ] && [[ $(cat $TEMP_DIR/statistics) =~ \"todayCount\":([0-9]+),\"totalCount\":([0-9]+) ]] && local TODAY="${BASH_REMATCH[1]}" && local TOTAL="${BASH_REMATCH[2]}" && rm -f $TEMP_DIR/statistics
    hint "\n *******************************************\n\n $(text 55) \n"
  fi
}

# 选择中英语言
select_language() {
  if [ -z "$L" ]; then
    if [ -s ${WORK_DIR}/language ]; then
      L=$(cat ${WORK_DIR}/language)
    else
      L=E && hint "\n $(text 0) \n" && reading " $(text 24) " LANGUAGE
      [ "$LANGUAGE" = 2 ] && L=C
    fi
  fi
}

# 字母与数字的 ASCII 码值转换
asc() {
  if [[ "$1" = [a-z] ]]; then
    [ "$2" = '++' ] && printf "\\$(printf '%03o' "$(( $(printf "%d" "'$1'") + 1 ))")" || printf "%d" "'$1'"
  else
    [[ "$1" =~ ^[0-9]+$ ]] && printf "\\$(printf '%03o' "$1")"
  fi
}

# 收录一些热心网友和官网的 cdn
parse_host_port() {
  local INPUT_VALUE=$1
  local DEFAULT_PORT=$2
  local HOST_VALUE PORT_VALUE

  INPUT_VALUE=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$INPUT_VALUE")
  [ -z "$INPUT_VALUE" ] && return 1

  if [[ "$INPUT_VALUE" =~ ^\[([^][]+)\]:([0-9]{1,5})$ ]]; then
    HOST_VALUE="${BASH_REMATCH[1]}"
    PORT_VALUE="${BASH_REMATCH[2]}"
  elif [[ "$INPUT_VALUE" =~ ^([^:]+):([0-9]{1,5})$ ]] && [[ "${BASH_REMATCH[1]}" != *:* ]]; then
    HOST_VALUE="${BASH_REMATCH[1]}"
    PORT_VALUE="${BASH_REMATCH[2]}"
  else
    HOST_VALUE="$INPUT_VALUE"
    PORT_VALUE=$DEFAULT_PORT
  fi

  if [[ -n "$PORT_VALUE" && ( ! "$PORT_VALUE" =~ ^[0-9]+$ || "$PORT_VALUE" -lt 1 || "$PORT_VALUE" -gt 65535 ) ]]; then
    return 1
  fi

  PARSED_HOST="$HOST_VALUE"
  PARSED_PORT="$PORT_VALUE"
  return 0
}

format_uri_host() {
  local HOST_VALUE=$1
  if [[ "$HOST_VALUE" == *:* && ! "$HOST_VALUE" =~ ^\[.*\]$ ]]; then
    printf '[%s]' "$HOST_VALUE"
  else
    printf '%s' "$HOST_VALUE"
  fi
}
