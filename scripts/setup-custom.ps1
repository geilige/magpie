<#
.SYNOPSIS
    magpie 定制版的一次性引导：加 upstream remote、建 custom 分支、设置三项 git 配置。

.DESCRIPTION
    幂等：重复运行安全，已完成的步骤打印 skipped。
    顺序：校验仓库 -> upstream remote -> custom 分支 -> git 配置。
    每一步失败立即停下并保留现场（不改回、不猜意图）。

    退出码：
      0  成功（含全部 skipped）
      1  出错，已停下

    绝不执行：push、reset --hard、clean、rm，以及除 git fetch 之外的任何网络操作。
    注意：本脚本本身不 fetch，只在 main 不存在时提示你自己 fetch。

.NOTES
    三项配置一律写到 --local（仓库级），避免读到的全局值伪装成「已配置」：
      rerere.enabled      true     记住解过的冲突，上游日更场景省重复劳动
      merge.conflictStyle zdiff3   冲突块多显示一个共同祖先版本，少猜
      pull.rebase         false    pull 一律 merge，别偷偷 rebase 掉合并点
#>

[CmdletBinding()]
param()

# 原生命令的 stderr 在 Stop 下会变成终止错误、吞掉 git 原始报错，这里统一 Continue，
# 成败靠 $LASTEXITCODE 判断。
$ErrorActionPreference = 'Continue'

$ExpectedUpstreamUrl = 'https://github.com/yetone/magpie.git'
$CustomBranch = 'custom'
$BaseBranch = 'main'

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
    param([string]$Message)
    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Write-Host 'exit code: 1'
    exit 1
}

Write-Host 'setup-custom.ps1 - one-time bootstrap for the magpie custom branch'
Write-Host 'safe to re-run: finished steps are reported as skipped'

# ---- 1. 校验在 git 仓库内 ----
Write-Step '1/4 repository check'

$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $gitCmd) {
    Stop-With 'git not found in PATH.'
}

$rootOut = @(& git rev-parse --show-toplevel)
if ($LASTEXITCODE -ne 0) {
    Stop-With 'current directory is not inside a git repository (git rev-parse --show-toplevel failed).'
}
$RepoRoot = ''
if ($rootOut.Count -gt 0 -and $null -ne $rootOut[0]) { $RepoRoot = $rootOut[0].ToString().Trim() }
if ($RepoRoot -eq '') {
    Stop-With 'git rev-parse --show-toplevel returned an empty path.'
}
Write-Item "repository: $RepoRoot"

# ---- 2. upstream remote ----
Write-Step '2/4 upstream remote'

$remotes = @(& git -C $RepoRoot remote)
if ($LASTEXITCODE -ne 0) {
    Stop-With 'git remote failed.'
}
$remoteNames = @($remotes | Where-Object { $null -ne $_ } | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne '' })

if ($remoteNames -contains 'upstream') {
    $urlOut = @(& git -C $RepoRoot remote get-url upstream)
    if ($LASTEXITCODE -ne 0) {
        Stop-With 'upstream remote exists but its URL cannot be read.'
    }
    $currentUrl = ''
    if ($urlOut.Count -gt 0 -and $null -ne $urlOut[0]) { $currentUrl = $urlOut[0].ToString().Trim() }

    $normalizedCurrent = $currentUrl.TrimEnd('/')
    $normalizedExpected = $ExpectedUpstreamUrl.TrimEnd('/')

    if ($normalizedCurrent -ieq $normalizedExpected) {
        Write-Item "skipped: upstream already points to $currentUrl"
    } else {
        Stop-With "upstream already exists but points to '$currentUrl' (expected '$ExpectedUpstreamUrl'). Nothing was changed. If that URL is deliberate, keep it; otherwise run: git remote set-url upstream $ExpectedUpstreamUrl"
    }
} else {
    & git -C $RepoRoot remote add upstream $ExpectedUpstreamUrl
    if ($LASTEXITCODE -ne 0) {
        Stop-With "git remote add upstream failed (exit $LASTEXITCODE)."
    }
    Write-Item "added: upstream = $ExpectedUpstreamUrl"
}

