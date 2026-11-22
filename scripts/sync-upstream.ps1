<#
.SYNOPSIS
    把上游 yetone/magpie 合并进本地定制分支。只做本地改动，永不 push。

.DESCRIPTION
    一条命令完成：前置检查 -> fetch -> 判断是否最新 -> merge -> 冲突预警 -> 冒烟编译 -> 摘要。
    幂等：已是最新时直接退出 0，不产生空提交、不做任何写操作。

    退出码（任何路径都只返回这几个值）：
      0   成功。含「already up to date」与 -DryRun 正常结束
      10  合并冲突。仓库被故意留在合并状态，等你手工解决
      11  前置检查不通过；或合并在非冲突原因下中止
      12  合并成功，但 go build ./... 失败
      13  git fetch 失败

.PARAMETER UpstreamRemote
    上游 remote 名，默认 upstream。

.PARAMETER UpstreamBranch
    上游分支名，默认 main。

.PARAMETER CustomBranch
    本地定制分支名，默认 custom。前置检查要求当前分支就是它。

.PARAMETER PatchesFile
    补丁登记表路径。默认 <仓库根>\PATCHES.md；相对路径一律按仓库根解析。

.PARAMETER SkipBuild
    跳过 go build ./... 冒烟编译。

.PARAMETER DryRun
    只预测不动手：不碰工作区、索引、分支、HEAD。

.NOTES
    PATCHES.md 读取规则（与任务约定一致）：
      1. 只取 <!-- patches:begin --> 与 <!-- patches:end --> 之间的行
      2. 去掉每行首尾空白
      3. 跳过空行、跳过以 # 开头的行
      4. 反斜杠统一成 / 分隔
    本脚本不设置代理、不改 NO_PROXY、不调用 gh；除 git fetch 外不发任何网络请求。
    原生命令的 stderr 一律不重定向，git 的原始报错直接打到控制台。
#>

[CmdletBinding()]
param(
    [string]$UpstreamRemote = 'upstream',
    [string]$UpstreamBranch = 'main',
    [string]$CustomBranch   = 'custom',
    [string]$PatchesFile    = '',
    [switch]$SkipBuild,
    [switch]$DryRun
)

# PS 5.1 把原生命令的 stderr 包成 error record；$ErrorActionPreference='Stop' 时
# 连一条 warning 都会变成终止错误，把 git 的原始报错吞掉。这里固定 Continue，
# 成败一律靠 $LASTEXITCODE 判断，stderr 原样透传。
$ErrorActionPreference = 'Continue'

# ---------------- 输出小工具（终端输出全 ASCII，避免控制台代码页打乱中文） ----------------

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "== $Text"
}

function Write-Item {
    param([string]$Text)
    Write-Host "   $Text"
}

function Stop-With {
    param([int]$Code, [string]$Message)
    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Write-Host "exit code: $Code"
    exit $Code
}

# 取 git 单行输出；末尾统一 Trim，调用方自己查 $LASTEXITCODE
function Get-GitLine {
    param([string[]]$GitArgs)
    $out = @(& git -C $RepoRoot @GitArgs)
    if ($out.Count -eq 0) { return '' }
    if ($null -eq $out[0]) { return '' }
    return $out[0].ToString().Trim()
}

# 取 git 多行输出，去掉空行
function Get-GitLines {
    param([string[]]$GitArgs)
    $out = @(& git -C $RepoRoot @GitArgs)
    return @($out | Where-Object { $null -ne $_ } | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne '' })
}

# 只给「不解析 stdout、但会大量写 stderr」的命令用（fetch / merge）。
# 直接 & git 时，一旦调用方把输出重定向（*>log.txt），PS 5.1 会把 git 的正常进度
# 信息包成 NativeCommandError 红堆栈；合并 stderr 后逐条转发就不会。$LASTEXITCODE 不受影响。
function Invoke-GitPassthru {
    param([string[]]$GitArgs)
    & git -C $RepoRoot @GitArgs 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            Write-Host ("   " + $_.Exception.Message)
        } else {
            Write-Host ("   " + $_.ToString())
        }
    }
    return $LASTEXITCODE
}

