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
| `.github/workflows/release.yml` | **整文件替换** | 自己的发布流水线：tag → 构建 → 清单 → 签名 → 溯源 → Release → `latest.json` → gh-pages。上游同名文件只做「转发给 magpie-releases + 镜像 release」，替换后那两个 job 不再存在 | M3b |
| `internal/update/attest.go` | 修改（2 行） | `attestRepo` → `geilige/magpie`。`attestID.SAN`、`attestID.Repo`、溯源 API 地址都由它拼出来，自动跟着变；workflow 因此必须叫 `release.yml` | M3b |
| `internal/update/fallback.go` | 修改（2 行） | `releaseRepo` → `geilige/magpie`：GitHub 回落读的 API、release 页面与下载地址 | M3b |
| `scripts/make-feed.ps1` | 新增 | 由 `SHA256SUMS` + `SHA256SUMS.sig` + `dist` 里的四个二进制生成 `latest.json`，写完读回来逐项自检（字段、字节、哈希、尺寸） | M3b |
| `scripts/setup-custom.ps1` | 新增 | 一次性引导：加 `upstream` remote、建 `custom`、开 `rerere`/`zdiff3`/`pull.rebase=false` | M1 |
| `scripts/sync-upstream.ps1` | 新增 | 日常同步：fetch → merge → 冲突预警 → 冒烟编译，退出码 0/10/11/12/13 | M1 |

### 说明

- **M2**：`workbuddy_instances.go` 靠替换 `Sync` 和 `Fields[0].Set` 两个闭包复用 `workbuddyBuild`，**没有改 `workbuddy.go`**。
  `agentenv.go` 那一行不是新功能，是上游守护测试的硬要求（`internal/agent/agentenv_test.go:65`）。
- **M3a**：`signingKey` 换成我们的公钥后，官方包在 `verify()` 就失败，覆盖不了定制版；
  `testdata/signed-sample.sig` 属于「换 key 必须跟着换的测试数据」，不是测试代码。
- **M3b**：`release.yml` 是上游文件，整文件替换——**冲突风险最高的一处**，上游每次改发布流程，
  同步时都要人工看一遍。`attestRepo` 换成我们自己的仓库后，15 条溯源测试永久红，见下一节。
- 路线：M1 同步骨架 → M2 多开实例 → M3a 换 key/feed → M3b 发布流水线；M3b 之后才谈「打 tag 能装上」。

## 已知红基线（`go test ./internal/update/`）

> 下面 15 条在换 `attestRepo` 之后**永久红**，不是我们的改动坏了。
> **清单内的忽略，清单外的一律当真问题查。**

**为什么关不掉**

`internal/update/attest_test.go:43-45` 的假服务器是这么断言请求的：

```go
if !strings.HasPrefix(r.URL.Path, "/repos/yetone/magpie-releases/attestations/sha256:") {
    t.Errorf("asked %s", r.URL.Path)
}
```

`attestRepo` 换成 `geilige/magpie` 之后，请求走 `/repos/geilige/magpie/attestations/sha256:…`，
于是**每一条走这个 API 的测试**都会被 `t.Errorf` 判红。这行是测试代码里硬编码的上游仓库名，
与 `testdata/attest/` 里的 fixture 内容**无关**：换 fixture 不会让它转绿，只有改 `*_test.go` 才行，
而那违反「不改上游测试」。

其中 5 条还多一层：fixture 的证书 SAN 是
`https://github.com/yetone/magpie-releases/.github/workflows/release.yml@refs/heads/main`，
而现在的 `attestID.SAN` 只认 `geilige/magpie`。即便把那行路径断言改掉，这几条的正向断言
（「真实 bundle 应当通过」）仍要等我们自己第一次发布产出 bundle 才会绿。

结论：这 15 条测的是「上游 fixture 与上游身份是否一致」，不是我们改动的行为。
我们自己的 attestation 链路另行验证：首次发布后用真实 API 跑 `attestedFile` 通过。

**逐条清单**（对照 `--- FAIL:` 的名字；红因 A = 假服务器断言上游仓库路径，B = 另有 fixture 的 SAN 是上游身份）

