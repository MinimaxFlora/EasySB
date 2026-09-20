#!/usr/bin/env bash
# 静态检查测试 / Static analysis test
# 校验产物中的项目地址、协议清单、函数定义等静态特征

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EASYSB_DIR="$(dirname "$TESTS_DIR")"
DIST_SCRIPT="${EASYSB_DIR}/dist/easysb.sh"

. "${TESTS_DIR}/helpers.sh"

assert_file "产物存在" "$DIST_SCRIPT"

# 项目地址必须指向本仓库，而不是上游脚本仓库
assert_grep "项目常量 PROJECT_REPO" "^PROJECT_REPO='MinimaxFlora/EasySB'$" "$DIST_SCRIPT"
assert_grep "脚本发行地址" '^PROJECT_SCRIPT_URL=.*/download/easysb/easysb\.sh"$' "$DIST_SCRIPT"
assert_grep "内核下载指向本仓库" 'PROJECT_SING_BOX_RELEASE}/download/v\$ONLINE' "$DIST_SCRIPT"
assert_grep "强制版本文件指向本仓库" 'PROJECT_RAW}/EasySB/force_version' "$DIST_SCRIPT"

# 上游脚本仓库的下载与反馈地址不应残留
assert_no_grep "无上游脚本下载地址" 'raw\.githubusercontent\.com/fscarmen/sing-box' "$DIST_SCRIPT"
assert_no_grep "无上游反馈地址" 'github\.com/fscarmen/sing-box/issues' "$DIST_SCRIPT"
assert_no_grep "无上游统计接口" 'stat\.cloudflare\.now\.cc' "$DIST_SCRIPT"
assert_no_grep "无上游内核下载地址" 'SagerNet/sing-box/releases/download' "$DIST_SCRIPT"

# 参考项目声明必须保留
assert_grep "保留参考项目声明" 'github\.com/fscarmen/sing-box' "$DIST_SCRIPT"
assert_grep "保留 EasySB 项目地址" 'github\.com/MinimaxFlora/EasySB' "$DIST_SCRIPT"

# 订阅模板取自本仓库 Templates/，守护进程内核只使用正式版
assert_grep "订阅模板指向本仓库" '^SUBSCRIBE_TEMPLATE="\$\{PROJECT_RAW\}/Templates"$' "$DIST_SCRIPT"
assert_grep "订阅模板 config.yaml" 'SUBSCRIBE_TEMPLATE}/config\.yaml' "$DIST_SCRIPT"
assert_grep "订阅模板 config-rule.yaml" 'SUBSCRIBE_TEMPLATE}/config-rule\.yaml' "$DIST_SCRIPT"
assert_grep "订阅模板 config.json" 'SUBSCRIBE_TEMPLATE}/config\.json' "$DIST_SCRIPT"
assert_no_grep "无上游订阅模板地址" 'fscarmen/client_template/main/(clash|clash2|sing-box)' "$DIST_SCRIPT"
assert_no_grep "内核兜底版本非预发布" "^DEFAULT_NEWEST_VERSION='[0-9.]+-(alpha|beta|rc)" "$DIST_SCRIPT"
assert_grep "内核版本过滤预发布标签" "grep -E '\^\[0-9\]\+" "$DIST_SCRIPT"
assert_grep "保留 clash2 订阅生成" 'WORK_DIR}/subscribe/clash2' "$DIST_SCRIPT"

# 12 个协议全部保留
assert_eq "协议数量" \
  "$(grep -m1 '^PROTOCOL_LIST=' "$DIST_SCRIPT" | grep -oE '"[^"]+"' | wc -l)" "12"
for PROTO in 'XTLS + reality' 'hysteria2' 'tuic' 'ShadowTLS' 'shadowsocks' 'trojan' \
             'vmess + ws' 'vless + ws + tls' 'H2 + reality' 'gRPC + reality' 'AnyTLS' 'naive'; do
  assert_grep "协议存在: ${PROTO}" "\"${PROTO//+/\\+}\"" "$DIST_SCRIPT"
done

# 菜单项与命令行入口完整
assert_grep "菜单 setting 入口" '^menu_setting\(\) \{' "$DIST_SCRIPT"
assert_grep "交互菜单入口" '^menu\(\) \{' "$DIST_SCRIPT"
for OPT in 0 1 2 3 4 5 6 7 8 9 10 11 12; do
  assert_grep "菜单动作 ACTION[${OPT}]" "ACTION\[${OPT}\]" "$DIST_SCRIPT"
done

# 顶层函数不得重复定义（heredoc 内的同名片段需排除）
DUPLICATED="$(awk '
  { if (inhd) { if ($0 == delim) inhd = 0; next }
    if (match($0, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
      s = substr($0, RSTART, RLENGTH); gsub(/<<-?|[ \t]|["\047]/, "", s)
      delim = s; inhd = 1; next }
    if (match($0, /^[A-Za-z_][A-Za-z0-9_-]*\(\)/)) print substr($0, RSTART, RLENGTH)
  }' "$DIST_SCRIPT" | sort | uniq -d | tr '\n' ' ')"
assert_eq "无重复顶层函数" "$DUPLICATED" ""

# 语法校验
assert_true "产物 bash -n 通过" bash -n "$DIST_SCRIPT"

finish_tests "test-static"
