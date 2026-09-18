#!/usr/bin/env bash
# =============================================================================
# EasySB — 70-web.sh
# 伪装站点（camouflage website）：
#   nginx 安装 / 模板站点部署 / ACME webroot / 443 证书配置 / 重载 / 端口检查
# 依赖：00-core.sh（run_gate / log_* / file_write）、10-detect.sh（service_mgr /
#       port_in_use / os_pkg_install / pkg_name_for）、20-state.sh（state_get / state_set*）
#
# 设计约束（违反即缺陷）：
#   1. 只写、只删**本工具自己**的配置文件（默认 easysb.conf），绝不读取或修改其它站点配置；
#   2. 所有绝对路径都带 ESB_ROOT 前缀（ESB_WEB_ROOT / ESB_NGINX_CONF 可被 init 覆盖）；
#   3. 所有系统变更命令走 run_gate；任何 nginx 配置生效前必须先 nginx -t；
#   4. UI 可调用的函数一律 `error "…"; return 1`，绝不 exit；
#   5. nginx 配置由 heredoc + file_write 生成，禁止 sed 原地改；
#   6. 443 端口若被已启用的 TCP 协议占用，必须拒绝写入 443 配置（保持 80 单端口站点）。
# =============================================================================
# shellcheck shell=bash

# nginx 配置里的管理标记（测试与契约审计依赖它，请勿修改）
ESB_WEB_MARKER="EasySB-MANAGED 伪装站点"

# ---------------------------------------------------------------------------
# 路径与模板工具
# ---------------------------------------------------------------------------
# 沙箱一致性：显式传入的路径必须落在 ESB_ROOT 之内（为空则任意路径都合法）
_web_under_root() {
  local _web_ur_path="${1-}"
  if [ -z "${ESB_ROOT:-}" ]; then return 0; fi
  case "$_web_ur_path" in
    "${ESB_ROOT}"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# stdout：伪装站点根目录
_web_root() {
  local _web_root_var="${ESB_WEB_ROOT:-}"
  if [ -n "$_web_root_var" ] && _web_under_root "$_web_root_var"; then
    printf '%s\n' "$_web_root_var"
  else
    printf '%s\n' "${ESB_ROOT:-}/var/www/easysb"
  fi
  return 0
}

# stdout：nginx 站点配置目录（Debian/RHEL=conf.d，Alpine=http.d，兜底 conf.d）
_web_conf_dir() {
  local _web_cd_dir
  for _web_cd_dir in \
      "${ESB_ROOT:-}/etc/nginx/conf.d" \
      "${ESB_ROOT:-}/etc/nginx/http.d" \
      "${ESB_ROOT:-}/etc/nginx/sites-enabled"; do
    if [ -d "$_web_cd_dir" ]; then
      printf '%s\n' "$_web_cd_dir"
      return 0
    fi
  done
  printf '%s\n' "${ESB_ROOT:-}/etc/nginx/conf.d"
  return 0
}

# stdout：本工具独占的 nginx 配置文件路径
_web_conf_file() {
  local _web_cf_var="${ESB_NGINX_CONF:-}"
  if [ -n "$_web_cf_var" ] && _web_under_root "$_web_cf_var" && [ -d "$(dirname "$_web_cf_var")" ]; then
    printf '%s\n' "$_web_cf_var"
  else
    printf '%s/easysb.conf\n' "$(_web_conf_dir)"
  fi
  return 0
}

# 规范化反向代理目标（去首尾空白、去尾部斜杠），stdout 输出
_web_normalize_url() {
  local _web_nu_val="$(trim "${1-}")"
  case "$_web_nu_val" in
    */)
      if [ "${#_web_nu_val}" -gt 8 ]; then _web_nu_val="${_web_nu_val%/}"; fi
      ;;
  esac
  printf '%s\n' "$_web_nu_val"
  return 0
}

# 只允许写/删本工具自己的配置，防止 ESB_NGINX_CONF 被误配到别人的站点文件上
_web_conf_owned() {
  case "$(basename "${1-}")" in
    *easysb*) return 0 ;;
    *) return 1 ;;
  esac
}

_web_conf_bak() { printf '%s.easysb.bak\n' "$1"; }

_web_template_known() {
  case "${1-}" in
    blog|corp|blank|custom|proxy) return 0 ;;
    *) return 1 ;;
  esac
}

_web_template_label() {
  case "${1-}" in
    blog)   printf '个人博客\n' ;;
    corp)   printf '企业官网\n' ;;
    blank)  printf '200 空白页\n' ;;
    custom) printf '自定义 HTML\n' ;;
    proxy)  printf '反向代理到真实站点\n' ;;
    *)      printf '%s\n' "${1-}" ;;
  esac
  return 0
}

# 模板列表（stdout TSV：key<TAB>名称）
web_templates() {
  local _web_tpl_k
  for _web_tpl_k in blog corp blank custom proxy; do
    printf '%s\t%s\n' "$_web_tpl_k" "$(_web_template_label "$_web_tpl_k")"
  done
  return 0
}

# ---------------------------------------------------------------------------
# nginx 存在性 / 版本 / 服务动作
# ---------------------------------------------------------------------------
web_installed() {
  if cmd_exists nginx; then return 0; fi
  local _web_inst_p
  for _web_inst_p in \
      "${ESB_ROOT:-}/usr/sbin/nginx" \
      "${ESB_ROOT:-}/sbin/nginx" \
      "${ESB_ROOT:-}/usr/bin/nginx"; do
    if [ -x "$_web_inst_p" ]; then return 0; fi
  done
  return 1
}

