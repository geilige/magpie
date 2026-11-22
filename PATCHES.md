# 定制补丁登记

> 这张表有两个用途：
> 1. **给人看**：每个文件为什么改、上游原逻辑是什么（配合 DESIGN.md 的 P4 纪律）。
> 2. **给脚本读**：`scripts/sync-upstream.ps1` 只读下面标记块里的路径，用来在每次合并上游后提示
>    「哪些我们改过的文件，上游这次也动了」。
>
> 每次新增或修改补丁，都要同步更新这张表和下面的标记块。加补丁不改表，等于关掉冲突预警。

## 补丁清单

| 文件 | 类型 | 理由 | 需求 |
|---|---|---|---|
| `internal/agent/workbuddy_instances.go` | 新增 | 枚举 `WORKBUDDY_INSTANCES_ROOT` 下的 `instance-<n>\config`，每个实例产出一行 Agent。行 ID 唯一（`workbuddy#N`），写 `models.json` 仍按 `workbuddy` 语义 | R7 |
| `internal/agent/workbuddy_instances_test.go` | 新增 | 上面那个文件的测试：枚举、按数字排序、写出的必须是裸数组、与默认行去重、在 `onMachine` 里注册上了 | R7 |
| `internal/agent/agents.go` | 修改（+1 行） | `onMachineAll` 收尾的 append 链尾追加 `workbuddyInstances(home)...` | R7 |
| `internal/agentenv/agentenv.go` | 修改（+1 行） | `Vars` 加 `WORKBUDDY_INSTANCES_ROOT`。`TestFolderVarsAreListed` 要求 package agent 读的每个目录变量都在 `Vars` 里，否则每个 sandbox 都不会清它，测试会读到开发机真实的实例目录 | R7 |
| `internal/update/signed.go` | 修改（2 行） | `signingKey` 换成我们自己的 ed25519 公钥，并把注释说清「不是上游那把」。官方包因此验签失败，覆盖不了定制版 | M3a |
| `internal/update/fallback.go` | 修改（1 行） | `siteFeed` 从 `Site + "/api/latest"` 换成 `https://geilige.github.io/magpie/latest.json`。`Site` 常量不动（attest 与文档链接还在用） | M3a |
| `internal/update/testdata/signed-sample.sig` | 修改（重签） | `TestEmbeddedKeyVerifiesCIsSignature` 用**内嵌公钥**验这份样本，换 key 后必须用我们的私钥对同一份 `.msg` 重签，否则该测试红。`.msg` 一字未改 | M3a |
| `scripts/sign-release.ps1` | 新增 | 发布时给 `SHA256SUMS` 签名（ed25519 / `-rawin`），并带 `-Verify` 自验；格式与 `verify()` 逐字节一致 | M3a |
| `scripts/setup-custom.ps1` | 新增 | 一次性引导：加 `upstream` remote、建 `custom`、开 `rerere`/`zdiff3`/`pull.rebase=false` | M1 |
| `scripts/sync-upstream.ps1` | 新增 | 日常同步：fetch → merge → 冲突预警 → 冒烟编译，退出码 0/10/11/12/13 | M1 |

### 说明

- **M2**：`workbuddy_instances.go` 靠替换 `Sync` 和 `Fields[0].Set` 两个闭包复用 `workbuddyBuild`，**没有改 `workbuddy.go`**。
  `agentenv.go` 那一行不是新功能，是上游守护测试的硬要求（`internal/agent/agentenv_test.go:65`）。
- **M3a**：`signed.go` 是我们唯一在 `internal/update/` 里动逻辑的地方；`attest.go` 一个字没动，构建溯源留到 M3b。
  `testdata/signed-sample.sig` 属于「换 key 必须跟着换的测试数据」，不是测试代码：`.msg` 保持原样，重签后
  `TestEmbeddedKeyVerifiesCIsSignature` 仍然在验证「内嵌公钥 = 我们 CI 签名用的那把」。
- M3b 计划：`.github/workflows/release-custom.yml` + `attestRepo` 换成我们自己的仓库，届时再登记。
- `internal/update/` 里除 `signed.go`、`fallback.go`、`testdata/signed-sample.sig` 之外没有任何改动。

## 机器可读区

读取规则（同步脚本按此实现，改格式必须同步改脚本）：

1. 只取 `patches:begin` 与 `patches:end` 之间的行
2. 去掉每行首尾空白
3. 跳过空行、跳过以 `#` 开头的行
4. 路径统一用 `/` 分隔（脚本内部会把 `\` 归一成 `/`，两边写哪种都能匹配）

<!-- patches:begin -->
internal/agent/workbuddy_instances.go
internal/agent/workbuddy_instances_test.go
internal/agent/agents.go
internal/agentenv/agentenv.go
internal/update/signed.go
internal/update/fallback.go
internal/update/testdata/signed-sample.sig
scripts/setup-custom.ps1
scripts/sync-upstream.ps1
scripts/sign-release.ps1
<!-- patches:end -->
