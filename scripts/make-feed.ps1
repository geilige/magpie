<#
.SYNOPSIS
    由 SHA256SUMS + SHA256SUMS.sig + dist 里的四个二进制，生成更新用的 latest.json。

.DESCRIPTION
    结构严格对应 internal/update/update.go 的 Release / Asset：
        version  string           不带 v，例如 0.1.4657-custom.1
        notes    string
        url      string           Release 页面
        assets   map[name]Asset   只放二进制，每个 url / size / sha256
        signed   {sums, sig}      sums 是 SHA256SUMS 的原文（含行尾），sig 是 base64

    退出码：
      0  成功
      1  参数错误：版本带 v 或含非法字符、-Repo 不是 owner/name
      2  SHA256SUMS 不存在/为空/含 CR/行格式不对，或缺 SHA256SUMS.sig
      3  dist 里缺文件，或文件哈希与清单不一致
      4  写盘失败，或写出来的 JSON 读回来与输入对不上

.PARAMETER Version
    必填，不带 v。

.PARAMETER Repo
    必填，"owner/name"，用来拼 Release 页面与下载地址。

.PARAMETER SumsPath
    SHA256SUMS 的文件路径或它所在的目录，默认当前目录。

.PARAMETER DistPath
    四个二进制所在目录，默认 dist。

.PARAMETER OutPath
    输出文件，默认 latest.json（与 SumsPath 同一目录的概念，但按给定路径写）。

.PARAMETER Notes
    写进 feed 的说明。默认「基于上游 v<base> 的定制版」。

.NOTES
    assets 里绝不能出现 SHA256SUMS、SHA256SUMS.sig 或 latest.json：
    Release.verify() 会拿签名清单核对每个资产，清单里没有它们就整包拒收。
#>

[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$Repo = '',
    [string]$SumsPath = '',
    [string]$DistPath = 'dist',
    [string]$OutPath = 'latest.json',
    [string]$Notes = ''
)

$ErrorActionPreference = 'Continue'

# 发布产物名：与 Makefile 的 release-windows / release-cli 逐字符一致，
# 也正是 update.BinaryAsset() 在客户端去找的名字。错一个字符就当没有这个包。
$AssetNames = @(
    'magpie-windows-amd64.exe',
    'magpie-windows-arm64.exe',
    'magpie-cli-windows-amd64.exe',
    'magpie-cli-windows-arm64.exe'
)

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

# 相对路径按 PowerShell 的当前位置解析，不能用 [System.IO.Path]::GetFullPath：
# 后者按 .NET 的 CurrentDirectory 解析，而 Set-Location 不会改它，两者可以不同。
# GetUnresolvedProviderPathFromPSPath 允许目标还不存在，正好解析还没写出的 latest.json。
function Resolve-FullPath {
    [CmdletBinding()]
    param([string]$Path)
    if ($Path -eq '') { return '' }
    return $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
}

Write-Host 'make-feed.ps1 - write latest.json for the magpie custom feed'

# ---------------- 参数 ----------------

if ($Version -eq '') {
    Stop-With 1 'no -Version. Pass the feed version without v, e.g. -Version 0.1.4657-custom.1'
}
if ($Version.StartsWith('v') -or $Version.StartsWith('V')) {
    Stop-With 1 ("version must not start with v: '{0}' - the feed's version has no v" -f $Version)
}
if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z.+_-]*$') {
    Stop-With 1 ("version has characters the feed cannot carry: '{0}'" -f $Version)
}
if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    Stop-With 1 ("-Repo must be owner/name, got '{0}'" -f $Repo)
}

# ---------------- 清单与签名 ----------------

if ($SumsPath -eq '') { $SumsPath = (Get-Location).Path }
if (Test-Path -LiteralPath $SumsPath -PathType Container) {
    $sumsFile = Join-Path $SumsPath 'SHA256SUMS'
} else {
    $sumsFile = $SumsPath
}
$sumsFile = Resolve-FullPath $sumsFile
$sumsDir = [System.IO.Path]::GetDirectoryName($sumsFile)
$sigFile = Join-Path $sumsDir 'SHA256SUMS.sig'
$outFull = Resolve-FullPath $OutPath

Write-Item "sums    : $sumsFile"
Write-Item "dist    : $DistPath"
Write-Item "out     : $outFull"

if (-not (Test-Path -LiteralPath $sumsFile -PathType Leaf)) {
    Stop-With 2 ("SHA256SUMS not found: {0}" -f $sumsFile)
}
$sumsBytes = [System.IO.File]::ReadAllBytes($sumsFile)
if ($sumsBytes.Length -eq 0) {
    Stop-With 2 ("SHA256SUMS is empty: {0}" -f $sumsFile)
}
# 行尾必须是 LF：CRLF 的清单会被原样签进消息，和流水线其它环节对不上
if ($sumsBytes -contains 0x0d) {
    Stop-With 2 'SHA256SUMS contains CR bytes: it must be LF only, as the release writes it'
}
if ($sumsBytes[$sumsBytes.Length - 1] -ne 0x0a) {
    Stop-With 2 'SHA256SUMS does not end with a newline'
}
$sumsText = (New-Object System.Text.UTF8Encoding($false)).GetString($sumsBytes)

