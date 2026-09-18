# 测试沙箱契约（tests/）

开发机是 Windows（MSYS/git-bash），目标机是 Linux VPS，因此测试分三层：
**语法门 → 沙箱套件 → 真实 sing-box 解析器校验**（见 `linux-vps-script-tooling` 技能）。

## 运行

```bash
bash tests/run_tests.sh --list              # 列出全部用例
bash tests/run_tests.sh --unit              # 全部用例
bash tests/run_tests.sh --case <用例函数名>  # 单个用例
bash tests/audit.sh                         # 契约审计（公共函数是否齐全 / 违规模式扫描）
bash tests/real-parser.sh [版本…]            # 真实 sing-box 二进制校验（默认取本仓库 releases 最新 tag）
bash tests/acceptance.sh                    # 真机验收（在已部署的 VPS 上跑；沙箱证明不了的项都在这）
```

> `tests/acceptance.sh` 是给**目标 Linux 主机**用的：检查 systemd 服务与自启、配置能被已安装内核校验、
> 服务用户能否读到配置、协议端口监听、防火墙规则（含端口跳跃 DNAT）、伪装站点 HTTP/HTTPS 可访问、
> 订阅地址可访问且内容可解码、证书有效期与域名一致、客户端产物完整。
> 用法：`bash <(curl -fsSL <raw>/EasySB/tests/acceptance.sh)`，只读检查，不改任何配置。

> 真实二进制校验默认只用**本仓库 releases** 编译的内核（本仓库从 1.14 起）；
> 设 `ESB_REALPARSER_EXTRA=1` 才会额外拉官方旧版本，用于跨内核世代的兼容性证据。
> 安装路径（`sb_install`）永远只从本仓库 releases 下载。

退出码 0=全绿。结果写入 `$ESB_TEST_WORK/results.tsv`。

## 环境（由 runner 设置，用例不得自行覆盖）

| 变量 | 值 |
| --- | --- |
| `ESB_ROOT` | `$ESB_TEST_WORK/root`（每个用例独立、干净） |
| `ESB_GATE` | `1`（系统变更命令不执行，只记录） |
| `ESB_GATE_LOG` | `$ESB_TEST_WORK/gate.log` |
| `ESB_OFFLINE` | `1`（不联网） |
| `ESB_NO_COLOR` | `1` |
| `ESB_NO_PAUSE` | `1` |
| `ESB_ASSUME_YES` | `1` |
| `ESB_TEST_WORK` | `<repo>/tests/.work`（可用 `ESB_TEST_WORK=…` 覆盖，便于并行跑） |
| `PATH` | `tests/bin`（stub）: `tools/bin`（jq 等自带工具）: 原 PATH |

沙箱里有 stub 的外部命令（在 `tests/bin/`）：`systemctl`、`nginx`、`ufw`、`firewall-cmd`、`nft`、
`iptables`、`useradd`、`curl`、`wget`、`acme.sh`、`openssl`(可选真实)。stub 把自身调用追加到
`$ESB_TEST_WORK/stubs.log` 并按需输出固定文本；**stub 绝不能"什么命令都返回成功"**：只在被明确
调用时才记录与返回。

## 用例文件格式

`tests/cases/<name>.sh`：

```bash
# 用例文件由 runner source（已加载 lib/*.sh 与沙箱环境）
TESTS="test_1_xxx test_2_yyy"

test_1_xxx() {
  state_init || return 1
  assert_eq "$(proto_enabled_list)" "" "默认没有启用协议" || return 1
}
```

- 每个 `test_*` 函数返回 0=通过、非 0=失败；用 `assert_*` 给出可读原因。
- 每个用例在**独立子 shell + 独立沙箱根**中运行；不得依赖上一个用例的残留。
- 断言助手见 `tests/lib/harness.sh`（`assert_eq`、`assert_contains`、`assert_ok`、`assert_fail`、
  `assert_file`、`assert_json <file> <jq表达式> <期望>`）。
- 不许放宽断言来"修"失败；断言错就先用测量证明期望本身是错的。

## 硬性要求

1. 断言值，不只断言形状（"能解析成 JSON" 不算，要断言具体字段值）。
2. 每个断言都要能失败：新增断言后先手动把被测代码改坏一次，确认它会红。
3. 需要精确值的用例用固定输入（fixture），不用随机值。
4. 网络一律走 fixture（`ESB_OFFLINE=1` + `tests/fixtures/` 里的 JSON），禁止真联网。
