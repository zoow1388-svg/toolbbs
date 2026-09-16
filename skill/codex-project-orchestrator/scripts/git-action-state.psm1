Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Write-GitJsonAtomic($Value,[string]$Path){
    $parent=Split-Path -Parent $Path;if(-not(Test-Path $parent)){[void](New-Item -ItemType Directory -Path $parent)}
    $temporary="$Path.tmp.$([guid]::NewGuid().ToString('N'))"
    try{[IO.File]::WriteAllText($temporary,($Value|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false));if(Test-Path $Path){[IO.File]::Replace($temporary,$Path,"$Path.bak");Remove-Item "$Path.bak" -Force}else{[IO.File]::Move($temporary,$Path)}}finally{if(Test-Path $temporary){Remove-Item $temporary -Force}}
}
function Invoke-GitStateLock([string]$State,[scriptblock]$Action){
    if(-not(Test-Path $State)){[void](New-Item -ItemType Directory -Path $State)};$stream=$null
    try{$stream=[IO.File]::Open((Join-Path $State 'workflow.lock'),'OpenOrCreate','ReadWrite','None');&$Action}catch [IO.IOException]{throw 'State lock is held by another controller.'}finally{if($stream){$stream.Dispose()}}
}
function Read-GitActions([string]$State){$path=Join-Path $State 'git-actions.json';if(Test-Path $path){@(Get-Content $path -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_})}else{@()}}
function Get-Sha([string]$Path){(Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Get-GitActionState([string]$ProjectPath){Read-GitActions (Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator')}

function Start-GitAction {
    param([string]$ProjectPath,[string]$TaskId,[string]$RequestPath,[int64]$ExpectedControllerEpoch)
    $project=[IO.Path]::GetFullPath($ProjectPath);$state=Join-Path $project '.codex-orchestrator'
    Invoke-GitStateLock $state {
        $workflow=Get-Content (Join-Path $state 'workflow.json') -Raw -Encoding UTF8|ConvertFrom-Json;$tasks=@(Get-Content (Join-Path $state 'tasks.json') -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_});$actions=@(Read-GitActions $state)
        if([int64]$workflow.controller_epoch-ne$ExpectedControllerEpoch){throw 'STALE_CONTROLLER_LEASE: controller epoch changed.'}
        $task=@($tasks|Where-Object{$_.task_id-eq$TaskId});if($task.Count-ne1){throw "Task not found: $TaskId"};$task=$task[0]
        if($task.authorization-ne'git-approved'){throw 'Registered task does not have explicit Git authorization.'}
        $resolved=[IO.Path]::GetFullPath($RequestPath);if(-not(Test-Path $resolved -PathType Leaf)){throw 'Git request not found.'};$request=Get-Content $resolved -Raw -Encoding UTF8|ConvertFrom-Json
        if($request.authorization-ne'git-approved'){throw 'Explicit git-approved authorization is required.'};if([IO.Path]::GetFullPath([string]$request.repository_root)-ne$project){throw 'Git request repository does not match workflow project.'}
        $logical="$TaskId`:$($request.operation)";$prior=@($actions|Where-Object{$_.logical_key-eq$logical});if(@($prior|Where-Object{$_.status-notin@('cancelled','failed')}).Count){throw 'GIT_ACTION_ALREADY_STARTED: inspect the existing transaction.'}
        $attempt=$prior.Count+1;$now=[DateTime]::UtcNow.ToString('o');$item=[pscustomobject][ordered]@{git_action_id="$($workflow.workflow_id):$($workflow.controller_epoch):$logical`:$attempt";logical_key=$logical;task_id=$TaskId;operation=$request.operation;operation_id=$request.operation_id;controller_thread_id=$workflow.controller_thread_id;controller_host_id=$workflow.controller_host_id;controller_epoch=[int64]$workflow.controller_epoch;attempt=$attempt;status='prepared';request_path=$resolved;request_sha256=Get-Sha $resolved;receipt_path=$null;receipt_sha256=$null;resolution_evidence_path=$null;resolution_evidence_sha256=$null;error=$null;created_at=$now;completed_at=$null;failed_at=$null;cancelled_at=$null}
        $actions+=$item;Write-GitJsonAtomic $actions (Join-Path $state 'git-actions.json');$item
    }
}
function Complete-GitAction {
    param([string]$ProjectPath,[string]$GitActionId,[string]$ReceiptPath)
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator';Invoke-GitStateLock $state {
        $actions=@(Read-GitActions $state);$found=@($actions|Where-Object{$_.git_action_id-eq$GitActionId});if($found.Count-ne1){throw 'Git action not found.'};$item=$found[0]
        $resolved=[IO.Path]::GetFullPath($ReceiptPath);if(-not(Test-Path $resolved)){throw 'Git receipt not found.'};$receipt=Get-Content $resolved -Raw -Encoding UTF8|ConvertFrom-Json
        if($item.status-eq'completed'){if((Get-Sha $resolved)-ne$item.receipt_sha256){throw 'Completed Git receipt mismatch.'};return $item}
        if($item.status-ne'prepared'){throw 'Only a prepared Git action can complete.'}
        if($receipt.operation_id-ne$item.operation_id-or$receipt.operation-ne$item.operation-or$receipt.request_sha256-ne$item.request_sha256-or$receipt.status-ne'completed'){throw 'Git receipt identity mismatch.'}
        $item.status='completed';$item.receipt_path=$resolved;$item.receipt_sha256=Get-Sha $resolved;$item.completed_at=[DateTime]::UtcNow.ToString('o');Write-GitJsonAtomic $actions (Join-Path $state 'git-actions.json');$item
    }
}
function Fail-GitAction {
    param([string]$ProjectPath,[string]$GitActionId,[string]$EvidencePath,[string]$ErrorMessage)
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator';Invoke-GitStateLock $state {$actions=@(Read-GitActions $state);$found=@($actions|Where-Object{$_.git_action_id-eq$GitActionId});if($found.Count-ne1){throw 'Git action not found.'};$item=$found[0];if($item.status-ne'prepared'){throw 'Only a prepared Git action can fail.'};$evidence=[IO.Path]::GetFullPath($EvidencePath);if(-not(Test-Path $evidence)){throw 'Failure evidence not found.'};$item.status='failed';$item.resolution_evidence_path=$evidence;$item.resolution_evidence_sha256=Get-Sha $evidence;$item.error=$ErrorMessage;$item.failed_at=[DateTime]::UtcNow.ToString('o');Write-GitJsonAtomic $actions (Join-Path $state 'git-actions.json');$item}
}
function Cancel-GitAction {
    param([string]$ProjectPath,[string]$GitActionId,[string]$EvidencePath)
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator';Invoke-GitStateLock $state {$actions=@(Read-GitActions $state);$found=@($actions|Where-Object{$_.git_action_id-eq$GitActionId});if($found.Count-ne1){throw 'Git action not found.'};$item=$found[0];if($item.status-ne'prepared'){throw 'Only a prepared Git action can be cancelled.'};$evidence=[IO.Path]::GetFullPath($EvidencePath);if(-not(Test-Path $evidence)){throw 'Cancellation evidence not found.'};$item.status='cancelled';$item.resolution_evidence_path=$evidence;$item.resolution_evidence_sha256=Get-Sha $evidence;$item.cancelled_at=[DateTime]::UtcNow.ToString('o');Write-GitJsonAtomic $actions (Join-Path $state 'git-actions.json');$item}
}
Export-ModuleMember -Function Start-GitAction,Complete-GitAction,Fail-GitAction,Cancel-GitAction,Get-GitActionState