# 从 PATCHES.md 标记块读补丁目标。
# 返回 hashtable：State = ok | missing-file | bad-markers | empty，以及 Targets / Message
function Get-PatchTargets {
    param([string]$FilePath)

    $result = @{ State = 'ok'; Targets = @(); Message = '' }

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        $result.State = 'missing-file'
        $result.Message = "patches file not found: $FilePath"
        return $result
    }

    $lines = @(Get-Content -LiteralPath $FilePath -Encoding UTF8)
    $inside = $false
    $sawBegin = $false
    $sawEnd = $false
    $targets = New-Object System.Collections.ArrayList

    foreach ($rawLine in $lines) {
        $line = ''
        if ($null -ne $rawLine) { $line = $rawLine.Trim() }

        if (-not $inside) {
            if ($line -eq '<!-- patches:begin -->') { $inside = $true; $sawBegin = $true }
            continue
        }
        if ($line -eq '<!-- patches:end -->') { $sawEnd = $true; break }
        if ($line -eq '') { continue }
        if ($line.StartsWith('#')) { continue }
        # 反斜杠归一成 /；顺手去掉 ./ 前缀，否则和 git 输出的路径对不上
        $path = $line -replace '\\', '/'
        while ($path.StartsWith('./')) { $path = $path.Substring(2) }
        if ($path -eq '') { continue }
        [void]$targets.Add($path)
    }

    if (-not $sawBegin) {
        $result.State = 'bad-markers'
        $result.Message = "marker <!-- patches:begin --> missing in $FilePath"
        return $result
    }
    if (-not $sawEnd) {
        $result.State = 'bad-markers'
        $result.Message = "marker <!-- patches:end --> missing in $FilePath"
        return $result
    }
    if ($targets.Count -eq 0) {
        $result.State = 'empty'
        $result.Message = "patch target list is empty in $FilePath"
        return $result
    }

    $result.Targets = @($targets.ToArray())
    return $result
}

# 冲突预警：上游本次改的文件 ∩ 我们的补丁文件；
# 另外单独报「补丁目标在仓库里已经不存在」。
# 返回预警条数（仅用于摘要），PATCHES.md 有问题时只警告不退出。
function Invoke-PatchWarning {
    param(
        [string]$PatchesPath,
        [string[]]$ChangedFiles,
        [string[]]$PredictedConflicts,
        [string]$TreeRef,
        [switch]$IsPrediction
    )

    $info = Get-PatchTargets -FilePath $PatchesPath
    if ($info.State -ne 'ok') {
        Write-Item "WARN: $($info.Message)"
        Write-Item 'patch risk check skipped (warning only, not a failure)'
        return 0
    }

    $changedKeys = @{}
    foreach ($f in $ChangedFiles) {
        if ($null -ne $f -and $f -ne '') { $changedKeys[$f.ToLowerInvariant()] = $f }
    }
    $conflictKeys = @{}
    foreach ($f in $PredictedConflicts) {
        if ($null -ne $f -and $f -ne '') { $conflictKeys[$f.ToLowerInvariant()] = $true }
    }

    # 用 TreeRef 判断补丁目标还在不在（-DryRun 时传 merge-tree 预测出来的树）
    $treeKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    $treeOk = $false
    $treeOut = @(& git -C $RepoRoot -c core.quotePath=false ls-tree -r --name-only $TreeRef)
    if ($LASTEXITCODE -eq 0) {
        $treeOk = $true
        foreach ($f in $treeOut) {
            if ($null -ne $f -and $f.Trim() -ne '') { [void]$treeKeys.Add($f.Trim().ToLowerInvariant()) }
        }
    }

    $touched = 0
    $missing = 0
    $untouched = 0

    foreach ($target in $info.Targets) {
        $key = $target.ToLowerInvariant()
        if ($changedKeys.ContainsKey($key)) {
            $touched = $touched + 1
            $suffix = ''
            if ($conflictKeys.ContainsKey($key)) { $suffix = '   [predicted conflict]' }
            Write-Host "     * $target   (upstream also touched this file)$suffix"
            continue
        }
        if ($treeOk -and -not $treeKeys.Contains($key)) {
            $missing = $missing + 1
            Write-Host "     * $target   (patch target missing upstream)"
            continue
        }
        $untouched = $untouched + 1
    }

    if ($IsPrediction) {
        Write-Item "patch targets: $($info.Targets.Count) total, $touched touched, $missing missing, $untouched untouched (prediction)"
    } else {
        Write-Item "patch targets: $($info.Targets.Count) total, $touched touched, $missing missing, $untouched untouched"
    }
    if ($touched -eq 0 -and $missing -eq 0) {
        Write-Item 'no patch file was touched by this upstream update - no new conflict risk'
    }
    return ($touched + $missing)
}

