[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ProjectPath,
    [Parameter(Mandatory=$true)][string]$PreflightPath,
    [string]$TargetBranch='main'
)

$ErrorActionPreference='Stop'
function Normalize-Path([string]$Path){[IO.Path]::GetFullPath($Path).TrimEnd('\')}
function Assert-Equal($Expected,$Actual,[string]$Name){if([string]$Expected-ne[string]$Actual){throw "STALE_PREFLIGHT: $Name changed after preflight."}}

$project=Normalize-Path $ProjectPath
$reportPath=[IO.Path]::GetFullPath($PreflightPath)
if(-not(Test-Path -LiteralPath $reportPath -PathType Leaf)){throw 'PREFLIGHT_REQUIRED: readiness report was not found.'}
if($reportPath.StartsWith("$project\",[StringComparison]::OrdinalIgnoreCase)){throw 'INVALID_PREFLIGHT: readiness report must be stored outside the target project.'}
$initialSha=(Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant()
try{$report=Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8|ConvertFrom-Json}catch{throw 'INVALID_PREFLIGHT: readiness report is not valid JSON.'}
$required=@('schema_version','project_path','observed_at','expires_at','classification','recommended_mode','repository','state','worktree','findings','summary')
foreach($name in $required){if($report.PSObject.Properties.Match($name).Count-ne1){throw "INVALID_PREFLIGHT: missing $name."}}
foreach($contract in @(
    @{object=$report.repository;name='repository';fields=@('is_git_repository','repository_root','requested_path_is_root','has_commits','head_revision','current_branch','is_detached','target_branch','target_branch_exists','status_lines','ongoing_operations','worktree_count')},
    @{object=$report.state;name='state';fields=@('path','exists','tracked','ignored')},
    @{object=$report.worktree;name='worktree';fields=@('default_root','exists')},
    @{object=$report.summary;name='summary';fields=@('blockers','warnings')}
)){if($null-eq$contract.object){throw "INVALID_PREFLIGHT: missing $($contract.name)."};foreach($field in $contract.fields){if($contract.object.PSObject.Properties.Match($field).Count-ne1){throw "INVALID_PREFLIGHT: missing $($contract.name).$field."}}}
if([int]$report.schema_version-ne1){throw 'INVALID_PREFLIGHT: unsupported schema version.'}
if((Normalize-Path ([string]$report.project_path))-ne$project){throw 'INVALID_PREFLIGHT: project path does not match.'}
if([string]$report.repository.target_branch-ne$TargetBranch){throw 'INVALID_PREFLIGHT: target branch does not match.'}
$now=[DateTime]::UtcNow
try{$observed=[DateTime]::Parse([string]$report.observed_at).ToUniversalTime();$expires=[DateTime]::Parse([string]$report.expires_at).ToUniversalTime()}catch{throw 'INVALID_PREFLIGHT: timestamps are invalid.'}
if($observed-gt$now.AddMinutes(1)-or$expires-le$observed){throw 'INVALID_PREFLIGHT: timestamp range is invalid.'}
if($now-gt$expires){throw 'STALE_PREFLIGHT: readiness report expired.'}
if($report.classification-ne'compatible'-or$report.recommended_mode-ne'full-integration'){throw "PREFLIGHT_BLOCKED: classification is $($report.classification)."}

$liveJson=@(& (Join-Path $PSScriptRoot 'test-project-readiness.ps1') -ProjectPath $project -TargetBranch $TargetBranch)|Out-String
$live=$liveJson|ConvertFrom-Json
if($live.classification-ne'compatible'){throw "STALE_PREFLIGHT: live classification is $($live.classification)."}
Assert-Equal $report.repository.repository_root $live.repository.repository_root 'repository root'
Assert-Equal $report.repository.head_revision $live.repository.head_revision 'HEAD revision'
Assert-Equal $report.repository.current_branch $live.repository.current_branch 'current branch'
Assert-Equal ($report.repository.status_lines -join "`n") ($live.repository.status_lines -join "`n") 'working tree status'
Assert-Equal ($report.repository.ongoing_operations -join ',') ($live.repository.ongoing_operations -join ',') 'ongoing Git operations'
Assert-Equal $report.repository.worktree_count $live.repository.worktree_count 'worktree inventory'
Assert-Equal $report.state.exists $live.state.exists 'runtime state presence'
Assert-Equal $report.state.tracked $live.state.tracked 'runtime state tracking'
Assert-Equal $report.state.ignored $live.state.ignored 'runtime state ignore rule'
$finalSha=(Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant()
if($initialSha-ne$finalSha){throw 'STALE_PREFLIGHT: readiness report changed during verification.'}

[ordered]@{
    report_path=$reportPath
    report_sha256=$initialSha
    observed_at=$report.observed_at
    expires_at=$report.expires_at
    verified_at=$now.ToString('o')
    classification=$report.classification
    repository_root=$live.repository.repository_root
    head_revision=$live.repository.head_revision
    current_branch=$live.repository.current_branch
    target_branch=$TargetBranch
}|ConvertTo-Json -Depth 5
