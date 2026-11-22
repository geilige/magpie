<#
.SYNOPSIS
    给 magpie 定制版发布的 SHA256SUMS 签名，格式与 app 里 verify() 逐字节一致。

.DESCRIPTION
    被签名的字节（顺序、分隔、行尾都不能变）：
        "magpie release " + <Version> + "\n" + <SHA256SUMS 的完整原始字节>
    签名算法：
        ed25519 直接对上面这串字节签名，不做 sha256 预处理 —— openssl 的 -rawin
    输出：
        签名原始 64 字节的 base64（单行、无换行），写入 SHA256SUMS.sig，末尾一个 LF

    退出码：
      0  成功
      1  参数错误：缺 -Version、版本带 v 前缀、版本含非法字符、私钥路径不存在
      2  SHA256SUMS 不存在或为空
      3  openssl 不可用，或签名命令失败
      4  签完自验失败（此时不写 SHA256SUMS.sig，不会产出一个自己都验不过的签名）
      5  -Verify 验签失败（签名与 SHA256SUMS 或 Version 不匹配）
      6  -Verify 缺 SHA256SUMS.sig，或它不是一个 64 字节的 base64

.PARAMETER Version
    必填，不带 v 前缀，例如 0.1.4657-custom.1。
    这个字符串会原样进入被签名的消息，必须和 feed 里 Release.Version 一字不差。

.PARAMETER SumsPath
    SHA256SUMS 的文件路径，或它所在的目录。默认当前目录。
    签名写到同目录的 SHA256SUMS.sig。

.PARAMETER KeyPath
    ed25519 私钥文件（OpenSSL PEM）。默认读环境变量 MAGPIE_UPDATE_SIGNING_KEY。
    -Verify 时可以不填：不填就用内嵌在 app 里的那把公钥验，验的就是 app 将来认的东西。

.PARAMETER Verify
    只验签不签名：读 SHA256SUMS 与 SHA256SUMS.sig，用 openssl pkeyutl -verify 验。

.NOTES
    私钥内容任何时候都不打印、不写进仓库。临时文件建在 %TEMP%\magpie-sign-*，跑完删掉。
    SHA256SUMS 的每一个字节都参与签名，所以行尾（LF / CRLF）会被签进去：
    GitHub Actions 上 sha256sum 产出的是 LF，Windows 的 Out-File 是 CRLF，两者签名不通用。
#>

[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$SumsPath = '',
    [string]$KeyPath = '',
    [switch]$Verify
)

# 原生命令的 stderr 在 Stop 下会变成终止错误，这里固定 Continue，成败靠 $LASTEXITCODE。
$ErrorActionPreference = 'Continue'

# app 内嵌的公钥：internal/update/signed.go 的 signingKey（base64, raw 32 字节）。
# 只在 -Verify 没给私钥时用 —— 验的就是二进制将来认的那把。
$EmbeddedKeyBase64 = 'lF7L86d/FS20ohijHND7SikMnZrVdrEa6eD9IKP7Ec8='

# ed25519 的 SubjectPublicKeyInfo DER 前缀：SEQUENCE{OID 1.3.101.112, BIT STRING}
$Ed25519SpkiPrefix = [byte[]](0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00)

$Work = $null

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
# 后者按 .NET 的 CurrentDirectory 解析，而 Set-Location 不会改它。两者可以不同
# （PowerShell 里切了目录、或宿主进程从别处启动），GetFullPath(".") 就会指到别处。
# GetUnresolvedProviderPathFromPSPath 允许目标还不存在，正好用来解析还没创建的输出文件。
function Resolve-FullPath {
    [CmdletBinding()]
    param([string]$Path)
    if ($Path -eq '') { return '' }
    return $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
}

