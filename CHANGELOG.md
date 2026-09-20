# 变更记录

本文件记录 EasySB 项目的重要变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

脚本自身的版本号定义在 `EasySB/lib/00-header.sh` 的 `VERSION` 常量；内核版本独立于脚本版本，由 `EasySB/force_version` 与 Releases 管理。

## [未发布]

### 新增

- README 中英双语：`README.md` 为简体中文，`README_EN.md` 为 English，两页互相链接。
- GitHub 社区健康文件：Issue 表单（缺陷 / 功能请求）、Pull Request 模板、`CODEOWNERS`、Dependabot 配置。
- 仓库级文档与配置：`LICENSE`、`CHANGELOG.md`、`CONTRIBUTING.md`、`SECURITY.md`、`.editorconfig`、`.gitignore`。

### 变更

- 仓库根许可证统一为 GPL-3.0，与 `EasySB/` 和 `Release/` 中的 GPL-3.0 组件保持一致。

## [v1.3.25] - 2026-09-18

### 新增

- `Templates/config-rule.yaml`：Clash / Mihomo 订阅模板，内嵌节点与分流规则，不依赖 `proxy-providers`。
- `EasySB/lib/` 模块化源码（19 个模块），`EasySB/build.sh` 按编号合成单文件发行版。
- `EasySB/tests/` 测试套件，覆盖构建、文案、静态断言与 lint；`.github/workflows/easysb-release.yml` 在 CI 中执行。
- 本仓库自行编译并发布 sing-box 内核，`.github/workflows/build-release.yml` 覆盖多架构构建。

### 变更

- 订阅模板来源改为本仓库 `Templates/`，不再依赖上游 `fscarmen/client_template`。
  - `Templates/config.yaml`：Clash / Mihomo 订阅，使用 `proxy-providers`。
  - `Templates/config-rule.yaml`：Clash / Mihomo 订阅，自包含形式。
  - `Templates/config.json`：sing-box SFM / SFA / SFI 订阅。
- 脚本、内核与强制版本文件的远端地址统一指向本仓库 Releases。
- 内核兜底版本由 `1.15.0-alpha.6` 改为正式版 `1.14.1`。
- 内核版本解析只接受 `x.y.z` 正式版标签，过滤 `alpha`、`beta`、`rc` 预发布标签与脚本自身的 `easysb` 发布标签。

### 修复

- CDN 探测不再访问已删除的上游文件，改为探测本仓库的 `EasySB/force_version`。

### 移除

- 移除旧版单文件 sing-box 一键脚本，功能由 `EasySB/lib/` 模块化实现承接。

## 早期版本

`EasySB` 重构自 [fscarmen/sing-box](https://github.com/fscarmen/sing-box)。上游 1.3.x 系列的历史变更请参考上游仓库的提交记录，本项目在重构中完整保留了其功能与交互选项。