# stdout：nginx 版本号（形如 1.24.0），取不到输出空
_web_nginx_version() {
  local _web_nv_out=""
  if ! web_installed; then return 0; fi
  _web_nv_out="$(nginx -v 2>&1 | tr -d '\r' | sed -n 's|.*nginx/\([0-9][0-9.]*\).*|\1|p' | head -1)"
  printf '%s\n' "$_web_nv_out"
  return 0
}

# nginx 服务动作：优先 service_mgr；没有 init 系统（容器/沙箱）时直接操作 nginx 进程
_web_service() {
  local _web_svc_action="${1:-status}"
  if [ "${ESB_INIT:-none}" != "none" ] || [ -x "${ESB_ROOT:-}/etc/init.d/nginx" ]; then
    service_mgr nginx "$_web_svc_action"
    return $?
  fi
  case "$_web_svc_action" in
    status)
      log_debug "没有服务管理器，无法判断 nginx 运行状态"
      return 1
      ;;
    start)   run_gate "nginx start" nginx ;;
    reload)  run_gate "nginx reload" nginx -s reload ;;
    restart) run_gate "nginx restart" nginx -s reload ;;
    stop)    run_gate "nginx stop" nginx -s quit ;;
    enable|disable) return 0 ;;
    *)
      error "未知的 nginx 服务动作：$_web_svc_action"
      return 1
      ;;
  esac
}

# nginx -t：0=配置合法。沙箱（ESB_GATE=1）里只记录不执行。
_web_conf_test() {
  local _web_ct_out="" _web_ct_line=""
  if [ "${ESB_GATE:-0}" = "1" ]; then
    run_gate "nginx -t" nginx -t
    return 0
  fi
  if _web_ct_out="$(nginx -t 2>&1)"; then
    log_debug "nginx -t 通过"
    return 0
  fi
  log_warn "nginx -t 未通过，已拒绝重载（运行中的 nginx 不受影响）"
  printf '%s\n' "$_web_ct_out" | tr -d '\r' | while IFS= read -r _web_ct_line; do
    log_warn "    $_web_ct_line"
  done
  return 1
}

web_reload() {
  if ! web_installed; then
    error "nginx 未安装，无法重载配置"
    return 1
  fi
  if ! _web_conf_test; then
    return 1
  fi
  if ! _web_service reload; then
    log_warn "nginx 重载失败，尝试重启以加载新配置"
    if ! _web_service restart; then
      error "nginx 重启失败，请手动检查 nginx -t 与服务日志"
      return 1
    fi
  fi
  log_ok "nginx 配置已生效"
  return 0
}

web_install() {
  if web_installed; then
    log_ok "nginx 已安装（$(_web_nginx_version)）"
    return 0
  fi
  log_info "安装 nginx（包管理器：${ESB_PKG:-unknown}）"
  if ! os_pkg_install "$(pkg_name_for nginx)"; then
    error "nginx 安装失败，请手动安装后重试（apt install nginx / dnf install nginx / apk add nginx）"
    return 1
  fi
  mkdir -p "$(_web_conf_dir)" 2>/dev/null || true
  if ! _web_service enable; then log_warn "nginx 开机自启设置失败（不影响本次使用）"; fi
  if ! _web_service start; then log_warn "nginx 启动失败，请检查 nginx -t 与服务日志"; fi
  if ! web_installed; then
    error "安装后仍未找到 nginx 可执行文件，请手动检查安装结果"
    return 1
  fi
  log_ok "nginx 安装完成（$(_web_nginx_version)）"
  return 0
}

# ---------------------------------------------------------------------------
# 站点内容（内联 CSS，无任何外部 CDN 依赖）
# ---------------------------------------------------------------------------
_web_page_blog() {
  cat <<'HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>云间笔记 · 个人博客</title>
<style>
  :root{--fg:#1b1f24;--muted:#5c6672;--line:#e6e8eb;--accent:#2f6feb;--bg:#fbfbfd;--card:#fff}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);line-height:1.75;
       font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans SC","PingFang SC","Microsoft YaHei",sans-serif}
  a{color:var(--accent);text-decoration:none}
  a:hover{text-decoration:underline}
  header{background:var(--card);border-bottom:1px solid var(--line)}
  .wrap{max-width:820px;margin:0 auto;padding:0 20px}
  .bar{display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;padding:18px 0}
  .brand{font-size:20px;font-weight:600;letter-spacing:.5px}
  nav a{margin-left:18px;color:var(--muted);font-size:15px}
  main{padding:36px 0 56px}
  h1{font-size:30px;margin:0 0 8px}
  .lead{color:var(--muted);margin:0 0 30px}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:16px}
  .card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px 20px}
  .card h3{margin:0 0 8px;font-size:17px}
  .card p{margin:0;color:var(--muted);font-size:14.5px}
  .meta{color:var(--muted);font-size:13px;margin-top:10px}
  footer{border-top:1px solid var(--line);color:var(--muted);font-size:13px;padding:22px 0;text-align:center}
  @media (max-width:600px){h1{font-size:24px}nav a{margin-left:12px}}
</style>
</head>
<body>
<header>
  <div class="wrap bar">
    <div class="brand">云间笔记</div>
    <nav><a href="/">首页</a><a href="/archive">归档</a><a href="/about">关于</a></nav>
  </div>
