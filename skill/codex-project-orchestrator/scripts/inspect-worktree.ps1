[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorktreePath,
    [string]$OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$resolved = [IO.Path]::GetFullPath($WorktreePath)
if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { throw "Worktree path not found: $resolved" }

$inside = (& git -C $resolved rev-parse --is-inside-work-tree 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $inside -ne 'true') { throw 'Target is not a Git worktree.' }
$topLevel = [IO.Path]::GetFullPath((& git -C $resolved rev-parse --show-toplevel).Trim())
if ($LASTEXITCODE -ne 0 -or $topLevel -ne $resolved) { throw 'WorktreePath must be the worktree root.' }

$porcelain = @(& git -C $resolved worktree list --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'Unable to read Git worktree inventory.' }
$roots = @($porcelain | Where-Object { $_ -like 'worktree *' } | ForEach-Object { [IO.Path]::GetFullPath($_.Substring(9)) })
if ($resolved -notin $roots) { throw 'Target is not registered in git worktree list.' }
$repositoryRoot = $roots[0]
$branch = (& git -C $resolved symbolic-ref --quiet --short HEAD 2>$null)
$detached = $LASTEXITCODE -ne 0
if ($detached -or [string]::IsNullOrWhiteSpace($branch)) { throw 'Detached HEAD worktrees cannot be bound.' }
$head = (& git -C $resolved rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[a-f0-9]{40,64}$') { throw 'Unable to resolve worktree HEAD.' }
$dirty = @(& git -C $resolved status --porcelain=v1).Count -gt 0

$binding = [ordered]@{
    repository_root = $repositoryRoot
    worktree_path = $resolved
    branch_name = $branch.Trim()
    head_revision = $head
    is_detached = $false
    is_dirty = $dirty
    inspected_at = (Get-Date).ToUniversalTime().ToString('o')
}
$json = $binding | ConvertTo-Json -Depth 4
if ($OutputPath) {
    $fullOutput = [IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $fullOutput
    if ($parent) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    [IO.File]::WriteAllText($fullOutput, $json, [Text.UTF8Encoding]::new($false))
}
$json