| # | 测试 | 它本来测什么 | 红因 |
|---|---|---|---|
| 1 | `TestAttestationFromTheSite` | 站点给的 bundles 能让文件通过 | A |
| 2 | `TestAttestationFromTheSiteOfAnotherDigestRefused` | 站点 bundle 的 digest 不对必须拒 | A |
| 3 | `TestAttestationSiteMissGoesToGitHub` | 站点没有时转问 GitHub | A+B |
| 4 | `TestAttestationSiteTamperedRefused` | 站点 bundle 被改过必须拒 | A+B |
| 5 | `TestAttestationFromTheSiteWrongIdentityRefused` | 站点 bundle 身份不对必须拒 | A |
| 6 | `TestAttestationSiteOnlyForTheSitesFiles` | 「只信站点」时不去问 GitHub | A+B |
| 7 | `TestAttestationOfARealBundleHolds` | 真实 bundle 必须通过（正向锚点） | A+B |
| 8 | `TestAttestationOfAnotherDigestRefused` | 别的 digest 的 bundle 必须拒 | A |
| 9 | `TestAttestationTamperedRefused` | 签名被改的 bundle 必须拒 | A |
| 10 | `TestAttestationEditedPayloadRefused` | payload 被改的 bundle 必须拒 | A |
| 11 | `TestAttestationWrongIdentityRefused` | 身份（repo / workflow / ref / issuer）不对必须拒 | A+B |
| 12 | `TestAttestationNoneListedRefused` | GitHub 说没有就拒 | A |
| 13 | `TestAttestationUnknownGoesOnAndSaysSo` | 读不到（5xx、超时）不算拒，只在日志说明 | A |
| 14 | `TestAttestationUnknownIsNotVerified` | 「unknown」不能被当成「已验证」 | A |
| 15 | `TestDownloadRefusedWithoutAttestation` | 没溯源就不装 | A |

另外两条常驻红与本项目无关，一并记下：`TestEnsureCompanion`、`TestPackagedByDpkg`
（Windows 上的既有失败，未改动时同样红）。

## 已知行为差异（instance 行 vs 默认行）

WorkBuddy 多开实例的行（`workbuddy#<n>`）与默认行不完全对等。两处缺失都是结构性的，不是漏写。

### 1. 没有「重启 X 后生效」提示与「重启」按钮

`internal/agent/apprestart.go` 的 `AppBehind()` 用 `restartApps[a.ID]` 查一张按**精确 ID**
索引的静态表（只有 `workbuddy`、`workbuddy-ai` 等）。`workbuddy#2` 查不到，函数直接返回 nil，
前端拿不到 `appRestart` 就不渲染这一段。

**为什么不补**：Windows 侧靠进程映像名匹配（`winExe: "WorkBuddy.exe"`），五个实例跑的是同一个
`WorkBuddy.exe`，匹配到哪一个取决于遍历顺序——补上会**重启错实例**，比没有按钮更糟。

**实测影响**：无。连接实例后不重启也立即生效（WorkBuddy 按需读取 `models.json`，而不是上游
`appReads` 假定的「启动时读一次」）。反过来看，默认行那条提示对 WorkBuddy 是误报。注意这只是
本机观测，不是能下结论的通用事实。

### 2. 没有「改动了 ‹path›　查看 ›」的 diff 预览

`internal/agent/preview.go` 的 `DisconnectPreview()` 要求 agent 的配置目录位于
`os.UserHomeDir()` 之下（它把整个目录复制到 `%TEMP%` 才算得出差异），否则返回
`the agent's files are outside home`。多开实例在 `D:\duokai\...`，被这条挡下，前端拿到空的
`changes` 就不显示这一行。

**为什么不补**：这条 guard 是安全边界——放开等于允许 magpie 把 home 之外任意位置的文件复制进
临时目录。为「看一眼改了什么」开这个口子不划算。

**影响**：只少一个只读视图。`断开并还原` 正常（走 `Field("provider").Set("")`）；想看差异直接
打开 `instance-<n>\config\models.json`，它就是个裸 JSON 数组。

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
internal/update/attest.go
internal/update/testdata/signed-sample.sig
.github/workflows/release.yml
scripts/setup-custom.ps1
scripts/sync-upstream.ps1
scripts/sign-release.ps1
scripts/make-feed.ps1
<!-- patches:end -->