</header>
<main class="wrap">
  <h1>用文字记录，与技术慢慢相处</h1>
  <p class="lead">这里是我的个人博客：写网络与自建服务，也写读书和日常。</p>
  <section class="cards">
    <article class="card">
      <h3>自建网络服务入门</h3>
      <p>从一台最小配置的服务器开始，把需要的东西一件件搭起来。</p>
      <div class="meta">2026-08-30 · 网络</div>
    </article>
    <article class="card">
      <h3>给站点配一张证书</h3>
      <p>让网站支持 HTTPS，其实比想象中简单，也不影响正在运行的服务。</p>
      <div class="meta">2026-09-05 · 运维</div>
    </article>
    <article class="card">
      <h3>最近在读的书</h3>
      <p>技术之外的一点阅读记录，慢慢补充中。</p>
      <div class="meta">2026-09-12 · 随笔</div>
    </article>
  </section>
</main>
<footer><div class="wrap">© 2026 云间笔记 · 保留所有权利</div></footer>
</body>
</html>
HTML
}

_web_page_corp() {
  cat <<'HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>远山科技 · 企业官网</title>
<style>
  :root{--fg:#141a21;--muted:#5b6673;--line:#e3e7ec;--accent:#0f62fe;--bg:#fff}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);line-height:1.7;
       font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans SC","PingFang SC","Microsoft YaHei",sans-serif}
  a{color:inherit;text-decoration:none}
  .wrap{max-width:1040px;margin:0 auto;padding:0 22px}
  header{border-bottom:1px solid var(--line);position:sticky;top:0;background:rgba(255,255,255,.94)}
  .bar{display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;padding:16px 0}
  .logo{font-size:19px;font-weight:700;letter-spacing:1px}
  nav a{margin-left:20px;color:var(--muted);font-size:15px}
  .hero{padding:64px 0 52px;border-bottom:1px solid var(--line)}
  .hero h1{margin:0 0 14px;font-size:36px;line-height:1.3}
  .hero p{margin:0 0 26px;color:var(--muted);font-size:16.5px;max-width:640px}
  .btn{display:inline-block;background:var(--accent);color:#fff;padding:11px 22px;border-radius:8px;font-size:15px}
  .btn.ghost{background:transparent;color:var(--accent);border:1px solid var(--accent);margin-left:10px}
  section{padding:52px 0}
  h2{font-size:23px;margin:0 0 22px}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:20px}
  .box{border:1px solid var(--line);border-radius:12px;padding:22px}
  .box h3{margin:0 0 10px;font-size:17px}
  .box p{margin:0;color:var(--muted);font-size:14.5px}
  footer{border-top:1px solid var(--line);padding:26px 0;color:var(--muted);font-size:13.5px}
  @media (max-width:600px){.hero h1{font-size:27px}nav a{margin-left:14px}.btn.ghost{margin:10px 0 0 0}}
</style>
</head>
<body>
<header>
  <div class="wrap bar">
    <div class="logo">远山科技</div>
    <nav><a href="#product">产品</a><a href="#solution">解决方案</a><a href="#contact">联系我们</a></nav>
  </div>
</header>
<div class="wrap">
  <section class="hero">
    <h1>让每一台服务器都稳定、可靠、可维护</h1>
    <p>远山科技为中小企业提供基础架构与网络服务，从选型、部署到日常运维，把复杂的事情做简单。</p>
    <a class="btn" href="#contact">联系我们</a><a class="btn ghost" href="#product">了解产品</a>
  </section>
  <section id="product">
    <h2>主要服务</h2>
    <div class="grid">
      <div class="box"><h3>基础架构部署</h3><p>服务器初始化、系统加固、服务编排，交付即用。</p></div>
      <div class="box"><h3>网络与加速</h3><p>链路优化、证书管理与域名规划，访问更快更稳。</p></div>
      <div class="box"><h3>运维托管</h3><p>监控告警、备份恢复与应急响应，7×24 小时值守。</p></div>
    </div>
  </section>
  <section id="contact">
    <h2>联系我们</h2>
    <div class="grid">
      <div class="box"><h3>商务咨询</h3><p>邮箱：contact@example.com<br>工作时间：周一至周五 9:00 - 18:00</p></div>
      <div class="box"><h3>技术支持</h3><p>邮箱：support@example.com<br>电话：400-000-0000</p></div>
    </div>
  </section>
</div>
<footer><div class="wrap">© 2026 远山科技 · 京ICP备00000000号</div></footer>
</body>
</html>
HTML
}

_web_page_blank() {
  cat <<'HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Welcome</title>
</head>
<body></body>
</html>
HTML
}

_web_page_custom_placeholder() {
  cat <<'HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>自定义站点</title>
<style>
  body{margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center;background:#f7f8fa;
       color:#1b1f24;font-family:-apple-system,"Noto Sans SC","Microsoft YaHei",sans-serif}
  .box{max-width:560px;padding:28px 30px;background:#fff;border:1px solid #e6e8eb;border-radius:12px;line-height:1.8}
  code{background:#f1f3f5;padding:2px 6px;border-radius:4px}
</style>
</head>
<body>
  <div class="box">
    <h1>自定义站点已就绪</h1>
    <p>请把你自己的 <code>index.html</code> 及静态资源放入本目录，刷新页面即可看到效果。</p>
    <p>本页面由 EasySB 生成，仅作为占位；覆盖后不会再被自动改写。</p>
  </div>
</body>
</html>
HTML
}

# 写站点首页；proxy 模板不写任何页面文件
_web_page_write() {
  local _web_pw_tpl="${1-}" _web_pw_root _web_pw_file
  _web_pw_root="$(_web_root)"
  _web_pw_file="${_web_pw_root}/index.html"
  case "$_web_pw_tpl" in
    blog)   _web_page_blog   | file_write "$_web_pw_file" 644 ;;
    corp)   _web_page_corp   | file_write "$_web_pw_file" 644 ;;
    blank)  _web_page_blank  | file_write "$_web_pw_file" 644 ;;
    custom)
      if [ -f "$_web_pw_file" ]; then
        log_info "custom 模板：保留已有首页 ${_web_pw_file}"
        return 0
      fi
      _web_page_custom_placeholder | file_write "$_web_pw_file" 644
      ;;
    *) return 0 ;;
  esac
  if [ ! -f "$_web_pw_file" ]; then
    error "写入站点首页失败：$_web_pw_file"
    return 1
  fi
  log_info "站点首页已写入：$_web_pw_file"
  return 0
}

