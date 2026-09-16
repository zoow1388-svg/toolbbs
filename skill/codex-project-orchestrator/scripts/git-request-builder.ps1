[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ProjectPath,[Parameter(Mandatory=$true)][string]$TaskId,[Parameter(Mandatory=$true)][ValidateSet('create_worktree','stage','commit','merge')][string]$Operation,[Parameter(Mandatory=$true)][string]$OutputPath,[string]$CommitMessage)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath($ProjectPath);$state=Join-Path $project '.codex-orchestrator'
$workflow=Get-Content (Join-Path $state 'workflow.json') -Raw -Encoding UTF8|ConvertFrom-Json
$tasks=@(Get-Content (Join-Path $state 'tasks.json') -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_});$found=@($tasks|Where-Object{$_.task_id-eq$TaskId})
if($found.Count-ne1){throw 'Task not found.'};$task=$found[0]
if($task.role-ne'developer'-or$task.authorization-ne'git-approved'){throw 'Developer task is not approved for Git automation.'}
$root=$null;if($Operation -eq 'create_worktree'){if([string]::IsNullOrWhiteSpace([string]$workflow.git_worktree_root)){throw 'Git worktree root is not configured.'};$root=[IO.Path]::GetFullPath([string]$workflow.git_worktree_root);if(-not$root.StartsWith('D:\',[StringComparison]::OrdinalIgnoreCase)){throw 'Git worktree root must be on D drive.'}}
$safe=($TaskId.ToLowerInvariant()-replace'[^a-z0-9._-]','-').Trim('-');$branch="codex/$safe";$worktree=$(if($task.worktree_path){$task.worktree_path}else{Join-Path $root "$($workflow.workflow_id)-$safe"})
$testEvidence=$null;$reviewEvidence=$null;$targetBranch=$null
if($Operation -eq 'create_worktree'){
    if($task.status -ne 'approved' -or $task.worktree_path){throw 'Task is not ready for worktree creation.'}
}elseif($Operation -in @('stage','commit')){
    if($task.status -ne 'awaiting_commit' -or -not $task.worktree_path){throw 'Task is not ready for controlled commit.'}
    $branch=$task.branch_name
    if($Operation -eq 'commit' -and [string]::IsNullOrWhiteSpace($CommitMessage)){
        $completed=-join([char[]]@(0x5B8C,0x6210));$developmentTask=-join([char[]]@(0x5F00,0x53D1,0x4EFB,0x52A1))
        $CommitMessage="feat: $completed $($task.task_id) $developmentTask"
    }
}else{
    if($task.git_phase-ne'committed'-or[string]::IsNullOrWhiteSpace([string]$task.commit_revision)){throw 'Developer commit is not ready for merge.'}
    $gates=@($tasks|Where-Object{$_.role-in@('tester','reviewer')-and$_.status-eq'completed'-and$_.verified-and$_.verification_status-eq'trusted'-and$_.depends_on-contains$task.task_id})
    foreach($role in @('tester','reviewer')){$gate=@($gates|Where-Object{$_.role-eq$role});if($gate.Count-ne1){throw "Exactly one trusted $role gate is required."};$gate=$gate[0];if(-not(Test-Path $gate.normalized_result_path)-or-not(Test-Path $gate.verification_receipt_path)){throw "$role evidence file is missing."};$result=Get-Content $gate.normalized_result_path -Raw -Encoding UTF8|ConvertFrom-Json;if($result.stage_evidence.role-ne$role-or$result.stage_evidence.outcome-ne'passed'-or$result.stage_evidence.inspected_revision-ne$task.commit_revision){throw "$role evidence does not inspect the developer commit."};$evidence=[pscustomobject][ordered]@{task_id=$gate.task_id;role=$role;inspected_revision=$task.commit_revision;verification_status='trusted';outcome='passed';receipt_path=[IO.Path]::GetFullPath($gate.verification_receipt_path);receipt_sha256=(Get-FileHash $gate.verification_receipt_path -Algorithm SHA256).Hash.ToLowerInvariant()};if($role-eq'tester'){$testEvidence=$evidence}else{$reviewEvidence=$evidence}}
    $branch=$task.branch_name;$worktree=$project;$targetBranch=$workflow.git_target_branch;$task.base_revision=(&git -C $project rev-parse HEAD).Trim();if($LASTEXITCODE-ne0){throw 'Cannot resolve target branch baseline.'}
}
$operationId='GIT-'+[guid]::NewGuid().ToString('N').ToUpperInvariant()
$request=[ordered]@{operation_id=$operationId;operation=$Operation;authorization='git-approved';repository_root=$project;worktree_path=$worktree;base_revision=$task.base_revision;branch_name=$branch;allowed_files=@($task.allowed_files);commit_message=$(if($Operation -eq 'commit'){$CommitMessage}else{$null});target_branch=$targetBranch;test_evidence=$testEvidence;review_evidence=$reviewEvidence;created_at=[DateTime]::UtcNow.ToString('o')}
$output=[IO.Path]::GetFullPath($OutputPath);if(Test-Path $output){throw 'Git request output already exists.'};$parent=Split-Path -Parent $output;if(-not(Test-Path $parent)){[void](New-Item -ItemType Directory -Path $parent)}
[IO.File]::WriteAllText($output,($request|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false));$request|ConvertTo-Json -Depth 10