# ---------------- 主流程 ----------------

Write-Host 'sync-upstream.ps1 - merge upstream into the custom branch (local only, never pushes)'
if ($DryRun) {
    Write-Host 'mode: DRY RUN - worktree, index, branch and HEAD are not touched'
}

# ---- 1. 前置检查 ----
Write-Step '1/7 preconditions'

$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $gitCmd) {
    Stop-With 11 'git not found in PATH.'
}

$rootOut = @(& git rev-parse --show-toplevel)
if ($LASTEXITCODE -ne 0) {
    Stop-With 11 'not inside a git repository (git rev-parse --show-toplevel failed).'
}
$RepoRoot = ''
if ($rootOut.Count -gt 0 -and $null -ne $rootOut[0]) { $RepoRoot = $rootOut[0].ToString().Trim() }
if ($RepoRoot -eq '') {
    Stop-With 11 'git rev-parse --show-toplevel returned an empty path.'
}
Write-Item "repository : $RepoRoot"

# 补丁表路径：默认 <仓库根>\PATCHES.md，相对路径按仓库根解析
$patchesPath = ''
if ($PatchesFile -eq '') {
    $patchesPath = Join-Path $RepoRoot 'PATCHES.md'
} elseif ([System.IO.Path]::IsPathRooted($PatchesFile)) {
    $patchesPath = $PatchesFile
} else {
    $patchesPath = Join-Path $RepoRoot $PatchesFile
}
Write-Item "patches    : $patchesPath"

$currentBranch = Get-GitLine @('rev-parse', '--abbrev-ref', 'HEAD')
if ($LASTEXITCODE -ne 0) {
    Stop-With 11 'cannot read the current branch (detached HEAD, or the repository has no commit yet).'
}
if ($currentBranch -ne $CustomBranch) {
    Stop-With 11 "current branch is '$currentBranch', but this script only merges into '$CustomBranch'. Run: git switch $CustomBranch"
}
Write-Item "branch     : $currentBranch"

$statusOut = @(& git -C $RepoRoot status --porcelain)
if ($LASTEXITCODE -ne 0) {
    Stop-With 11 "git status failed (exit $LASTEXITCODE)."
}
$dirty = @($statusOut | Where-Object { $null -ne $_ -and $_.ToString().Trim() -ne '' })
if ($dirty.Count -gt 0) {
    Write-Item "working tree is NOT clean: $($dirty.Count) entries (untracked files count as dirty)"
    $shown = 0
    foreach ($line in $dirty) {
        if ($shown -ge 10) { break }
        Write-Host "     $($line.ToString())"
        $shown = $shown + 1
    }
    if ($dirty.Count -gt $shown) {
        Write-Host "     ... $($dirty.Count - $shown) more"
    }
    Stop-With 11 'refusing to merge over a dirty working tree. Commit, stash or delete those entries, then re-run.'
}
Write-Item 'working tree: clean'

$remotes = @(& git -C $RepoRoot remote)
if ($LASTEXITCODE -ne 0) {
    Stop-With 11 'git remote failed.'
}
$remoteNames = @($remotes | Where-Object { $null -ne $_ } | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne '' })
if (-not ($remoteNames -contains $UpstreamRemote)) {
    Write-Item "remotes    : $($remoteNames -join ', ')"
    Stop-With 11 "remote '$UpstreamRemote' not found. Add it with: git remote add $UpstreamRemote https://github.com/yetone/magpie.git  (scripts/setup-custom.ps1 does this)"
}
$remoteUrl = Get-GitLine @('remote', 'get-url', $UpstreamRemote)
Write-Item "remote     : $UpstreamRemote = $remoteUrl"

# ---- 2. 记录合并前状态 ----
Write-Step '2/7 before-state'

$beforeSha = Get-GitLine @('rev-parse', 'HEAD')
if ($LASTEXITCODE -ne 0 -or $beforeSha -eq '') {
    Stop-With 11 'cannot resolve HEAD (empty repository?).'
}
Write-Item "HEAD before: $beforeSha"

# ---- 3. fetch ----
Write-Step '3/7 fetch'

