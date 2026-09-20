# ------------------------------------------------------------------------------
# 六、交互输入与校验 / Interactive input and validation
# ------------------------------------------------------------------------------
# 输入优选 CDN
input_cdn() {
  echo ""
  unset CUSTOM_CDN PARSED_HOST PARSED_PORT
  for c in "${!CDN_DOMAIN[@]}"; do
    hint " $(( c+1 )). ${CDN_DOMAIN[c]} "
  done

  while true; do
    reading "\n ${TOTAL_STEPS:+(${STEP_NUM}/${TOTAL_STEPS}) }$(text 53) " CUSTOM_CDN
    case "$CUSTOM_CDN" in
      [1-${#CDN_DOMAIN[@]}] )
        CDN="${CDN_DOMAIN[$((CUSTOM_CDN-1))]}"
        CDN_PORT[17]='80' && CDN_PORT[18]='443'
        break
        ;;
      ?????* )
        parse_host_port "$CUSTOM_CDN" '' || {
          warning "\n $(text 36) \n"
          continue
        }
        CDN="$PARSED_HOST"
        if grep -q '.' <<< $PARSED_PORT; then
          CDN_PORT[17]=$PARSED_PORT && CDN_PORT[18]=$PARSED_PORT
        else
          CDN_PORT[17]='80' && CDN_PORT[18]='443'
        fi
        break
        ;;
      * )
        CDN="${CDN_DOMAIN[0]}"
        CDN_PORT[17]='80' && CDN_PORT[18]='443'
        break
    esac
  done
}

# 输入 UUID
input_uuid() {
  # 输入 UUID ，错误超过 5 次将会退出
  local UUID_DEFAULT=$(cat /proc/sys/kernel/random/uuid)
  [[ "$IS_FAST_INSTALL" = 'is_fast_install' || "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]] && UUID_CONFIRM=${UUID_CONFIRM:-"$UUID_DEFAULT"}
  if [ -z "$UUID_CONFIRM" ]; then
    (( STEP_NUM++ )) || true
    reading "\n ${TOTAL_STEPS:+(${STEP_NUM}/${TOTAL_STEPS}) }$(text 12) " UUID_CONFIRM
  fi
  local UUID_ERROR_TIME=5
  until [[ -z "$UUID_CONFIRM" || "${UUID_CONFIRM,,}" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; do
    (( UUID_ERROR_TIME-- )) || true
    [ "$UUID_ERROR_TIME" = 0 ] && error "\n $(text 3) \n" || reading "\n $(text 4) " UUID_CONFIRM
  done
  UUID_CONFIRM=${UUID_CONFIRM:-"$UUID_DEFAULT"}
}

input_node_name() {
  # 输入节点名，以系统的 hostname 作为默认（新安装 / 无既有协议重新添加时询问）
  local NODE_NAME_INPUT=''
  if [ -z "$NODE_NAME_CONFIRM" ]; then
    local EMOJI="${EMOJI4:-$EMOJI6}"
    local EMOJI="${EMOJI}${EMOJI:+ }"
    if command -v hostname >/dev/null 2>&1; then
      local NODE_NAME_DEFAULT="${EMOJI}$(hostname)"
    elif [ -s /etc/hostname ]; then
      local NODE_NAME_DEFAULT="${EMOJI}$(cat /etc/hostname)"
    else
      local NODE_NAME_DEFAULT="${EMOJI}Sing-Box"
    fi
    [[ "$IS_FAST_INSTALL" = 'is_fast_install' || "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]] && NODE_NAME_CONFIRM="${NODE_NAME_DEFAULT}"
    if [ -z "$NODE_NAME_CONFIRM" ]; then
      (( STEP_NUM++ )) || true
      reading "\n ${TOTAL_STEPS:+(${STEP_NUM}/${TOTAL_STEPS}) }$(text 13) " NODE_NAME_INPUT
    fi
    grep -q '^$' <<< "$NODE_NAME_INPUT" && NODE_NAME_CONFIRM="$NODE_NAME_DEFAULT" || NODE_NAME_CONFIRM="${EMOJI}${NODE_NAME_INPUT}"
  fi
}

