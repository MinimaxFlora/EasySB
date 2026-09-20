# ------------------------------------------------------------------------------
# 九、自定义路由规则 / Custom routing rules
# ------------------------------------------------------------------------------

# 统计自定义路由规则数量（按数组里的单项统计，不按整条 route rule 统计）
custom_route_count() {
  local CUSTOM_FILE="${WORK_DIR}/conf/08_custom_route.json"
  if [ -s "$CUSTOM_FILE" ]; then
    jq_exec '[.route.rules[]? | ((.domain_suffix // []) | length) + ((.rule_set // []) | length)] | add // 0' "$CUSTOM_FILE" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# 将 warp-ep 的 domain_suffix / rule_set 合并到同一条 route rule，保持 08_custom_route.json 更简洁
custom_route_compact_rules() {
  local CUSTOM_FILE="${WORK_DIR}/conf/08_custom_route.json"
  local TMP_FILE="${CUSTOM_FILE}.tmp"
  [ ! -s "$CUSTOM_FILE" ] && return

  jq_exec '
    (.route.rules // []) as $rules |
    ($rules | map(select((.outbound // "warp-ep") == "warp-ep") | .domain_suffix // []) | add // [] | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)) as $domains |
    ($rules | map(select((.outbound // "warp-ep") == "warp-ep") | .rule_set // []) | add // [] | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)) as $sets |
    ($rules | map(select((.outbound // "warp-ep") != "warp-ep"))) as $others |
    .route.rules = (
      $others +
      (if (($domains | length) + ($sets | length)) > 0 then
        [((if ($sets | length) > 0 then {rule_set:$sets} else {} end)
          + (if ($domains | length) > 0 then {domain_suffix:$domains} else {} end)
          + {action:"route", outbound:"warp-ep"})]
      else [] end)
    )
  ' "$CUSTOM_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$CUSTOM_FILE"
}

# 通过 GitHub API 校验 rule_set 是否存在，返回下载 URL
# 参数: $1 = rule_set 名称（不含 .srs）
# 输出: 下载 URL 或空字符串
check_rule_set_exists() {
  local NAME="$1"
  local SRS_NAME="${NAME}.srs"
  local CACHE_DIR="${TEMP_DIR}/ruleset_cache"
  mkdir -p "$CACHE_DIR"

  # SagerNet 源
  local SAGERNET_CACHE="${CACHE_DIR}/sagernet_tree.json"
  if [ ! -s "$SAGERNET_CACHE" ]; then
    curl -sL --connect-timeout 5 --max-time 15 "https://api.github.com/repos/SagerNet/sing-geosite/git/trees/rule-set?recursive=1" > "$SAGERNET_CACHE" 2>/dev/null || true
  fi

  if [ -s "$SAGERNET_CACHE" ] && jq_exec -e ".tree[]? | select(.path == \"${SRS_NAME}\")" "$SAGERNET_CACHE" >/dev/null 2>&1; then
    echo "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/${SRS_NAME}"
    return 0
  fi

  # MetaCubeX 源
  local METACUBEX_CACHE="${CACHE_DIR}/metacubex_tree.json"
  if [ ! -s "$METACUBEX_CACHE" ]; then
    curl -sL --connect-timeout 5 --max-time 15 "https://api.github.com/repos/MetaCubeX/meta-rules-dat/git/trees/sing?recursive=1" > "$METACUBEX_CACHE" 2>/dev/null || true
  fi

  if [ -s "$METACUBEX_CACHE" ]; then
    local MATCH_PATH
    MATCH_PATH=$(jq_exec -r "[.tree[]? | select(.path | endswith(\"/${SRS_NAME}\") or . == \"${SRS_NAME}\") | .path] | first // empty" "$METACUBEX_CACHE" 2>/dev/null)
    if [ -n "$MATCH_PATH" ]; then
      echo "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/${MATCH_PATH}"
      return 0
    fi
  fi

  # 两处 API 都没数据（可能是 rate limit 或网络问题）
  if [ ! -s "$SAGERNET_CACHE" ] && [ ! -s "$METACUBEX_CACHE" ]; then
    # API 不可用，降级使用默认 URL
    warning " $(text 14) "
    echo "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/${SRS_NAME}"
    return 0
  fi

  # 确实在两处都没找到
  return 1
}

# 添加自定义路由规则
custom_route_add() {
  local CUSTOM_FILE="${WORK_DIR}/conf/08_custom_route.json"

  # 选择规则类型
  hint "\n $(text 152) "
  reading " $(text 24) " RULE_TYPE_CHOICE
  case "$RULE_TYPE_CHOICE" in
    1 ) local RULE_TYPE="domain_suffix" ;;
    2 ) local RULE_TYPE="rule_set" ;;
    * ) info " $(text 135) " && return ;;
  esac

  local VALIDATED_VALUES=()
  local RULE_SET_URLS=()

  if [ "$RULE_TYPE" = "domain_suffix" ]; then
    reading " $(text 153) " DOMAIN_INPUT
    [ -z "$DOMAIN_INPUT" ] && info " $(text 135) " && return

    local DOMAINS=()
    custom_route_csv_to_array "$DOMAIN_INPUT" DOMAINS
    local DOMAIN
    for DOMAIN in "${DOMAINS[@]}"; do
      DOMAIN=$(sed 's/。/./g' <<< "${DOMAIN,,}")
      if [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]]; then
        VALIDATED_VALUES+=("$DOMAIN")
      else
        warning " $(text 149) "
      fi
    done
    [ "${#VALIDATED_VALUES[@]}" -eq 0 ] && warning " $(text 135) " && return

  elif [ "$RULE_TYPE" = "rule_set" ]; then
    # 输入规则集名称
    hint "\n $(text 73) \n"
    reading " $(text 154) " RULESET_INPUT
    [ -z "$RULESET_INPUT" ] && info " $(text 135) " && return

    local RULESETS=()
    custom_route_csv_to_array "$RULESET_INPUT" RULESETS

    local RULE_NAME RETRY URL
    for RULE_NAME in "${RULESETS[@]}"; do
      RULE_NAME="${RULE_NAME,,}"
      RULE_NAME=$(sed -E 's#^.*/##; s/\.srs$//I' <<< "$RULE_NAME")
      [[ -n "$RULE_NAME" && ! "$RULE_NAME" =~ ^geo(site|ip)- ]] && RULE_NAME="geosite-${RULE_NAME}"
      [ -z "$RULE_NAME" ] && continue

      RETRY=3
      URL=""
      while [ $RETRY -gt 0 ]; do
        URL=$(check_rule_set_exists "$RULE_NAME")
        if [ -n "$URL" ]; then
          VALIDATED_VALUES+=("$RULE_NAME")
          RULE_SET_URLS+=("$URL")
          break
        else
          ((RETRY--))
          if [ $RETRY -gt 0 ]; then
            warning " $(text 156) "
            reading " " RULE_NAME
            RULE_NAME="${RULE_NAME,,}"
            RULE_NAME=$(sed -E 's#^.*/##; s/\.srs$//I' <<< "$RULE_NAME")
            [[ -n "$RULE_NAME" && ! "$RULE_NAME" =~ ^geo(site|ip)- ]] && RULE_NAME="geosite-${RULE_NAME}"
          else
            warning " $(text 156) "
          fi
        fi
      done
    done
    [ "${#VALIDATED_VALUES[@]}" -eq 0 ] && warning " $(text 135) " && return
  fi

  # 自定义路由固定使用 warp-ep 出站
  local OUTBOUND="warp-ep"
  hint " $(text 155) "

  # 初始化 JSON 文件（如果不存在）
  if [ ! -s "$CUSTOM_FILE" ]; then
    echo '{"route":{"rule_set":[],"rules":[]}}' | jq_exec '.' > "$CUSTOM_FILE"
  fi

  local TMP_FILE="${CUSTOM_FILE}.tmp"

  if [ "$RULE_TYPE" = "domain_suffix" ]; then
    # 构建 domain_suffix 数组 JSON，先对输入本身去重
    local DOMAINS_JSON
    DOMAINS_JSON=$(printf '%s\n' "${VALIDATED_VALUES[@]}" | jq_exec -R . | jq_exec -s 'reduce .[] as $x ([]; if index($x) then . else . + [$x] end)')

    # 合并到同一条 warp-ep route rule；rule_set 和 domain_suffix 共用一条规则
    jq_exec --argjson domains "$DOMAINS_JSON" --arg out "$OUTBOUND" '
      .route.rules = (.route.rules // []) |
      (.route.rules | map(select((.outbound // $out) == $out) | .domain_suffix // []) | add // []) as $old_domains |
      (.route.rules | map(select((.outbound // $out) == $out) | .rule_set // []) | add // []) as $old_sets |
      (.route.rules | map(select((.outbound // $out) != $out))) as $others |
      (($old_domains + $domains) | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)) as $new_domains |
      ($old_sets | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)) as $new_sets |
      .route.rules = (
        $others +
        (if (($new_domains | length) + ($new_sets | length)) > 0 then
          [((if ($new_sets | length) > 0 then {rule_set:$new_sets} else {} end)
            + (if ($new_domains | length) > 0 then {domain_suffix:$new_domains} else {} end)
            + {action:"route", outbound:$out})]
        else [] end)
      )
    ' "$CUSTOM_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$CUSTOM_FILE"

  elif [ "$RULE_TYPE" = "rule_set" ]; then
    # 添加 rule_set 定义到 route.rule_set（去重）
    for i in "${!VALIDATED_VALUES[@]}"; do
      local RS_NAME="${VALIDATED_VALUES[$i]}"
      local RS_URL="${RULE_SET_URLS[$i]}"

      jq_exec --arg tag "$RS_NAME" --arg url "$RS_URL" '
        .route.rule_set = (.route.rule_set // []) |
        .route.rule_set |= (
          if any(.[]; .tag == $tag) then .
          else . + [{"tag": $tag, "type": "remote", "format": "binary", "url": $url}]
          end
        )
      ' "$CUSTOM_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$CUSTOM_FILE"
    done

    # 构建 rule_set 名称数组，先对输入本身去重
    local RS_NAMES_JSON
    RS_NAMES_JSON=$(printf '%s\n' "${VALIDATED_VALUES[@]}" | jq_exec -R . | jq_exec -s 'reduce .[] as $x ([]; if index($x) then . else . + [$x] end)')

    # 合并到同一条 warp-ep route rule；rule_set 和 domain_suffix 共用一条规则
    jq_exec --argjson names "$RS_NAMES_JSON" --arg out "$OUTBOUND" '
      .route.rules = (.route.rules // []) |
      (.route.rules | map(select((.outbound // $out) == $out) | .domain_suffix // []) | add // []) as $old_domains |
      (.route.rules | map(select((.outbound // $out) == $out) | .rule_set // []) | add // []) as $old_sets |
      (.route.rules | map(select((.outbound // $out) != $out))) as $others |
      ($old_domains | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)) as $new_domains |
      (($old_sets + $names) | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)) as $new_sets |
      .route.rules = (
        $others +
        (if (($new_domains | length) + ($new_sets | length)) > 0 then
          [((if ($new_sets | length) > 0 then {rule_set:$new_sets} else {} end)
            + (if ($new_domains | length) > 0 then {domain_suffix:$new_domains} else {} end)
            + {action:"route", outbound:$out})]
        else [] end)
      )
    ' "$CUSTOM_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$CUSTOM_FILE"
  fi

  custom_route_compact_rules

  info " $(text 157) "
  cmd_systemctl reload sing-box
  sleep 2
  cmd_systemctl status sing-box &>/dev/null && \
    info "\n Sing-box $(text 28) $(text 37) \n" || \
    warning "\n Sing-box $(text 27) $(text 38) \n"
}

# 将逗号分隔输入转为数组：支持半角/全角逗号、顿号、分号、竖线；不使用 IFS
custom_route_csv_to_array() {
  local INPUT_CSV="$1"
  local -n OUT_ARRAY="$2"
  OUT_ARRAY=()

  mapfile -t OUT_ARRAY < <(
    printf '%s\n' "$INPUT_CSV" |
      sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\^\[\[[0-9;?]*[A-Za-z]//g; s/[，、；;|]/,/g; s/[[:space:]]//g; s/,/\n/g; /^$/d'
  )
}

# 输出展开后的自定义路由项，每个 domain_suffix / rule_set 数组元素单独一行
custom_route_items_json() {
  local CUSTOM_FILE="${WORK_DIR}/conf/08_custom_route.json"
  jq_exec -c '
    [.route.rules[]?] as $rules |
    reduce range(0; ($rules | length)) as $i ([];
      ($rules[$i]) as $r |
      .
      + [($r.rule_set[]? | {rule_index:$i,type:"rule_set",match:.,outbound:($r.outbound // "warp-ep")})]
      + [($r.domain_suffix[]? | {rule_index:$i,type:"domain_suffix",match:.,outbound:($r.outbound // "warp-ep")})]
      + (if (($r.rule_set? == null) and ($r.domain_suffix? == null)) then [{rule_index:$i,type:"unknown",match:"N/A",outbound:($r.outbound // "warp-ep")}] else [] end)
    ) | .[]
  ' "$CUSTOM_FILE" 2>/dev/null
}

# 查看自定义路由规则
custom_route_view() {
  local CUSTOM_FILE="${WORK_DIR}/conf/08_custom_route.json"

  if [ ! -s "$CUSTOM_FILE" ]; then
    hint " $(text 158) "
    return 1
  fi

  local ROUTE_ITEMS=()
  mapfile -t ROUTE_ITEMS < <(custom_route_items_json)

  if [ "${#ROUTE_ITEMS[@]}" -eq 0 ]; then
    hint " $(text 158) "
    return 1
  fi

  hint "\n $(text 45) \n"
  printf "  %-4s %-16s %s\n" "#" "Type" "Match"
  printf "  %-4s %-16s %s\n" "---" "---------------" "---------------------------------------"

  local IDX=0
  local ITEM TYPE MATCH
  for ITEM in "${ROUTE_ITEMS[@]}"; do
    ((IDX++)) || true
    TYPE=$(jq_exec -r '.type' <<< "$ITEM")
    MATCH=$(jq_exec -r '.match' <<< "$ITEM")
    printf "  %-4s %-16s %s\n" "$IDX" "$TYPE" "$MATCH"
  done

  echo ""
  return 0
}

# 删除自定义路由规则：按展开后的单项编号删除，支持删除数组里的某个元素
custom_route_delete() {
  local CUSTOM_FILE="${WORK_DIR}/conf/08_custom_route.json"

  custom_route_view || return

  local ROUTE_ITEMS=()
  mapfile -t ROUTE_ITEMS < <(custom_route_items_json)
  [ "${#ROUTE_ITEMS[@]}" -eq 0 ] && info " $(text 135) " && return

  reading " $(text 159) " DELETE_INPUT
  [ -z "$DELETE_INPUT" ] && info " $(text 135) " && return

  local DELETE_NUMS=()
  custom_route_csv_to_array "$DELETE_INPUT" DELETE_NUMS

  local DELETE_ITEM_LINES=()
  local NUM
  for NUM in "${DELETE_NUMS[@]}"; do
    NUM=$(sed 's/[^0-9]//g' <<< "$NUM")
    if [[ "$NUM" =~ ^[0-9]+$ ]] && [ "$NUM" -ge 1 ] && [ "$NUM" -le "${#ROUTE_ITEMS[@]}" ]; then
      DELETE_ITEM_LINES+=("${ROUTE_ITEMS[$((NUM - 1))]}")
    fi
  done

  [ "${#DELETE_ITEM_LINES[@]}" -eq 0 ] && info " $(text 135) " && return

  local DELETE_ITEMS_JSON TMP_FILE
  DELETE_ITEMS_JSON=$(printf '%s\n' "${DELETE_ITEM_LINES[@]}" | jq_exec -s 'unique_by(.rule_index, .type, .match)')
  TMP_FILE="${CUSTOM_FILE}.tmp"

  # 只删除被选中的数组元素；数组清空后才删除整条 route rule
  jq_exec --argjson del "$DELETE_ITEMS_JSON" '
    .route.rules |= (
      [.[]?] as $rules |
      reduce range(0; ($rules | length)) as $idx ([];
        ($rules[$idx]) as $rule |
        ($del | map(select(.rule_index == $idx and .type == "domain_suffix") | .match)) as $remove_domains |
        ($del | map(select(.rule_index == $idx and .type == "rule_set") | .match)) as $remove_sets |
        ($rule
          | if .domain_suffix? != null then .domain_suffix = ([.domain_suffix[]? as $v | select(($remove_domains | index($v)) | not) | $v]) else . end
          | if .rule_set? != null then .rule_set = ([.rule_set[]? as $v | select(($remove_sets | index($v)) | not) | $v]) else . end
          | if ((.domain_suffix // []) | length) == 0 then del(.domain_suffix) else . end
          | if ((.rule_set // []) | length) == 0 then del(.rule_set) else . end
        ) as $new_rule |
        if (($new_rule.domain_suffix? != null) or ($new_rule.rule_set? != null)) then
          . + [$new_rule]
        elif ($del | any(.rule_index == $idx and .type == "unknown")) then
          .
        else
          . + [$new_rule]
        end
      )
    )
  ' "$CUSTOM_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$CUSTOM_FILE"

  custom_route_compact_rules

  # 清理孤立的 rule_set 定义：只保留仍被 rules 引用的 rule_set
  jq_exec '
    (.route.rules | [.[]? | .rule_set // [] | .[]] | unique) as $used |
    .route.rule_set |= [.[]? | select(.tag as $t | $used | index($t) | not | not)]
  ' "$CUSTOM_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$CUSTOM_FILE"

  # 如果没有任何规则了，删除文件
  local REMAINING
  REMAINING=$(jq_exec '.route.rules | length' "$CUSTOM_FILE" 2>/dev/null)
  if [ "${REMAINING:-0}" -eq 0 ]; then
    rm -f "$CUSTOM_FILE"
  fi

  info " $(text 160) "
  cmd_systemctl reload sing-box
  sleep 2
  cmd_systemctl status sing-box &>/dev/null && \
    info "\n Sing-box $(text 28) $(text 37) \n" || \
    warning "\n Sing-box $(text 27) $(text 38) \n"
}

# 自定义路由规则子菜单
custom_route_menu() {
  while true; do
    CUSTOM_ROUTE_COUNT=$(custom_route_count)
    hint "\n $(text 150) \n"
    hint " $(text 151) "
    hint ""
    reading " $(text 24) " CUSTOM_ROUTE_CHOICE

    case "$CUSTOM_ROUTE_CHOICE" in
      1 ) custom_route_add ;;
      2 ) custom_route_view ;;
      3 ) custom_route_delete ;;
      0 ) return ;;
      * ) info " $(text 135) " && return ;;
    esac
  done
}

# ===================== 自定义路由规则 END =====================

