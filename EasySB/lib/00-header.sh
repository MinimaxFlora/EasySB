#!/usr/bin/env bash
# ==============================================================================
#  EasySB 一键部署脚本 / EasySB one-click deployment script
# ------------------------------------------------------------------------------
#  项目名称 Project    : EasySB
#  项目地址 Homepage   : https://github.com/MinimaxFlora/EasySB
#  参考项目 Reference  : https://github.com/fscarmen/sing-box
#  脚本版本 Version    : v1.3.25 (2026.09.18)
#  开源协议 License    : GPL-3.0
# ------------------------------------------------------------------------------
#  本脚本重构自 fscarmen/sing-box（https://github.com/fscarmen/sing-box），
#  完整保留其功能与全部交互选项，并针对 EasySB 项目重新梳理：统一远端资源
#  地址、集中管理常量、规范代码分段与注释。
#
#  原始项目版权 / Original copyright : fscarmen  https://github.com/fscarmen/sing-box
#  本项目版权   / Project copyright  : MinimaxFlora  https://github.com/MinimaxFlora/EasySB
#
#  本项目是 GPL-3.0 的衍生作品，分发与修改均需继续遵循 GPL-3.0 协议。
#  This script is a GPL-3.0 derivative work, see LICENSE for the full text.
# ==============================================================================

# ------------------------------------------------------------------------------
# 一、项目远端资源（本仓库自有资产）/ Project-owned remote endpoints
# ------------------------------------------------------------------------------
PROJECT_REPO='MinimaxFlora/EasySB'
PROJECT_BRANCH='master'
PROJECT_HOME="https://github.com/${PROJECT_REPO}"
PROJECT_RAW="https://raw.githubusercontent.com/${PROJECT_REPO}/${PROJECT_BRANCH}"
PROJECT_RELEASE="https://github.com/${PROJECT_REPO}/releases"
PROJECT_ISSUES="https://github.com/${PROJECT_REPO}/issues"
# 脚本自身地址：由 .github/workflows/easysb-release.yml 打包 EasySB/dist/easysb.sh 后
# 作为 release 资产发布，安装与快捷指令 [sb] 均从此处拉取最新脚本。
PROJECT_SCRIPT_URL="${PROJECT_RELEASE}/download/easysb/easysb.sh"
# sing-box 内核：由本仓库 Actions 编译并发布到 Releases，命名与上游保持一致
PROJECT_SING_BOX_RELEASE="${PROJECT_RELEASE}"
PROJECT_SING_BOX_API="https://api.github.com/repos/${PROJECT_REPO}/releases"
# 强制指定内核版本文件，用于某版本内核出现 bug 时锁定可用版本
PROJECT_FORCE_VERSION_URL="${PROJECT_RAW}/EasySB/force_version"

# ------------------------------------------------------------------------------
# 二、脚本元信息与全局默认值 / Script metadata and global defaults
# ------------------------------------------------------------------------------
# 当前脚本版本号 / Current script version
VERSION='v1.3.25 (2026.09.18)'

# Github 反代加速代理 / GitHub reverse-proxy accelerators
GITHUB_PROXY=('https://hub.glowp.xyz/' 'https://proxy.vvvv.ee/')

# 各变量默认值 / Default values
TEMP_DIR='/tmp/sing-box'
WORK_DIR='/etc/sing-box'
FIREWALL_STATE_DIR="${WORK_DIR}/firewall"
SERVICE_FIREWALL_STATE_FILE="${FIREWALL_STATE_DIR}/service_ports.list"
START_PORT_DEFAULT='8881'
MIN_PORT=100
MAX_PORT=65520
MIN_HOPPING_PORT=10000
MAX_HOPPING_PORT=65535
TLS_SERVER_DEFAULT=addons.mozilla.org
PROTOCOL_LIST=("XTLS + reality" "hysteria2" "tuic" "ShadowTLS" "shadowsocks" "trojan" "vmess + ws" "vless + ws + tls" "H2 + reality" "gRPC + reality" "AnyTLS" "naive")
NODE_TAG=("xtls-reality" "hysteria2" "tuic" "ShadowTLS" "shadowsocks" "trojan" "vmess-ws" "vless-ws-tls" "h2-reality" "grpc-reality" "anytls" "naive")
CONSECUTIVE_PORTS=${#PROTOCOL_LIST[@]}
CDN_DOMAIN=("skk.moe" "ip.sb" "time.is" "cfip.xxxxxxxx.tk" "bestcf.top" "cdn.2020111.xyz" "xn--b6gac.eu.org" "cf.090227.xyz")
# 客户端订阅模板来源，取自本仓库 Templates/ 目录，供订阅生成使用
#   config.yaml      -> Clash / Mihomo 订阅（proxy-providers 形式）
#   config-rule.yaml -> Clash / Mihomo 订阅（内嵌规则与节点的自包含形式）
#   config.json      -> sing-box SFM / SFA / SFI 订阅
SUBSCRIBE_TEMPLATE="${PROJECT_RAW}/Templates"
# 运行次数统计接口：留空表示不上报；填写自建统计服务地址即可启用统计功能
STATISTICS_API=''
# 仅在 GitHub API 不可达时使用的兜底内核版本，取本仓库已编译发布的正式版
DEFAULT_NEWEST_VERSION='1.14.1'
FINGER_PRINT='chrome'
STEP_NUM=0      # 当前步骤编号（安装流程中动态递增）
TOTAL_STEPS=''  # 总步骤数（协议确定后动态计算）

export DEBIAN_FRONTEND=noninteractive

cleanup_temp() {
  rm -rf "$TEMP_DIR"
}

trap cleanup_temp EXIT
trap 'cleanup_temp; printf "\n"; exit 1' INT QUIT TERM

mkdir -p "$TEMP_DIR"
