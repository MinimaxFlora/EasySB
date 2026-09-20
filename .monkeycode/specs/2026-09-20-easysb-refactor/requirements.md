# Requirements Document

## Introduction

在仓库根目录新增 `EasySB/`，把上游 `fscarmen/sing-box` 一键脚本重构为本项目自有发行版。
功能、菜单与交互选项与上游保持一致，仅重写项目归属信息、远端资源地址与源码组织方式。

## Glossary

- **EasySB**：本项目一键部署脚本，源码位于 `EasySB/lib/`，发行文件为 `EasySB/dist/easysb.sh`。
- **上游 / Upstream**：参考项目 `https://github.com/fscarmen/sing-box`。
- **发行脚本**：由 `EasySB/build.sh` 合成的单文件脚本，用于 `bash <(curl ...)` 安装。
- **模块**：`EasySB/lib/` 下按功能拆分的源码文件。
- **协议代号**：`b`-`m` 十二个协议代号，`a` 表示全部协议。

## Requirements

### Requirement 1

**User Story:** AS 仓库维护者, I want 在 `EasySB/` 下拥有一套可维护的一键脚本源码, so that 我能独立迭代并发布本项目脚本。

#### Acceptance Criteria

1. THE EasySB SHALL 在仓库根目录提供 `EasySB/` 目录，内含源码、构建脚本、测试与配置模板。
2. THE EasySB SHALL 以 `EasySB/lib/` 作为唯一脚本源码，并按功能拆分为 19 个编号模块。
3. THE EasySB SHALL 由 `EasySB/build.sh` 按模块编号顺序合成单文件 `EasySB/dist/easysb.sh`。
4. THE EasySB SHALL 保持 `dist/` 目录不进入版本库。

### Requirement 2

**User Story:** AS VPS 用户, I want 用一条命令安装脚本, so that 我无需手动下载多个文件。

#### Acceptance Criteria

1. THE EasySB SHALL 支持 `bash <(curl -fsSL <脚本发行地址>)` 形式的一次性安装。
2. THE EasySB SHALL 在安装后创建 `sb` 快捷指令，且该指令从本仓库发行地址拉取最新脚本。
3. THE EasySB SHALL 通过 GitHub Actions 以固定标签 `easysb` 发布发行脚本资产 `easysb.sh`。

### Requirement 3

**User Story:** AS VPS 用户, I want 脚本功能与上游完全一致, so that 我原有的使用习惯与自动化参数不被破坏。

#### Acceptance Criteria

1. THE EasySB SHALL 提供与上游一致的 12 个协议，且协议代号 `a`-`m` 含义保持相同。
2. THE EasySB SHALL 提供与上游一致的命令行参数，包含 `-c` `-e` `-l` `-k` `-u` `-n` `-d` `-s` `-a` `-t` `-v` `-b` `-r`。
3. THE EasySB SHALL 提供与上游一致的主菜单与安装后菜单选项，包含 `0`-`12` 全部动作项。
4. THE EasySB SHALL 提供与上游一致的 KV 传参，包含 `--LANGUAGE` `--CHOOSE_PROTOCOLS` `--START_PORT` `--SERVER_IP` `--CDN` `--UUID_CONFIRM` `--SUBSCRIBE` `--ARGO` `--HY2_PORT_HOPPING_RANGE` `--HY2_REALM` `--REALITY_PRIVATE` `--NODE_NAME_CONFIRM` `--BIND_INTERFACE` 等。
5. THE EasySB SHALL 保留 Argo 隧道、Nginx 订阅站点、WARP 账户、Hysteria2 Realm、端口跳跃、防火墙规则与自定义路由管理等能力。

### Requirement 4

**User Story:** AS 仓库维护者, I want 脚本内只指向本仓库的核心资源, so that 内核与脚本版本由本项目统一控制。

#### Acceptance Criteria

1. THE EasySB SHALL 从本仓库 Releases 下载 sing-box 内核，并读取本仓库的 `EasySB/force_version` 作为强制版本。
2. THE EasySB SHALL 在脚本头部声明本项目地址 `https://github.com/MinimaxFlora/EasySB` 与参考项目地址 `https://github.com/fscarmen/sing-box`。
3. THE EasySB SHALL 在报错反馈信息中指向本仓库 Issues。
4. WHERE 能力来自第三方独立项目（Argo 辅助脚本、WARP 注册接口、客户端订阅模板、二维码程序），THE EasySB SHALL 继续引用对应上游地址。

### Requirement 5

**User Story:** AS 仓库维护者, I want 自动化校验, so that 模块拆分与后续改动不会破坏可运行性。

#### Acceptance Criteria

1. THE EasySB SHALL 在 `EasySB/tests/` 提供服务构建、核心工具、多语言文案、静态特征与静态语法五类测试。
2. WHEN 执行 `bash EasySB/tests/run-tests.sh`, THE EasySB SHALL 先合成发行脚本，再依次执行全部测试，并在任一测试失败时返回非零退出码。
3. THE EasySB SHALL 校验中英文文案条目下标一一对应且无空值。
4. THE EasySB SHALL 校验发行脚本中不存在重复的顶层函数定义。
5. THE EasySB SHALL 校验发行脚本中不残留上游脚本仓库的下载地址与反馈地址。

### Requirement 6

**User Story:** AS 仓库维护者, I want 明确的许可与来源声明, so that 衍生作品的合规性清晰可查。

#### Acceptance Criteria

1. THE EasySB SHALL 以 GPL-3.0 协议分发，并在 `EasySB/LICENSE` 提供完整协议文本。
2. THE EasySB SHALL 在脚本头部与 `EasySB/README.md` 同时声明上游参考项目与 GPL-3.0 衍生关系。
