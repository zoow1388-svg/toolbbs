[CmdletBinding()]
param(
    [string]$OutputDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$skillSource = Join-Path $projectRoot 'skill\codex-project-orchestrator'
$version = (Get-Content -LiteralPath (Join-Path $skillSource 'VERSION') -Raw -Encoding UTF8).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "VERSION 格式无效：$version" }

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'dist' }
$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
[void](New-Item -ItemType Directory -Path $outputRoot -Force)
$operationId = [guid]::NewGuid().ToString('N')
$staging = Join-Path $outputRoot ".package-$operationId"
$packageRoot = Join-Path $staging "toolbbs-v$version"
$archivePath = Join-Path $outputRoot "codex-project-orchestrator-v$version.zip"
$checksumPath = "$archivePath.sha256"

try {
    [void](New-Item -ItemType Directory -Path (Join-Path $packageRoot 'skill') -Force)
    Copy-Item -LiteralPath $skillSource -Destination (Join-Path $packageRoot 'skill\codex-project-orchestrator') -Recurse
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install.ps1') -Destination (Join-Path $packageRoot 'install.ps1')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'uninstall.ps1') -Destination (Join-Path $packageRoot 'uninstall.ps1')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'docs\INSTALL.md') -Destination (Join-Path $packageRoot 'INSTALL.md')

    $manifestFiles = @()
    foreach ($file in Get-ChildItem -LiteralPath $packageRoot -File -Recurse | Sort-Object FullName) {
        $manifestFiles += [ordered]@{
            path = $file.FullName.Substring($packageRoot.Length).TrimStart('\').Replace('\', '/')
            size = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $manifest = [ordered]@{
        package = 'codex-project-orchestrator'
        version = $version
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        files = $manifestFiles
    }
    [IO.File]::WriteAllText((Join-Path $packageRoot 'PACKAGE_MANIFEST.json'), ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

    if ((Test-Path -LiteralPath $archivePath) -or (Test-Path -LiteralPath $checksumPath)) {
        throw "发布包或校验文件已存在，拒绝覆盖：$archivePath"
    }
    Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $archivePath -CompressionLevel Optimal
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($checksumPath, "$archiveHash  $([IO.Path]::GetFileName($archivePath))`n", [Text.UTF8Encoding]::new($false))
    Write-Output "发布包：$archivePath"
    Write-Output "SHA-256：$archiveHash"
} finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}
