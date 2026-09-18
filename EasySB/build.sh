#!/usr/bin/env bash
# =============================================================================
# EasySB — build.sh
# 把 entry + lib/*.sh 打包成单文件 dist/easysb.sh（唯一允许 curl|bash 的文件）
# 步骤：语法检查 → 版本一致性检查 → 组装 → 冒烟测试 → 生成 SHA256SUMS
# =============================================================================
set -u

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BUILD_DIR" || exit 1

fatal() { printf '[构建失败] %s\n' "$*" >&2; exit 1; }
info()  { printf '[构建] %s\n' "$*"; }

[ -f VERSION ] || fatal "缺少 VERSION 文件"
VERSION="$(tr -d ' \r\n' <VERSION)"
[ -n "$VERSION" ] || fatal "VERSION 内容为空"

# 1. 语法检查
info "语法检查（bash -n）"
for f in easysb.sh lib/*.sh; do
  [ -f "$f" ] || continue
  bash -n "$f" || fatal "语法错误：$f"
done

# 2. 入口版本号必须与 VERSION 一致
ENTRY_VERSION="$(sed -n 's/^ESB_SCRIPT_VERSION="\(.*\)"$/\1/p' easysb.sh | head -1 | tr -d '\r')"
[ -n "$ENTRY_VERSION" ] || fatal "入口文件中找不到 ESB_SCRIPT_VERSION"
[ "$ENTRY_VERSION" = "$VERSION" ] || fatal "版本号不一致：easysb.sh=$ENTRY_VERSION，VERSION=$VERSION"

# 3. 组装
mkdir -p dist
TMP_DIST="dist/easysb.sh.tmp.$$"
{
  awk '/^# >>> EASYSB_LIB_SOURCE_BEGIN/{exit} {print}' easysb.sh
  printf '# ---------------------------------------------------------------------------\n'
  printf '# 以下模块由 build.sh 自动内联（源码位于 EasySB/lib/）\n'
  printf '# ---------------------------------------------------------------------------\n'
  for f in lib/*.sh; do
    [ -f "$f" ] || continue
    printf '\n# ===== 内联模块：%s =====\n' "$f"
    cat "$f"
    printf '\n'
  done
  awk 'BEGIN{skip=1} /^# <<< EASYSB_LIB_SOURCE_END/{skip=0; next} skip==0{print}' easysb.sh
} >"$TMP_DIST" || fatal "组装失败"

# 4. 语法检查 + 冒烟测试
bash -n "$TMP_DIST" || fatal "单文件语法错误"
chmod 755 "$TMP_DIST" || true
# 冒烟测试必须在干净环境里跑：开发机上遗留的 ESB_* 变量（ESB_NO_MAIN/ESB_GATE/ESB_ROOT…）
# 会让产物"什么都不输出"，看起来像构建坏了
SMOKE="$(env -u ESB_NO_MAIN -u ESB_GATE -u ESB_GATE_LOG -u ESB_ROOT -u ESB_OFFLINE \
  -u ESB_ASSUME_YES -u ESB_NO_PAUSE -u ESB_TEST_WORK \
  bash "$TMP_DIST" --version 2>&1)" || fatal "单文件运行失败：$SMOKE"
case "$SMOKE" in
  *"v${VERSION}"*) info "冒烟测试通过：$SMOKE" ;;
  *) fatal "版本输出异常：$SMOKE" ;;
esac
if ! env -u ESB_NO_MAIN -u ESB_GATE -u ESB_ROOT bash "$TMP_DIST" --help >/dev/null 2>&1; then
  fatal "--help 运行失败"
fi

mv -f "$TMP_DIST" dist/easysb.sh || fatal "替换产物失败"
chmod 755 dist/easysb.sh || true

# 5. 校验和
if command -v sha256sum >/dev/null 2>&1; then
  ( cd dist && sha256sum easysb.sh >SHA256SUMS ) || fatal "生成校验和失败"
  info "已生成 dist/SHA256SUMS"
fi

info "构建完成：dist/easysb.sh（v${VERSION}）"
info "安装命令：bash <(curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/EasySB/master/EasySB/dist/easysb.sh)"
exit 0
