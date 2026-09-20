# ------------------------------------------------------------------------------
# 四、基础工具库 / Core utilities（彩色输出、read 封装、文案取值）
# ------------------------------------------------------------------------------
# 自定义字体彩色，read 函数
warning() { echo -e "\033[31m\033[01m$*\033[0m"; }  # 红色
error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; } # 红色
info() { echo -e "\033[32m\033[01m$*\033[0m"; }   # 绿色
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }   # 黄色
reading() { read -rp "$(info "$1")" "$2"; }

# 预处理：扫描 E/C 数组，把含 $ 的条目下标记录到关联数组，避免 text() 每次调用都启动 grep 子进程
declare -A TEXT_NEEDS_EVAL
for TEXT_I in "${!E[@]}"; do
  [[ "${E[${TEXT_I}]}" == *'$'* || "${C[${TEXT_I}]}" == *'$'* ]] && TEXT_NEEDS_EVAL[${TEXT_I}]=1
done
unset TEXT_I

# text <index>：输出当前语言对应的字符串，含 $ 变量的条目用 eval 展开，其余直接 printf
text() {
  local -n TEXT_ARR="${L}"        # nameref 指向 E 或 C，零子进程
  local TEXT_VAL="${TEXT_ARR[$*]}"
  if [[ -n "${TEXT_NEEDS_EVAL[$*]}" ]]; then
    eval "printf '%s' \"${TEXT_VAL}\""
  else
    printf '%s' "${TEXT_VAL}"
  fi
}

# 服务状态匹配正则：把「关闭|开启」组装成可复用的正则，避免在 [[ =~ ]] 内直接拼接
status_on_off_regex() {
  printf '%s|%s' "$(text 27)" "$(text 28)"
}

# 根据 INSTALL_PROTOCOLS 计算安装流程总步骤数
# sing-box 协议分类：Reality 类 (b/j/k)、Hysteria2(c)、WS 类 (h/i)
calc_install_steps() {
  local STEP_TOTAL=5  # 固定步骤：协议选择、起始端口、VPS IP、UUID、节点名
  local HAS_REALITY=false HAS_WS=false HAS_HY2=false
  for PROTO in "${INSTALL_PROTOCOLS[@]}"; do
    [[ "$PROTO" =~ ^[bjk]$ ]] && HAS_REALITY=true
    [[ "$PROTO" =~ ^[hi]$ ]] && HAS_WS=true
    [[ "$PROTO" == 'c' ]] && HAS_HY2=true
  done
  [[ "$IS_SUB" = 'is_sub' || "$IS_ARGO" = 'is_argo' ]] && (( STEP_TOTAL++ ))  # nginx 端口
  $HAS_REALITY && (( STEP_TOTAL++ ))                # Reality 私钥
  $HAS_WS && (( STEP_TOTAL++ ))                     # CDN / 域名
  # Hysteria2 Realm / WARP / Port Hopping are protocol sub-options and are not counted as install steps.
  [ "$IS_ARGO" = 'is_argo' ] && (( STEP_TOTAL++ ))  # Argo 域名
  TOTAL_STEPS=$STEP_TOTAL
}
