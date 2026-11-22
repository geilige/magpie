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
| `internal/agent/workbuddy_instances.go` | 新增 | 枚举 WorkBuddy 多开实例，每个实例产出一行 Agent（行 ID 唯一 `workbuddy#N`，写文件时仍按 `workbuddy` 处理） | R7 |
| `internal/agent/agents.go` | 修改（+1 行） | 在 `onMachineAll` 收尾的 append 链尾追加 `workbuddyInstances(home)...` | R7 |

### 说明

- 上面两行是 **M2 的计划**，待 M2 落地后核对实际改动：文件名、注册位置如有变化，同步改这张表和标记块。
- 现阶段标记块里已经列了这两个路径，所以同步脚本会报 `patch target missing upstream`：
  `workbuddy_instances.go` 还没创建，属于预期；`agents.go` 存在，不会报 missing，但要等 M2 提交后
  才会在「upstream also touched this file」里出现。
  M2 落地后若不想看到这条预期提示，删掉对应行即可 —— 但那时它就该真实存在了，别删。
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
internal/agent/agents.go
<!-- patches:end -->
