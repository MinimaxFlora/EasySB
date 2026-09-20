# 贡献指南

感谢你参与 EasySB。本文说明提交问题与代码的流程，请先阅读再动手。

## 提交问题

- 缺陷与功能请求请使用仓库的 Issue 表单，表单会提示需要提供的信息。
- 报告缺陷时请附上脚本版本、系统与架构、所用协议，以及去除敏感信息后的配置与日志。
- **任何密钥、UUID、证书私钥、域名与订阅 token 都不要贴进 Issue。** 需要展示配置时请用占位值替换。
- 安全问题请按 [SECURITY.md](SECURITY.md) 私下报告，不要开公开 Issue。

## 源码约定

`EasySB/lib/*.sh` 是脚本的唯一源，文件名前缀决定合成顺序。`EasySB/dist/` 是构建产物，由 `EasySB/build.sh` 与 CI 生成，**不要提交**。

修改脚本时请直接编辑 `lib/` 下对应模块，不要编辑 `dist/easysb.sh`。

```bash
# 合成发行脚本
bash EasySB/build.sh

# 只做校验，不写文件
bash EasySB/build.sh --check
```

## 提交前必做

所有改动在提交前必须通过构建与完整测试：

```bash
# 运行全部测试套件
bash EasySB/tests/run-tests.sh
```

测试未通过时不要提交。若改动了以下内容，请同步更新对应断言或文档：

- 改动了远端地址、常量或模板：更新 `EasySB/tests/test-static.sh` 中的静态断言。
- 改动了界面文案：更新 `EasySB/lib/01-i18n.sh`，中英文条目必须同时存在。
- 改动了功能或选项：更新 `EasySB/docs/FEATURE-MAP.md` 与 [CHANGELOG.md](CHANGELOG.md)。

## 代码风格

- Shell 脚本缩进使用 2 个空格，遵循仓库根目录的 `.editorconfig`。
- 提交前请确保 `shellcheck` 无新增告警；仓库中已用到的解析限制在 `EasySB/tests/test-lint.sh` 的白名单内。
- 新增函数请写清用途，关键分支补中文注释，解释"为什么"而不是"做什么"。
- 文件统一使用 UTF-8 与 LF 换行，保留文件末尾换行。

## 分支与提交信息

从 `master` 切出特性分支，分支名建议使用 `feat/`、`fix/`、`docs/`、`chore/` 前缀，例如：

```bash
git checkout -b feat/add-shadowtls-template
```

提交信息使用约定式提交格式，范围（scope）使用模块名，描述可用中文：

```text
feat(EasySB): 新增 ShadowTLS 协议模板
fix(EasySB): 修复证书续期时的路径判断
docs(readme): 补充订阅模板说明
test(EasySB): 补充模板占位符断言
```

保持一次提交只做一件事，避免把格式化改动与功能改动混在同一次提交里。

## 提交 Pull Request

1. Fork 仓库并切出特性分支。
2. 完成改动，运行 `bash EasySB/tests/run-tests.sh` 直到全部通过。
3. 按仓库的 PR 模板填写变更说明、关联 Issue 与自测情况。
4. 创建 Pull Request，说明改动的动机、影响范围与验证方式。

PR 模板中的自测清单需要逐项确认，未完成的项目请说明原因。

## 协议

本项目遵循 GPL-3.0。提交代码即表示你同意以 GPL-3.0 协议分发你的贡献，并确认你有权这样做。