# 调 openssl，收集输出供失败时原文打印；不打印任何私钥内容（openssl 本身也不会把私钥打到 stdout）
function Invoke-OpenSsl {
    param([string[]]$OpenSslArgs)
    $lines = @(& $OpenSslExe @OpenSslArgs 2>&1)
    $code = $LASTEXITCODE
    $text = (@($lines | Where-Object { $null -ne $_ } | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    return @{ Exit = $code; Output = $text }
}

function New-WorkFile {
    param([string]$Name)
    return (Join-Path $Work $Name)
}

# 把消息字节拼出来：前缀是 UTF-8（无 BOM），后面原样接 SHA256SUMS 的字节
function Write-MessageFile {
    param([string]$Path, [byte[]]$SumsBytes)
    $prefix = [System.Text.Encoding]::UTF8.GetBytes("magpie release $Version`n")
    $all = New-Object byte[] ($prefix.Length + $SumsBytes.Length)
    [System.Array]::Copy($prefix, 0, $all, 0, $prefix.Length)
    [System.Array]::Copy($SumsBytes, 0, $all, $prefix.Length, $SumsBytes.Length)
    [System.IO.File]::WriteAllBytes($Path, $all)
    return $all.Length
}

# 私钥路径：参数 > 环境变量；空串表示没给
function Resolve-KeyPath {
    if ($KeyPath -ne '') { return $KeyPath }
    $fromEnv = [System.Environment]::GetEnvironmentVariable('MAGPIE_UPDATE_SIGNING_KEY')
    if ($null -ne $fromEnv) { return $fromEnv.Trim() }
    return ''
}

# 用私钥导出公钥 PEM（公钥不是秘密，可以打印它的指纹式摘要）
function Export-PublicKey {
    param([string]$KeyFile, [string]$PemPath)
    $r = Invoke-OpenSsl @('pkey', '-in', $KeyFile, '-pubout', '-out', $PemPath)
    if ($r.Exit -ne 0) {
        Stop-With 3 ("openssl could not read the signing key at {0}: {1}" -f $KeyFile, $r.Output)
    }
}

# -Verify 没给私钥时，把内嵌的 raw 公钥包成 DER/PEM 给 openssl 用
function Export-EmbeddedPublicKey {
    param([string]$PemPath)
    $raw = [System.Convert]::FromBase64String($EmbeddedKeyBase64)
    $der = New-Object byte[] ($Ed25519SpkiPrefix.Length + $raw.Length)
    [System.Array]::Copy($Ed25519SpkiPrefix, 0, $der, 0, $Ed25519SpkiPrefix.Length)
    [System.Array]::Copy($raw, 0, $der, $Ed25519SpkiPrefix.Length, $raw.Length)
    $derPath = New-WorkFile 'embedded-pub.der'
    [System.IO.File]::WriteAllBytes($derPath, $der)
    $r = Invoke-OpenSsl @('pkey', '-pubin', '-inform', 'DER', '-in', $derPath, '-out', $PemPath)
    if ($r.Exit -ne 0) {
        Stop-With 6 ("the embedded public key is not a usable ed25519 key: {0}" -f $r.Output)
    }
}

# ---------------- 主流程 ----------------

Write-Host 'sign-release.ps1 - sign a magpie custom release (ed25519, verify() byte for byte)'

$OpenSslExe = ''
$OpenSsl = Get-Command openssl -ErrorAction SilentlyContinue
if ($null -ne $OpenSsl) {
    $OpenSslExe = $OpenSsl.Source
} else {
    # PowerShell 的 PATH 通常没有 openssl（Git for Windows 的放在 usr\bin 下），
    # 按常见安装位置找一遍，找到就用它，找不到再报错
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\usr\bin\openssl.exe'),
        (Join-Path $env:ProgramFiles 'OpenSSL-Win64\bin\openssl.exe'),
        (Join-Path $env:ProgramFiles 'OpenSSL-Win32\bin\openssl.exe')
    )
    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $OpenSslExe = $candidate
            break
        }
    }
}
if ($OpenSslExe -eq '') {
    Stop-With 3 'openssl not found: put it on PATH (3.x is needed for -rawin), or install it to a standard folder.'
}
Write-Item "openssl : $OpenSslExe"

