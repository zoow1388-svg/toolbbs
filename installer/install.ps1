[CmdletBinding()]
param(
    [string]$SourcePath,
    [string]$DestinationRoot,
    [switch]$AllowUpgrade
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$skillName = 'codex-project-orchestrator'

function Resolve-SkillSource {
    param([string]$RequestedPath)
    if ($RequestedPath) { return [System.IO.Path]::GetFullPath($RequestedPath) }

    $candidates = @(
        (Join-Path $PSScriptRoot "skill\$skillName"),
        (Join-Path (Split-Path -Parent $PSScriptRoot) "skill\$skillName")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    throw "找不到 Skill 源目录。请使用 -SourcePath 指定 $skillName。"
}

function Resolve-SkillsRoot {
    param([string]$RequestedRoot)
    if ($RequestedRoot) { return [System.IO.Path]::GetFullPath($RequestedRoot) }
    if ($env:CODEX_HOME) { return [System.IO.Path]::GetFullPath((Join-Path $env:CODEX_HOME 'skills')) }
    return [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex\skills'))
}

function Assert-SkillLayout {
    param([string]$Path)
    foreach ($relativePath in @('SKILL.md', 'VERSION', 'agents\openai.yaml', 'scripts', 'references')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $relativePath))) {
            throw "安装包不完整，缺少：$relativePath"
        }
    }
    $version = (Get-Content -LiteralPath (Join-Path $Path 'VERSION') -Raw -Encoding UTF8).Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "VERSION 格式无效：$version" }
    return $version
}

function Get-DirectoryFingerprint {
    param([string]$Path)
    $lines = foreach ($file in Get-ChildItem -LiteralPath $Path -File -Recurse | Sort-Object FullName) {
        $relative = $file.FullName.Substring($Path.Length).TrimStart('\').Replace('\', '/')
        "$relative=$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($lines -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

$source = Resolve-SkillSource -RequestedPath $SourcePath
$sourceVersion = Assert-SkillLayout -Path $source
$skillsRoot = Resolve-SkillsRoot -RequestedRoot $DestinationRoot
$destination = Join-Path $skillsRoot $skillName
$backupRoot = Join-Path $skillsRoot ".toolbbs-backups\$skillName"

$normalizedSource = [System.IO.Path]::GetFullPath($source).TrimEnd('\')
$normalizedDestination = [System.IO.Path]::GetFullPath($destination).TrimEnd('\')
if ($normalizedSource -eq $normalizedDestination -or $normalizedDestination.StartsWith("$normalizedSource\", [StringComparison]::OrdinalIgnoreCase)) {
    throw '安装目录不能与源目录相同，也不能位于源目录内部。'
}

if (Test-Path -LiteralPath $destination) {
    $installedVersion = Assert-SkillLayout -Path $destination
    $sameContent = (Get-DirectoryFingerprint -Path $source) -eq (Get-DirectoryFingerprint -Path $destination)
    if ($installedVersion -eq $sourceVersion -and $sameContent) {
        Write-Output "已安装相同版本 $sourceVersion，无需修改。"
        return
    }
    if (-not $AllowUpgrade) {
        throw "已存在版本 $installedVersion，且内容不同。确认升级后请增加 -AllowUpgrade。"
    }
}

[void](New-Item -ItemType Directory -Path $skillsRoot -Force)
$operationId = [guid]::NewGuid().ToString('N')
$staging = Join-Path $skillsRoot ".$skillName.install.$operationId"
$backup = $null

try {
    Copy-Item -LiteralPath $source -Destination $staging -Recurse
    [void](Assert-SkillLayout -Path $staging)
    if ((Get-DirectoryFingerprint -Path $source) -ne (Get-DirectoryFingerprint -Path $staging)) {
        throw '暂存目录与安装包校验不一致。'
    }

    if (Test-Path -LiteralPath $destination) {
        [void](New-Item -ItemType Directory -Path $backupRoot -Force)
        $backup = Join-Path $backupRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + "-$operationId")
        Move-Item -LiteralPath $destination -Destination $backup
    }

    Move-Item -LiteralPath $staging -Destination $destination
    Write-Output "安装成功：$destination"
    Write-Output "版本：$sourceVersion"
    if ($backup) { Write-Output "旧版本备份：$backup" }
} catch {
    if (-not (Test-Path -LiteralPath $destination) -and $backup -and (Test-Path -LiteralPath $backup)) {
        Move-Item -LiteralPath $backup -Destination $destination
    }
    throw
} finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}
