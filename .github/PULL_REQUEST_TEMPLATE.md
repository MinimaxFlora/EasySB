<!-- 提交前请先阅读 CONTRIBUTING.md -->

## 变更类型

请勾选本次改动涉及的类型：

- [ ] 新增功能（feat）
- [ ] 缺陷修复（fix）
- [ ] 文档更新（docs）
- [ ] 重构或清理（refactor / chore）
- [ ] 测试补充（test）

## 变更说明

<!-- 说明改动的动机、做法与影响范围。涉及脚本改动时，请写清改动发生在哪个模块。 -->

## 关联 Issue

<!-- 例如：Closes #12；没有关联 Issue 可写"无" -->

## 自测清单

- [ ] `bash EasySB/build.sh --check` 通过
- [ ] `bash EasySB/tests/run-tests.sh` 全部通过
- [ ] 改动了远端地址、常量或模板时，已同步更新 `EasySB/tests/test-static.sh` 的断言
- [ ] 改动了界面文案时，`EasySB/lib/01-i18n.sh` 的中英文条目已同时补齐
- [ ] 改动了功能或选项时，已更新 `EasySB/docs/FEATURE-MAP.md` 与 `CHANGELOG.md`
- [ ] 未提交 `EasySB/dist/` 等构建产物
- [ ] 未提交任何密钥、UUID、证书私钥、域名或订阅 token

## 补充信息

<!-- 测试环境（系统与架构、所用协议）、验证方式，或需要评审者特别关注的地方。 -->