$sums = @{}
foreach ($line in ($sumsText -split "`n")) {
    if ($line -eq '') { continue }
    if ($line -notmatch '^([0-9a-f]{64})  (.+)$') {
        Stop-With 2 ("SHA256SUMS line is not '<64 lowercase hex>  <name>': {0}" -f $line)
    }
    $hash = $Matches[1]
    $name = $Matches[2]
    if ($sums.ContainsKey($name)) { Stop-With 2 ("SHA256SUMS lists {0} twice" -f $name) }
    $sums[$name] = $hash
}
foreach ($name in $AssetNames) {
    if (-not $sums.ContainsKey($name)) {
        Stop-With 2 ("SHA256SUMS has no line for {0} (it lists: {1})" -f $name, ($sums.Keys -join ', '))
    }
}
foreach ($name in $sums.Keys) {
    if ($AssetNames -notcontains $name) {
        Stop-With 2 ("SHA256SUMS lists {0}, which is not one of the four release files" -f $name)
    }
}

if (-not (Test-Path -LiteralPath $sigFile -PathType Leaf)) {
    Stop-With 2 ("no SHA256SUMS.sig beside {0}: sign the sums first" -f $sumsFile)
}
$sigText = ([System.IO.File]::ReadAllText($sigFile)).Trim()
if ($sigText -eq '') { Stop-With 2 ("SHA256SUMS.sig is empty: {0}" -f $sigFile) }
try {
    $sigBytes = [System.Convert]::FromBase64String($sigText)
} catch {
    Stop-With 2 ("SHA256SUMS.sig is not base64: {0}" -f $sigFile)
}
if ($sigBytes.Length -ne 64) {
    Stop-With 2 ("SHA256SUMS.sig holds {0} bytes, not ed25519's 64" -f $sigBytes.Length)
}

# ---------------- 资产 ----------------

$assets = [ordered]@{}
foreach ($name in $AssetNames) {
    $path = Join-Path $DistPath $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Stop-With 3 ("missing {0}" -f $path)
    }
    $item = Get-Item -LiteralPath $path
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $sums[$name]) {
        Stop-With 3 ("{0} hashes to {1}, but SHA256SUMS says {2}" -f $name, $hash, $sums[$name])
    }
    $assets[$name] = [ordered]@{
        url    = "https://github.com/$Repo/releases/download/v$Version/$name"
        size   = [long]$item.Length
        sha256 = $hash
    }
}

if ($Notes -eq '') {
    $base = $Version -replace '-custom\..*$', ''
    $Notes = "基于上游 v$base 的定制版"
}

$feed = [ordered]@{
    version = $Version
    notes   = $Notes
    url     = "https://github.com/$Repo/releases/tag/v$Version"
    assets  = $assets
    signed  = [ordered]@{
        sums = $sumsText
        sig  = $sigText
    }
}

# ---------------- 写盘 ----------------

try {
    $json = $feed | ConvertTo-Json -Depth 5 -Compress
    [System.IO.File]::WriteAllText($outFull, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Stop-With 4 ("cannot write {0}: {1}" -f $outFull, $_.Exception.Message)
}

# ---------------- 自检：读回来逐项对 ----------------

Write-Step 'self-check'

$back = $null
try {
    $back = [System.IO.File]::ReadAllText($outFull) | ConvertFrom-Json
} catch {
    Stop-With 4 ("{0} is not valid JSON: {1}" -f $outFull, $_.Exception.Message)
}
if ($back.version -ne $Version) {
    Stop-With 4 ("version came back as '{0}'" -f $back.version)
}
if ($back.url -ne "https://github.com/$Repo/releases/tag/v$Version") {
    Stop-With 4 ("url came back as '{0}'" -f $back.url)
}
if ($back.signed.sig -ne $sigText) {
    Stop-With 4 'signed.sig did not round-trip'
}
# sums 是签过名的字节，必须与文件逐字节相同，不只是"看起来一样"
$backSums = [System.Text.Encoding]::UTF8.GetBytes($back.signed.sums)
if ([System.Convert]::ToBase64String($backSums) -ne [System.Convert]::ToBase64String($sumsBytes)) {
    Stop-With 4 'signed.sums is not byte for byte the SHA256SUMS file'
}
if (@($back.assets.PSObject.Properties).Count -ne $AssetNames.Count) {
    Stop-With 4 ("assets holds {0} files, not {1}" -f @($back.assets.PSObject.Properties).Count, $AssetNames.Count)
}
foreach ($name in $AssetNames) {
    $a = $back.assets.$name
    if ($null -eq $a) { Stop-With 4 ("assets has no {0}" -f $name) }
    if ($a.sha256 -ne $sums[$name]) { Stop-With 4 ("assets.{0}.sha256 is not the signed one" -f $name) }
    if ([long]$a.size -ne [long](Get-Item -LiteralPath (Join-Path $DistPath $name)).Length) {
        Stop-With 4 ("assets.{0}.size is not the file's" -f $name)
    }
    Write-Item ("{0}  {1} bytes  {2}" -f $name, $a.size, $a.sha256)
}

Write-Step 'done'
Write-Item ("version : {0}" -f $Version)
Write-Item ("url     : {0}" -f $feed.url)
Write-Item ("sums    : {0} bytes, {1} lines" -f $sumsBytes.Length, ($sumsText -split "`n" | Where-Object { $_ -ne '' }).Count)
Write-Item ("sig     : {0} bytes of ed25519, base64 {1} chars" -f $sigBytes.Length, $sigText.Length)
Write-Item ("wrote   : {0}" -f $outFull)
exit 0