# ---------------------------------------------------------------------------
# 证书 / 端口相关判定
# ---------------------------------------------------------------------------
_web_tls_port() {
  local _web_tp="${1-}"
  if [ -z "$_web_tp" ]; then _web_tp="$(state_get .web.tls_port)"; fi
  case "$_web_tp" in
    ''|*[!0-9]*) _web_tp=443 ;;
  esac
  if [ "$_web_tp" -lt 1 ] || [ "$_web_tp" -gt 65535 ]; then _web_tp=443; fi
  printf '%s\n' "$_web_tp"
  return 0
}

# stdout：证书文件真实路径（state 里可能存了带/不带 ESB_ROOT 前缀的路径）
_web_resolve_path() {
  local _web_rp_path="${1-}" _web_rp_alt=""
  if [ -z "$_web_rp_path" ]; then return 1; fi
  if [ -f "$_web_rp_path" ]; then
    printf '%s\n' "$_web_rp_path"
    return 0
  fi
  if [ -n "${ESB_ROOT:-}" ]; then
    case "$_web_rp_path" in
      "${ESB_ROOT}"/*) _web_rp_alt="$_web_rp_path" ;;
      *) _web_rp_alt="${ESB_ROOT}${_web_rp_path}" ;;
    esac
    if [ -f "$_web_rp_alt" ]; then
      printf '%s\n' "$_web_rp_alt"
      return 0
    fi
  fi
  return 1
}

# stdout：两行，第一行证书、第二行私钥；缺任意一个则 return 1
_web_tls_cert_paths() {
  local _web_tcp_crt="" _web_tcp_key=""
  _web_tcp_crt="$(_web_resolve_path "$(state_get .cert.crt)")" || return 1
  _web_tcp_key="$(_web_resolve_path "$(state_get .cert.key)")" || return 1
  if [ -z "$_web_tcp_crt" ] || [ -z "$_web_tcp_key" ]; then return 1; fi
  printf '%s\n%s\n' "$_web_tcp_crt" "$_web_tcp_key"
  return 0
}

# stdout：占用该端口的已启用 TCP 协议 key（无冲突则无输出）
_web_tcp_conflict() {
  local _web_tc_port="${1-}" _web_tc_k _web_tc_p
  if [ -z "$_web_tc_port" ]; then return 1; fi
  for _web_tc_k in vless-vision-reality vmess-ws-tls anytls; do
    if ! proto_enabled "$_web_tc_k"; then continue; fi
    _web_tc_p="$(proto_port "$_web_tc_k")"
    if [ -n "$_web_tc_p" ] && [ "$_web_tc_p" = "$_web_tc_port" ]; then
      printf '%s\n' "$_web_tc_k"
      return 0
    fi
  done
  return 1
}

# 0 = 现在可以写 443（.web.tls=true + 证书齐 + 端口未被启用协议占用）
_web_tls_ready() {
  local _web_tr_owner=""
  if [ "$(state_get .web.tls)" != "true" ]; then return 1; fi
  if ! _web_tls_cert_paths >/dev/null 2>&1; then return 1; fi
  _web_tr_owner="$(_web_tcp_conflict "$(_web_tls_port)")"
  if [ -n "$_web_tr_owner" ]; then return 1; fi
  return 0
}

# 443 的 listen 行：nginx >= 1.25.1 用独立指令 http2 on;，更老的版本用 listen 参数形式
_web_tls_listen_lines() {
  local _web_tll_port="${1:-443}" _web_tll_ver _web_tll_maj _web_tll_rest _web_tll_min _web_tll_pat
  local _web_tll_kw=" http2" _web_tll_on=""
  _web_tll_ver="$(_web_nginx_version)"
  case "$_web_tll_ver" in
    ''|*[!0-9.]*)
      _web_tll_ver=""
      ;;
  esac
  if [ -n "$_web_tll_ver" ]; then
    _web_tll_maj="${_web_tll_ver%%.*}"
    _web_tll_rest="${_web_tll_ver#*.}"
    _web_tll_min="${_web_tll_rest%%.*}"
    _web_tll_pat="${_web_tll_rest#*.}"
    if [ "$_web_tll_pat" = "$_web_tll_rest" ]; then _web_tll_pat=0; fi
    case "$_web_tll_maj" in ''|*[!0-9]*) _web_tll_maj=0 ;; esac
    case "$_web_tll_min" in ''|*[!0-9]*) _web_tll_min=0 ;; esac
    case "$_web_tll_pat" in ''|*[!0-9]*) _web_tll_pat=0 ;; esac
    if [ "$_web_tll_maj" -gt 1 ]; then
      _web_tll_kw=""; _web_tll_on="    http2 on;"
    elif [ "$_web_tll_maj" -eq 1 ] && [ "$_web_tll_min" -gt 25 ]; then
      _web_tll_kw=""; _web_tll_on="    http2 on;"
    elif [ "$_web_tll_maj" -eq 1 ] && [ "$_web_tll_min" -eq 25 ] && [ "$_web_tll_pat" -ge 1 ]; then
      _web_tll_kw=""; _web_tll_on="    http2 on;"
    fi
  fi
  printf '    listen %s ssl%s;\n' "$_web_tll_port" "$_web_tll_kw"
  printf '    listen [::]:%s ssl%s;\n' "$_web_tll_port" "$_web_tll_kw"
  if [ -n "$_web_tll_on" ]; then printf '%s\n' "$_web_tll_on"; fi
  return 0
}

# ---------------------------------------------------------------------------
# nginx 配置生成（heredoc → file_write，绝不 sed -i）
# ---------------------------------------------------------------------------
# $1 = 模板 key，$2 = 1 写入 443 站点 / 0 仅 80
_web_conf_render() {
  local _web_cr_tpl="${1:-blog}" _web_cr_tls="${2:-0}"
  local _web_cr_root _web_cr_http_port _web_cr_domain _web_cr_name _web_cr_target=""
  local _web_cr_tls_port="" _web_cr_crt="" _web_cr_key="" _web_cr_listen="" _web_cr_proxy="0"

  _web_cr_root="$(_web_root)"
  _web_cr_http_port="$(state_get .web.http_port)"
  case "$_web_cr_http_port" in
    ''|*[!0-9]*) _web_cr_http_port=80 ;;
  esac
  _web_cr_domain="$(state_get .domain)"
  _web_cr_name="$_web_cr_domain"
  if [ -z "$_web_cr_name" ]; then _web_cr_name="_"; fi
  _web_cr_target="$(_web_normalize_url "$(state_get .web.proxy_target)")"
  _web_cr_proxy="0"
  if [ "$_web_cr_tpl" = "proxy" ]; then
    if [ -n "$_web_cr_target" ]; then
      _web_cr_proxy="1"
    else
      # 目标缺失时绝不生成 `proxy_pass ;`（那是非法配置），退化为静态块
      log_debug "反向代理目标为空，本次退化为静态站点块"
    fi
  fi

  if [ "$_web_cr_tls" = "1" ]; then
    _web_cr_tls_port="$(_web_tls_port)"
    _web_cr_crt="$(_web_tls_cert_paths | sed -n 1p)"
    _web_cr_key="$(_web_tls_cert_paths | sed -n 2p)"
    _web_cr_listen="$(_web_tls_listen_lines "$_web_cr_tls_port")"
  fi

  # ---- 文件头（管理标记） ----
  cat <<EOF
# =============================================================================
# ${ESB_WEB_MARKER}
#   站点模板 : ${_web_cr_tpl}（$(_web_template_label "$_web_cr_tpl")）
#   生成时间 : $(esb_now)
#   说明     : 本文件由 EasySB 生成并独占管理，只包含本工具自己的 server 块；
#              EasySB 不会读取或修改其它站点的 nginx 配置。
#              手工修改会在下次部署/应用证书时被覆盖。
# =============================================================================
EOF

  # ---- 反代模板需要的 WebSocket 升级映射（http 上下文，名称带 easysb 前缀避免撞名） ----
  if [ "$_web_cr_proxy" = "1" ]; then
    cat <<'EOF'

# 反向代理：WebSocket / HTTP 升级支持（仅本文件使用）
map $http_upgrade $easysb_connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
  fi

  # ---- 80 端口 server 块 ----
  cat <<EOF

server {
    listen ${_web_cr_http_port};
    listen [::]:${_web_cr_http_port};
    server_name ${_web_cr_name};

    root ${_web_cr_root};
    index index.html;

    # 隐藏 nginx 版本，避免指纹
    server_tokens off;
    access_log off;

    # ACME http-01 挑战目录：证书签发与续期不需要停站点、不影响正在运行的服务
    location /.well-known/acme-challenge/ {
        root ${_web_cr_root};
        default_type "text/plain";
        try_files \$uri =404;
    }

EOF

  if [ "$_web_cr_tls" = "1" ] && [ -n "$_web_cr_domain" ]; then
    cat <<'EOF'
    # 已启用 HTTPS：明文请求跳转（上面的 acme-challenge 位置优先匹配，不受影响）
    location / {
        return 301 https://$host$request_uri;
    }
EOF
  elif [ "$_web_cr_proxy" = "1" ]; then
    cat <<EOF
    location / {
        proxy_pass ${_web_cr_target};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$easysb_connection_upgrade;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
EOF
  else
    cat <<'EOF'
    location / {
        try_files $uri $uri/ /index.html;
    }
EOF
  fi
  printf '}\n'

  # ---- 443 端口 server 块 ----
  if [ "$_web_cr_tls" = "1" ]; then
    cat <<EOF

server {
${_web_cr_listen}
    server_name ${_web_cr_name};

    ssl_certificate     ${_web_cr_crt};
    ssl_certificate_key ${_web_cr_key};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache   shared:easysb_ssl:10m;
    ssl_session_tickets off;

    root ${_web_cr_root};
    index index.html;
    server_tokens off;
    access_log off;

    location /.well-known/acme-challenge/ {
        root ${_web_cr_root};
        default_type "text/plain";
        try_files \$uri =404;
    }

EOF
    if [ "$_web_cr_proxy" = "1" ]; then
      cat <<EOF
    location / {
        proxy_pass ${_web_cr_target};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$easysb_connection_upgrade;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF
    else
      cat <<'EOF'
    location / {
        try_files $uri $uri/ /index.html;
    }
}
EOF
    fi
  fi
  return 0
}

# 写本工具的 nginx 配置（先备份旧版本，失败可从 .easysb.bak 恢复）
_web_conf_write() {
  local _web_cw_tpl="${1:-blog}" _web_cw_tls="${2:-0}"
  local _web_cw_conf _web_cw_dir _web_cw_bak
  _web_cw_conf="$(_web_conf_file)"
  _web_cw_dir="$(dirname "$_web_cw_conf")"
  _web_cw_bak="$(_web_conf_bak "$_web_cw_conf")"

  if ! _web_conf_owned "$_web_cw_conf"; then
    error "拒绝写入非本工具管理的 nginx 配置：$_web_cw_conf（文件名必须包含 easysb）"
    return 1
  fi
  if ! mkdir -p "$_web_cw_dir" 2>/dev/null; then
    error "无法创建 nginx 配置目录：$_web_cw_dir"
    return 1
  fi
  if [ -f "$_web_cw_conf" ]; then
    if ! cp -f "$_web_cw_conf" "$_web_cw_bak" 2>/dev/null; then
      log_warn "无法备份现有配置（$_web_cw_bak），继续写入"
    fi
  fi
  if ! _web_conf_render "$_web_cw_tpl" "$_web_cw_tls" | file_write "$_web_cw_conf" 644; then
    error "写入 nginx 配置失败：$_web_cw_conf"
    return 1
  fi
  log_info "已生成 nginx 配置：$_web_cw_conf"
  return 0
}

# 回滚到写入前的配置（没有备份就删除）
_web_conf_rollback() {
  local _web_crb_conf _web_crb_bak
  _web_crb_conf="$(_web_conf_file)"
  _web_crb_bak="$(_web_conf_bak "$_web_crb_conf")"
  if [ -f "$_web_crb_bak" ]; then
    if cp -f "$_web_crb_bak" "$_web_crb_conf" 2>/dev/null; then
      log_warn "已恢复到写入前的 nginx 配置：$_web_crb_conf"
    else
      log_warn "恢复 nginx 配置失败，请手工检查：$_web_crb_conf"
    fi
    return 0
  fi
  rm -f "$_web_crb_conf" 2>/dev/null || true
  log_warn "已移除本次生成的 nginx 配置：$_web_crb_conf"
  return 0
}

# ---------------------------------------------------------------------------
# 对外 API：部署 / 关闭 / 状态
# ---------------------------------------------------------------------------
web_deploy() {
  local _web_dp_key="${1-}"
  local _web_dp_conf _web_dp_root _web_dp_target="" _web_dp_tls=0

  if ! _web_template_known "$_web_dp_key"; then
    error "未知的站点模板：${_web_dp_key:-（空）}（可选：blog / corp / blank / custom / proxy）"
    return 1
  fi
  if ! web_installed; then
    error "nginx 未安装，请先执行 web_install"
    return 1
  fi
  if [ ! -f "$ESB_STATE" ]; then
    if ! state_init; then
      error "无法初始化状态文件：$ESB_STATE"
      return 1
    fi
  fi

  _web_dp_conf="$(_web_conf_file)"
  _web_dp_root="$(_web_root)"

  if [ "$_web_dp_key" = "proxy" ]; then
    _web_dp_target="$(_web_normalize_url "$(state_get .web.proxy_target)")"
    if [ -z "$_web_dp_target" ]; then
      error "反向代理模板需要先设置目标地址（state .web.proxy_target，例如 https://example.org）"
      return 1
    fi
    case "$_web_dp_target" in
      http://*|https://*) ;;
      *)
        error "反向代理目标必须以 http:// 或 https:// 开头：$_web_dp_target"
        return 1
        ;;
    esac
  fi

  if ! mkdir -p "${_web_dp_root}/.well-known/acme-challenge" 2>/dev/null; then
    error "无法创建站点根目录：$_web_dp_root"
    return 1
  fi

  if [ "$_web_dp_key" != "proxy" ]; then
    if ! _web_page_write "$_web_dp_key"; then
      return 1
    fi
  fi

  if _web_tls_ready; then _web_dp_tls=1; fi
  if ! _web_conf_write "$_web_dp_key" "$_web_dp_tls"; then
    return 1
  fi
  if ! web_reload; then
    log_err "nginx 配置校验/重载失败，已回滚本次生成的配置"
    _web_conf_rollback
    return 1
  fi

  state_set_str ".web.template" "$_web_dp_key" >/dev/null 2>&1 || true
  state_set_str ".web.root" "$_web_dp_root" >/dev/null 2>&1 || true
  state_set ".web.enabled" "true" >/dev/null 2>&1 || true
  if [ -z "$(state_get .web.http_port)" ]; then
    state_set ".web.http_port" "80" >/dev/null 2>&1 || true
  fi

  log_ok "伪装站点已部署：$_web_dp_key（$(_web_template_label "$_web_dp_key")）"
  log_info "站点根目录：$_web_dp_root"
  if [ "$_web_dp_tls" = "1" ]; then
    log_ok "已同时启用 443（HTTPS）站点：$(state_get .cert.domain)"
  elif [ "$(state_get .web.tls)" = "true" ]; then
    log_warn "已请求 HTTPS，但证书缺失或端口冲突，本次仅生成 80 站点（可用 web_apply_cert 查看原因）"
  fi
  return 0
}

web_disable() {
  local _web_ds_conf _web_ds_bak
  _web_ds_conf="$(_web_conf_file)"
  _web_ds_bak="$(_web_conf_bak "$_web_ds_conf")"

  if [ ! -f "$_web_ds_conf" ]; then
    state_set ".web.enabled" "false" >/dev/null 2>&1 || true
    log_info "伪装站点未部署（找不到 $_web_ds_conf），已同步状态"
    return 0
  fi
  if ! _web_conf_owned "$_web_ds_conf"; then
    error "拒绝删除非本工具管理的 nginx 配置：$_web_ds_conf（文件名必须包含 easysb）"
    return 1
  fi

  # 保留一份可恢复的备份（扩展名不是 .conf，不会被 nginx 加载）
  cp -f "$_web_ds_conf" "$_web_ds_bak" 2>/dev/null || log_warn "无法备份待删除的配置：$_web_ds_bak"
  if ! rm -f "$_web_ds_conf" 2>/dev/null; then
    error "无法删除 nginx 配置：$_web_ds_conf"
    return 1
  fi
  log_info "已移除 nginx 配置：$_web_ds_conf"

  if ! web_reload; then
    log_warn "移除配置后 nginx 校验未通过，备份保留在 $_web_ds_bak"
    return 1
  fi
  state_set ".web.enabled" "false" >/dev/null 2>&1 || true
  log_ok "伪装站点已关闭（站点根目录内容保留：$(_web_root)）"
  return 0
}

web_status() {
  local _web_st_conf _web_st_root _web_st_installed="未安装" _web_st_run="未知"
  local _web_st_deployed="未部署" _web_st_tpl="-" _web_st_tls="未启用" _web_st_443="未写入"
  local _web_st_cert="未应用" _web_st_target="-" _web_st_http="80" _web_st_tls_port="443" _web_st_rc=1
  local _web_st_body="" _web_st_crt="" _web_st_key=""

  _web_st_conf="$(_web_conf_file)"
  _web_st_root="$(_web_root)"
  _web_st_http="$(state_get .web.http_port)"
  if [ -z "$_web_st_http" ]; then _web_st_http="80"; fi
  _web_st_tls_port="$(_web_tls_port)"

  if web_installed; then
    _web_st_installed="已安装（nginx/$(_web_nginx_version)）"
  fi
  if [ "${ESB_INIT:-none}" != "none" ] || [ -x "${ESB_ROOT:-}/etc/init.d/nginx" ]; then
    if _web_service status; then _web_st_run="运行中"; else _web_st_run="未运行"; fi
  fi

  if [ -f "$_web_st_conf" ]; then
    _web_st_deployed="已部署"
    _web_st_rc=0
  fi
  _web_st_tpl="$(state_get .web.template)"
  if [ -z "$_web_st_tpl" ]; then _web_st_tpl="blog"; fi

  if [ "$(state_get .web.tls)" = "true" ]; then
    _web_st_tls="已启用（端口 ${_web_st_tls_port}）"
  fi
  if [ -f "$_web_st_conf" ]; then
    if grep -qE "^[[:space:]]*listen[[:space:]]+(\[::\]:)?${_web_st_tls_port}[[:space:]]+ssl" "$_web_st_conf" 2>/dev/null; then
      _web_st_443="已写入"
    fi
  fi
  _web_st_crt="$(_web_resolve_path "$(state_get .cert.crt)" || true)"
  _web_st_key="$(_web_resolve_path "$(state_get .cert.key)" || true)"
  if [ -n "$_web_st_crt" ] && [ -n "$_web_st_key" ]; then
    _web_st_cert="$(state_get .cert.domain)"
    if [ -z "$_web_st_cert" ]; then _web_st_cert="已应用"; fi
    _web_st_cert="${_web_st_cert}（$(basename "$_web_st_crt") + $(basename "$_web_st_key")）"
  fi
  _web_st_target="$(trim "$(state_get .web.proxy_target)")"
  if [ -z "$_web_st_target" ]; then _web_st_target="-"; fi

  printf '%s\n' "伪装站点（nginx）"
  printf '  %-16s: %s\n' "nginx" "$_web_st_installed"
  printf '  %-16s: %s\n' "nginx 服务" "$_web_st_run"
  printf '  %-16s: %s\n' "站点状态" "$_web_st_deployed"
  printf '  %-16s: %s（%s）\n' "站点模板" "$_web_st_tpl" "$(_web_template_label "$_web_st_tpl")"
  printf '  %-16s: %s\n' "站点根目录" "$_web_st_root"
  printf '  %-16s: %s\n' "HTTP 端口" "$_web_st_http"
  printf '  %-16s: %s\n' "HTTPS" "$_web_st_tls"
  printf '  %-16s: %s\n' "443 配置" "$_web_st_443"
  printf '  %-16s: %s\n' "证书" "$_web_st_cert"
  printf '  %-16s: %s\n' "反代目标" "$_web_st_target"
  printf '  %-16s: %s\n' "ACME webroot" "${_web_st_root}/.well-known/acme-challenge"
  printf '  %-16s: %s\n' "配置文件" "$_web_st_conf"
  return "$_web_st_rc"
}

# ---------------------------------------------------------------------------
# 对外 API：ACME webroot / 443 证书 / 端口检查
# ---------------------------------------------------------------------------
web_acme_webroot() {
  local _web_aw_root _web_aw_dir
  _web_aw_root="$(_web_root)"
  _web_aw_dir="${_web_aw_root}/.well-known/acme-challenge"
  if ! mkdir -p "$_web_aw_dir" 2>/dev/null; then
    error "无法创建 ACME 挑战目录：$_web_aw_dir"
    return 1
  fi
  chmod 755 "$_web_aw_root" "$_web_aw_root/.well-known" "$_web_aw_dir" 2>/dev/null || true
  printf '%s\n' "$_web_aw_dir"
  return 0
}

# 把已应用的证书写进 nginx（443）。端口被已启用的 TCP 协议占用时拒绝，保持 80 单端口站点。
web_apply_cert() {
  local _web_ac_conf _web_ac_port _web_ac_owner _web_ac_crt="" _web_ac_key="" _web_ac_tpl=""
  local _web_ac_conflict_port=""

  _web_ac_conf="$(_web_conf_file)"
  _web_ac_port="$(_web_tls_port)"

  if [ "$(state_get .web.tls)" != "true" ]; then
    error "伪装站点未启用 HTTPS（state .web.tls 不是 true），未写入 443 配置（站点仍为 80）"
    return 1
  fi
  if ! validate_port "$_web_ac_port"; then
    return 1
  fi
  if ! web_installed; then
    error "nginx 未安装，请先执行 web_install"
    return 1
  fi

  # 1) 与已启用的 TCP 协议抢端口 → 直接拒绝，绝不制造端口冲突
  _web_ac_owner="$(_web_tcp_conflict "$_web_ac_port")"
  if [ -n "$_web_ac_owner" ]; then
    log_warn "伪装站点保持仅 80 端口：端口 ${_web_ac_port} 已被启用的协议 ${_web_ac_owner} 占用，未写入 443 配置"
    error "拒绝写入 443 站点配置：端口 ${_web_ac_port} 与已启用协议 ${_web_ac_owner} 冲突（可改 .web.tls_port 或关闭该协议后重试）"
    # 状态必须如实反映结果：否则订阅地址会给出一个并不存在的 https 地址
    state_set ".web.tls" "false" >/dev/null 2>&1 || true
    return 1
  fi

  # 2) 证书必须真实存在
  _web_ac_crt="$(_web_tls_cert_paths | sed -n 1p)"
  _web_ac_key="$(_web_tls_cert_paths | sed -n 2p)"
  if [ -z "$_web_ac_crt" ] || [ -z "$_web_ac_key" ]; then
    error "没有可用的证书文件（state .cert.crt / .cert.key），请先在证书管理中申请并应用证书"
    state_set ".web.tls" "false" >/dev/null 2>&1 || true
    return 1
  fi

  # 3) 端口被本机其它进程占用时给出明确警告（reload 会失败并自动回滚）
  if port_in_use "$_web_ac_port" tcp; then
    if ! _web_port_is_ours "$_web_ac_port"; then
      log_warn "端口 ${_web_ac_port} 已被本机其它进程占用，nginx 可能无法监听该端口"
    fi
  fi

  _web_ac_tpl="$(state_get .web.template)"
  if ! _web_template_known "$_web_ac_tpl"; then _web_ac_tpl="blog"; fi

  if ! _web_conf_write "$_web_ac_tpl" 1; then
    return 1
  fi
  if ! web_reload; then
    log_err "nginx 校验/重载失败，已回滚 443 配置"
    _web_conf_rollback
    state_set ".web.tls" "false" >/dev/null 2>&1 || true
    return 1
  fi
  log_ok "已写入 443（HTTPS）站点配置：$_web_ac_conf"
  log_info "证书：$_web_ac_crt"
  return 0
}

# 端口是否被本工具自己的伪装站点占用（配置里声明了 listen 且 nginx 已安装）
_web_port_is_ours() {
  local _web_po_port="${1-}" _web_po_conf
  _web_po_conf="$(_web_conf_file)"
  if [ ! -f "$_web_po_conf" ]; then return 1; fi
  if ! grep -qE "^[[:space:]]*listen[[:space:]]+(\[::\]:)?${_web_po_port}([[:space:]]|;|\$)" "$_web_po_conf" 2>/dev/null; then
    return 1
  fi
  web_installed || return 1
  return 0
}

# 0 = 端口可用（空闲，或只被本工具自己的伪装站点占用）
web_port_free() {
  local _web_pf_port="${1-}"
  if ! validate_port "$_web_pf_port" >/dev/null 2>&1; then
    error "端口无效：${_web_pf_port:-（空）}（应为 1-65535 的整数）"
    return 1
  fi
  if ! port_in_use "$_web_pf_port" tcp; then
    return 0
  fi
  if _web_port_is_ours "$_web_pf_port"; then
    log_debug "端口 $_web_pf_port 由本工具的伪装站点占用，视为可用"
    return 0
  fi
  log_warn "端口 $_web_pf_port 已被其它进程占用"
  return 1
}