Write-Item "`$ git fetch $UpstreamRemote $UpstreamBranch"
$fetchExit = Invoke-GitPassthru @('fetch', $UpstreamRemote, $UpstreamBranch)
if ($fetchExit -ne 0) {
    Stop-With 13 "git fetch $UpstreamRemote $UpstreamBranch failed (exit $fetchExit). Nothing was merged."
}

$fetchSha = Get-GitLine @('rev-parse', 'FETCH_HEAD')
if ($LASTEXITCODE -ne 0 -or $fetchSha -eq '') {
    Stop-With 13 'fetch reported success but FETCH_HEAD cannot be resolved.'
}
Write-Item "upstream tip: $fetchSha"

# ---- 4. 判断是否已最新 ----
Write-Step '4/7 compare'

$countText = Get-GitLine @('rev-list', '--count', "HEAD..$fetchSha")
if ($LASTEXITCODE -ne 0) {
    Stop-With 11 'git rev-list failed.'
}
$incoming = 0
if (-not [int]::TryParse($countText, [ref]$incoming)) {
    Stop-With 11 "cannot parse the commit count from git output: '$countText'"
}
Write-Item "commits to pull: $incoming"

if ($incoming -eq 0) {
    Write-Host ''
    Write-Host 'already up to date - nothing to merge, no commit created, nothing pushed.'
    Write-Item "HEAD unchanged: $beforeSha"
    exit 0
}

# ---- 5. 预测（-DryRun）或真正合并 ----
if ($DryRun) {
    Write-Step '5/7 dry run: impact preview (no writes)'

    # 上游「本次改了什么」必须用三点比较：merge-base -> 上游 tip。
    # $beforeSha（我们的 tip）和 $fetchSha 不是祖先关系，直接 diff 两点等于比两棵完整的树，
    # 会把我们自己的提交也算成「上游改动」，冲突预警就天天报假警报。
    $baseSha = Get-GitLine @('merge-base', $beforeSha, $fetchSha)
    if ($LASTEXITCODE -ne 0 -or $baseSha -eq '') {
        Stop-With 11 'git merge-base failed; cannot tell which files upstream changed. Nothing was merged.'
    }
    $changed = @(Get-GitLines @('-c', 'core.quotePath=false', 'diff', '--name-only', $baseSha, $fetchSha))
    Write-Item "files changed by upstream: $($changed.Count)"
    $shownFiles = 0
    foreach ($f in $changed) {
        if ($shownFiles -ge 15) { break }
        Write-Host "     $f"
        $shownFiles = $shownFiles + 1
    }
    if ($changed.Count -gt $shownFiles) {
        Write-Host "     ... $($changed.Count - $shownFiles) more"
    }

    # merge-tree --write-tree 只写对象库里的树对象，不动工作区/索引/HEAD。
    # 输出：第一行 tree oid，其后每行一个冲突路径（--name-only --no-messages）。
    # 有冲突退出 1，干净退出 0；坏引用同样是 1，所以必须校验首行是不是 oid。
    $treeOut = @(& git -C $RepoRoot -c core.quotePath=false merge-tree --write-tree --name-only --no-messages HEAD $fetchSha)
    $mtExit = $LASTEXITCODE
    $mtLines = @($treeOut | Where-Object { $null -ne $_ } | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne '' })

    $treeOid = ''
    if ($mtLines.Count -ge 1 -and $mtLines[0] -match '^[0-9a-fA-F]{40,64}$') {
        $treeOid = $mtLines[0]
    }
    $predicted = @()
    if ($treeOid -ne '' -and $mtLines.Count -gt 1) {
        $predicted = @($mtLines[1..($mtLines.Count - 1)])
    }

    if ($treeOid -eq '') {
        Write-Item "cannot predict conflicts with this git version (merge-tree --write-tree gave no usable tree, exit $mtExit)"
        Write-Item 'nothing was merged; re-run without -DryRun when you are ready'
    } elseif ($predicted.Count -eq 0) {
        Write-Item 'predicted conflicts: none'
    } else {
        Write-Item "predicted conflicts: $($predicted.Count) file(s)"
        foreach ($f in $predicted) {
            Write-Host "     $f"
        }
    }

    Write-Step '5/7 dry run: patch risk'
    $treeRef = 'HEAD'
    if ($treeOid -ne '') { $treeRef = $treeOid }
    $riskCount = Invoke-PatchWarning -PatchesPath $patchesPath -ChangedFiles $changed -PredictedConflicts $predicted -TreeRef $treeRef -IsPrediction

    Write-Step 'dry run summary'
    Write-Item "would pull $incoming commit(s), $($changed.Count) file(s) changed"
    Write-Item "HEAD stays at $beforeSha; worktree, index and branch untouched"
    Write-Item 'build: not run in dry run'
    Write-Item "patch warnings: $riskCount"
    exit 0
}