# 版本：必填，不带 v，且不能带会把消息弄脏的字符
if ($Version -eq '') {
    Stop-With 1 'no -Version. Pass the release version as the feed has it, e.g. -Version 0.1.4657-custom.1'
}
if ($Version.StartsWith('v') -or $Version.StartsWith('V')) {
    Stop-With 1 ("version must not start with v: '{0}' would never verify - the feed's version is 0.1.4657-custom.1" -f $Version)
}
if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z.+_-]*$') {
    Stop-With 1 ("version has characters the signed message cannot carry: '{0}'" -f $Version)
}

# SHA256SUMS：给的是目录就用目录下的 SHA256SUMS
if ($SumsPath -eq '') { $SumsPath = (Get-Location).Path }
if (Test-Path -LiteralPath $SumsPath -PathType Container) {
    $sumsFile = Join-Path $SumsPath 'SHA256SUMS'
} else {
    $sumsFile = $SumsPath
}
$sumsFile = Resolve-FullPath $sumsFile
$sumsDir = [System.IO.Path]::GetDirectoryName($sumsFile)
$sigFile = Join-Path $sumsDir 'SHA256SUMS.sig'

if (-not (Test-Path -LiteralPath $sumsFile -PathType Leaf)) {
    Stop-With 2 ("SHA256SUMS not found: {0}" -f $sumsFile)
}
$sumsBytes = [System.IO.File]::ReadAllBytes($sumsFile)
if ($sumsBytes.Length -eq 0) {
    Stop-With 2 ("SHA256SUMS is empty: {0}" -f $sumsFile)
}

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('magpie-sign-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work | Out-Null

try {
    $msgPath = New-WorkFile 'message.bin'
    $msgLen = Write-MessageFile -Path $msgPath -SumsBytes $sumsBytes
    Write-Item "sums    : $sumsFile ($($sumsBytes.Length) bytes)"
    Write-Item "version : $Version"
    Write-Item "signed  : $msgLen bytes = 'magpie release <version>\n' + SHA256SUMS"

    # SHA256SUMS 没有结尾换行时提醒一句：上游流水线产出的一定有，
    # 少了它签名仍然有效，但和上游产物对不上，容易在别处被重排后再也验不过
    if ($sumsBytes[$sumsBytes.Length - 1] -ne 0x0a) {
        Write-Item 'WARN: SHA256SUMS does not end with a newline; the signature covers it as it is'
    }

    $keyFile = Resolve-KeyPath
    if ($keyFile -ne '') {
        $keyFile = Resolve-FullPath $keyFile
        if (-not (Test-Path -LiteralPath $keyFile -PathType Leaf)) {
            Stop-With 1 ("signing key not found: {0} (pass -KeyPath, or set MAGPIE_UPDATE_SIGNING_KEY)" -f $keyFile)
        }
    }

    # ---- 只验签 ----
    if ($Verify) {
        Write-Step 'verify'

        if (-not (Test-Path -LiteralPath $sigFile -PathType Leaf)) {
            Stop-With 6 ("no SHA256SUMS.sig beside {0}: sign first" -f $sumsFile)
        }
        $sigText = ([System.IO.File]::ReadAllText($sigFile)).Trim()
        if ($sigText -eq '') {
            Stop-With 6 ("SHA256SUMS.sig is empty: {0}" -f $sigFile)
        }
        try {
            $sigBytes = [System.Convert]::FromBase64String($sigText)
        } catch {
            Stop-With 6 ("SHA256SUMS.sig is not base64: {0}" -f $sigFile)
        }
        if ($sigBytes.Length -ne 64) {
            Stop-With 6 ("SHA256SUMS.sig holds {0} bytes, not ed25519's 64" -f $sigBytes.Length)
        }

        $pubPath = New-WorkFile 'public.pem'
        if ($keyFile -ne '') {
            Export-PublicKey -KeyFile $keyFile -PemPath $pubPath
            Write-Item "key     : public half derived from $keyFile"
        } else {
            Export-EmbeddedPublicKey -PemPath $pubPath
            Write-Item 'key     : the public key built into magpie (signed.go signingKey)'
        }

        $sigPath = New-WorkFile 'signature.bin'
        [System.IO.File]::WriteAllBytes($sigPath, $sigBytes)

        $r = Invoke-OpenSsl @('pkeyutl', '-verify', '-pubin', '-inkey', $pubPath, '-rawin', '-in', $msgPath, '-sigfile', $sigPath)
        if ($r.Exit -ne 0) {
            Write-Host "   openssl: $($r.Output)"
            Stop-With 5 ("signature does NOT match this SHA256SUMS and version {0}. The file is either tampered with or signed for another version." -f $Version)
        }
        Write-Host ''
        Write-Host "signature OK: $sigFile matches $sumsFile for version $Version"
        exit 0
    }

    # ---- 签名 ----
    Write-Step 'sign'

    if ($keyFile -eq '') {
        Stop-With 1 'no signing key. Pass -KeyPath, or set MAGPIE_UPDATE_SIGNING_KEY.'
    }
    Write-Item "key     : $keyFile (contents never printed)"

    $sigPath = New-WorkFile 'signature.bin'
    Write-Item '$ openssl pkeyutl -sign -rawin'
    $r = Invoke-OpenSsl @('pkeyutl', '-sign', '-rawin', '-inkey', $keyFile, '-in', $msgPath, '-out', $sigPath)
    if ($r.Exit -ne 0) {
        Write-Host "   openssl: $($r.Output)"
        Stop-With 3 ("openssl pkeyutl -sign failed (exit {0})" -f $r.Exit)
    }
    $sigBytes = [System.IO.File]::ReadAllBytes($sigPath)
    if ($sigBytes.Length -ne 64) {
        Stop-With 3 ("openssl produced {0} bytes, not ed25519's 64" -f $sigBytes.Length)
    }

    # 先自验：绝不留一个自己都验不过的 sig 给发布流程
    Write-Step 'self-check'
    $pubPath = New-WorkFile 'public.pem'
    Export-PublicKey -KeyFile $keyFile -PemPath $pubPath
    $v = Invoke-OpenSsl @('pkeyutl', '-verify', '-pubin', '-inkey', $pubPath, '-rawin', '-in', $msgPath, '-sigfile', $sigPath)
    if ($v.Exit -ne 0) {
        Write-Host "   openssl: $($v.Output)"
        Stop-With 4 'the signature does not verify with its own public key; nothing was written'
    }
    Write-Item 'the signature verifies with the public half of the same key'

    # 写盘：base64 单行 + 一个 LF（上游 testdata/signed-sample.sig 是 88 字符 + LF）
    $b64 = [System.Convert]::ToBase64String($sigBytes)
    [System.IO.File]::WriteAllText($sigFile, $b64 + "`n", (New-Object System.Text.ASCIIEncoding))
    Write-Item ("wrote   : {0} ({1} chars + newline)" -f $sigFile, $b64.Length)

    Write-Step 'done'
    Write-Item "signature: $sigFile"
    Write-Item 'next     : put both files in the release, and the same SHA256SUMS text in latest.json'
    Write-Item 'reminder : the feed must carry these exact bytes - reformatting them breaks the signature'
    exit 0
} finally {
    # 临时文件里有签名中间产物，跑完删干净；只删本次自己建的 GUID 目录。
    # 删不掉也不影响已经写好的 SHA256SUMS.sig（文件留在 %TEMP%\magpie-sign-* 下）。
    if ($null -ne $Work -and (Test-Path -LiteralPath $Work)) {
        if ([System.IO.Path]::GetFileName($Work).StartsWith('magpie-sign-')) {
            try {
                Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction Stop
            } catch {
                Write-Item "note    : could not remove $Work (harmless)"
            }
        }
    }
}
