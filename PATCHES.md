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

### 说明

- M2 已落地。三个源码文件的改动与计划一致；多出来的 `agentenv.go` 一行不是新功能，是上游守护测试的硬要求
  （`internal/agent/agentenv_test.go:65`），不加则 `go test ./internal/agent` 红。
- `workbuddy_instances.go` 靠替换 `Sync` 和 `Fields[0].Set` 两个闭包来复用 `workbuddyBuild`，**没有改 `workbuddy.go`**。
  上游若重构 `workbuddyBuild` 的内部实现，坏在运行期而不是编译期：详见该文件顶部注释。
- `internal/update/signed.go`、`internal/update/update.go` 属于 M3 的更新源改造，等实际改完再登记，
  不要提前写进来（会让预警一直报「上游也在动」的假信号）。

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
<!-- patches:end -->