Write-Step '5/7 merge'

# 合并提交信息写成人能看懂的同步动作，而不是默认的 Merge commit '<sha>' into custom
$mergeMessage = "Merge upstream $UpstreamBranch into $CustomBranch"
Write-Item "`$ git merge --no-edit -m `"$mergeMessage`" $fetchSha"
$mergeExit = Invoke-GitPassthru @('merge', '--no-edit', '-m', $mergeMessage, $fetchSha)

if ($mergeExit -ne 0) {
    $unmerged = @(Get-GitLines @('-c', 'core.quotePath=false', 'diff', '--name-only', '--diff-filter=U'))
    if ($unmerged.Count -gt 0) {
        Write-Step 'merge conflict'
        Write-Item "conflicted files: $($unmerged.Count)"
        foreach ($f in $unmerged) {
            Write-Host "     $f"
        }
        Write-Item 'the repository is left IN THE MERGE STATE on purpose: no abort, no auto side-picking, no -X'
        Write-Item 'resolve by hand, then: git add <file> ... ; git commit'
        Write-Item "give up with: git merge --abort   (returns to $beforeSha)"
        Stop-With 10 "merge stopped with conflicts in $($unmerged.Count) file(s). Nothing was aborted. Resolve them, 'git add', 'git commit', then run 'go build ./...' yourself - the next run of this script will only report 'already up to date'."
    }
    Stop-With 11 "git merge failed for a reason other than a conflict (exit $mergeExit). See the git output above; the repository was left exactly as git left it."
}

$afterSha = Get-GitLine @('rev-parse', 'HEAD')
if ($LASTEXITCODE -ne 0 -or $afterSha -eq '') {
    Stop-With 11 'merge reported success but HEAD cannot be resolved.'
}

# ---- 6. 合并后状态 ----
Write-Step '6/7 post-merge state'

# 拉入提交数直接用合并前的 $incoming（HEAD..FETCH_HEAD 的计数）。
# 不能用 rev-list before..HEAD：合并提交本身会被算进去，显示的数字比实际多 1。
$changedMerged = @(Get-GitLines @('-c', 'core.quotePath=false', 'diff', '--name-only', $beforeSha, 'HEAD'))
Write-Item "HEAD after : $afterSha"
Write-Item "commits pulled: $incoming"
Write-Item "files changed : $($changedMerged.Count)"

# ---- 7. 冲突预警 ----
Write-Step '7/7 patch risk'
$riskCount = Invoke-PatchWarning -PatchesPath $patchesPath -ChangedFiles $changedMerged -PredictedConflicts @() -TreeRef 'HEAD'

# ---- 冒烟编译 ----
Write-Step 'smoke build'

$buildResult = ''
if ($SkipBuild) {
    Write-Item 'go build skipped (-SkipBuild)'
    $buildResult = 'skipped (-SkipBuild)'
} else {
    $goCmd = Get-Command go -ErrorAction SilentlyContinue
    if ($null -eq $goCmd) {
        Write-Item 'go not found, skipping build'
        $buildResult = 'skipped (go not found)'
    } else {
        Write-Item '$ go build ./...'
        Push-Location -LiteralPath $RepoRoot
        & go build ./...
        $buildExit = $LASTEXITCODE
        Pop-Location
        if ($buildExit -ne 0) {
            Stop-With 12 "the merge SUCCEEDED but 'go build ./...' failed (exit $buildExit). The merge commit is already in place: either upstream itself is broken, or a conflict was resolved wrongly. A build failure is NOT a merge failure."
        }
        $buildResult = 'ok'
    }
}

# ---- 摘要 ----
Write-Step 'summary'
Write-Item "HEAD       : $($beforeSha.Substring(0, 8)) -> $($afterSha.Substring(0, 8))"
Write-Item "commits    : $incoming pulled from upstream"
Write-Item "files      : $($changedMerged.Count) changed"
Write-Item "patch risk : $riskCount warning(s)"
Write-Item "build      : $buildResult"
Write-Item 'nothing was pushed - review the merge, then push yourself.'
exit 0
