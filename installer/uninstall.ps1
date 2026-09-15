[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [string]$DestinationRoot,
    [switch]$RestoreLatestBackup
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$skillName = 'codex-project-orchestrator'
if ($DestinationRoot) { $skillsRoot = [System.IO.Path]::GetFullPath($DestinationRoot) }
elseif ($env:CODEX_HOME) { $skillsRoot = [System.IO.Path]::GetFullPath((Join-Path $env:CODEX_HOME 'skills')) }
else { $skillsRoot = [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex\skills')) }

$destination = Join-Path $skillsRoot $skillName
$backupRoot = Join-Path $skillsRoot ".toolbbs-backups\$skillName"

if (-not (Test-Path -LiteralPath $destination)) {
    throw "未找到已安装的 Skill：$destination"
}
if (-not (Test-Path -LiteralPath (Join-Path $destination 'SKILL.md')) -or
    -not (Test-Path -LiteralPath (Join-Path $destination 'VERSION'))) {
    throw '目标目录缺少安装标识，拒绝卸载。'
}

if (-not $PSCmdlet.ShouldProcess($destination, '卸载 Codex 项目总控 Skill')) { return }

[void](New-Item -ItemType Directory -Path $backupRoot -Force)
$operationId = [guid]::NewGuid().ToString('N')
$uninstallBackup = Join-Path $backupRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + "-uninstalled-$operationId")
Move-Item -LiteralPath $destination -Destination $uninstallBackup
Write-Output "已卸载并保留备份：$uninstallBackup"

if ($RestoreLatestBackup) {
    $candidate = Get-ChildItem -LiteralPath $backupRoot -Directory |
        Where-Object { $_.FullName -ne $uninstallBackup } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $candidate) {
        Move-Item -LiteralPath $uninstallBackup -Destination $destination
        throw '没有可恢复的旧版本；已撤销本次卸载。'
    }
    Move-Item -LiteralPath $candidate.FullName -Destination $destination
    Write-Output "已恢复旧版本：$($candidate.FullName)"
}