# ---- 3. custom 分支 ----
Write-Step "3/4 branch $CustomBranch"

& git -C $RepoRoot show-ref --verify --quiet "refs/heads/$CustomBranch"
$branchCheckExit = $LASTEXITCODE

if ($branchCheckExit -eq 0) {
    $currentBranch = ''
    $branchOut = @(& git -C $RepoRoot rev-parse --abbrev-ref HEAD)
    if ($LASTEXITCODE -eq 0 -and $branchOut.Count -gt 0 -and $null -ne $branchOut[0]) {
        $currentBranch = $branchOut[0].ToString().Trim()
    }
    if ($currentBranch -eq $CustomBranch) {
        Write-Item "skipped: already on $CustomBranch"
    } else {
        & git -C $RepoRoot switch $CustomBranch
        if ($LASTEXITCODE -ne 0) {
            Stop-With "git switch $CustomBranch failed (exit $LASTEXITCODE). A dirty working tree is the usual cause; commit or stash first."
        }
        Write-Item "switched: $currentBranch -> $CustomBranch"
    }
} elseif ($branchCheckExit -eq 1) {
    & git -C $RepoRoot show-ref --verify --quiet "refs/heads/$BaseBranch"
    if ($LASTEXITCODE -ne 0) {
        Stop-With "local branch '$BaseBranch' not found, so '$CustomBranch' cannot be created from it. Run: git fetch origin $BaseBranch ; git switch $BaseBranch   then re-run this script."
    }
    & git -C $RepoRoot switch -c $CustomBranch $BaseBranch
    if ($LASTEXITCODE -ne 0) {
        Stop-With "git switch -c $CustomBranch $BaseBranch failed (exit $LASTEXITCODE)."
    }
    Write-Item "created: $CustomBranch from $BaseBranch"
} else {
    Stop-With "git show-ref failed (exit $branchCheckExit), cannot determine whether '$CustomBranch' exists."
}

# ---- 4. git 配置 ----
Write-Step '4/4 git config (repo-local)'

$settings = @(
    @{ Key = 'rerere.enabled';      Value = 'true'   },
    @{ Key = 'merge.conflictStyle'; Value = 'zdiff3' },
    @{ Key = 'pull.rebase';         Value = 'false'  }
)

foreach ($setting in $settings) {
    $oldOut = @(& git -C $RepoRoot config --local --get $setting.Key)
    $oldExit = $LASTEXITCODE

    $oldText = '(unset)'
    if ($oldExit -eq 0) {
        $joined = (@($oldOut) -join ' ').Trim()
        if ($joined -ne '') { $oldText = $joined } else { $oldText = '(empty)' }
    }

    if ($oldExit -eq 0 -and $oldText -ieq $setting.Value) {
        Write-Item ("{0}: skipped (already {1})" -f $setting.Key, $oldText)
        continue
    }

    & git -C $RepoRoot config --local $setting.Key $setting.Value
    if ($LASTEXITCODE -ne 0) {
        Stop-With ("git config --local {0} {1} failed (exit {2})." -f $setting.Key, $setting.Value, $LASTEXITCODE)
    }
    Write-Item ("{0}: {1} -> {2}" -f $setting.Key, $oldText, $setting.Value)
}

# ---- 完成 ----
Write-Step 'done'
Write-Item "branch: $CustomBranch"
Write-Item 'note   : commit PATCHES.md and scripts\ first - sync-upstream.ps1 refuses a dirty tree, and untracked files count as dirty'
Write-Item 'next   : scripts/sync-upstream.ps1 -DryRun   (preview the first sync)'
Write-Item 'reminder: this script never pushes; main stays a pure mirror of upstream'
exit 0
