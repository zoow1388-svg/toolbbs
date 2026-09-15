Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:TerminalStates = @('completed','blocked','failed','cancelled','stale')
$script:Transitions = @{
    draft = @('awaiting_approval','blocked','failed','cancelled','stale')
    awaiting_approval = @('approved','blocked','failed','cancelled','stale')
    approved = @('dispatched','blocked','failed','cancelled','stale')
    dispatched = @('running','blocked','failed','cancelled','stale')
    running = @('verifying','blocked','failed','cancelled','stale')
    verifying = @('completed','blocked','failed','cancelled','stale')
}

function Get-UtcTimestamp { (Get-Date).ToUniversalTime().ToString('o') }

function Write-JsonAtomic {
    param([Parameter(Mandatory=$true)]$Value,[Parameter(Mandatory=$true)][string]$Path)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory) }
    $temporary = Join-Path $directory (([System.IO.Path]::GetFileName($Path)) + '.tmp.' + [guid]::NewGuid().ToString('N'))
    $backup = Join-Path $directory (([System.IO.Path]::GetFileName($Path)) + '.bak.' + [guid]::NewGuid().ToString('N'))
    try {
        $json = $Value | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($temporary, $json, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($temporary, $Path, $backup); Remove-Item -LiteralPath $backup -Force }
        else { [System.IO.File]::Move($temporary, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    }
}

function Invoke-WithStateLock {
    param([Parameter(Mandatory=$true)][string]$StateDirectory,[Parameter(Mandatory=$true)][scriptblock]$Action)
    if (-not (Test-Path -LiteralPath $StateDirectory)) { [void](New-Item -ItemType Directory -Path $StateDirectory) }
    $lockPath = Join-Path $StateDirectory 'workflow.lock'
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        & $Action
    } catch [System.IO.IOException] {
        throw 'State lock is held by another controller.'
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Read-StateJson {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "State file not found: $Path" }
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-ObjectSha256($Value){
    $json=$Value|ConvertTo-Json -Depth 20 -Compress
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($json)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}

function Read-ExternalActions([string]$StateDirectory){
    $path=Join-Path $StateDirectory 'external-actions.json'
    if(-not(Test-Path -LiteralPath $path)){return @()}
    @(Read-StateJson $path|ForEach-Object{$_})
}

function Read-ActionExecutions([string]$StateDirectory){
    $path=Join-Path $StateDirectory 'action-executions.json'
    if(-not(Test-Path -LiteralPath $path)){return @()}
    $items=@(Read-StateJson $path|ForEach-Object{$_})
    foreach($item in $items){
        if($item.PSObject.Properties.Match('attempt').Count -eq 0){Add-Member -InputObject $item -NotePropertyName attempt -NotePropertyValue 1}
        foreach($name in @('resolution_reason','resolved_at','retry_authorized_at','retry_reason','retry_evidence_path','retry_evidence_sha256')){if($item.PSObject.Properties.Match($name).Count -eq 0){Add-Member -InputObject $item -NotePropertyName $name -NotePropertyValue $null}}
    }
    $items
}

function Add-Defaults {
    param($Workflow,[object[]]$Tasks)
    if ($Workflow.PSObject.Properties.Match('state_version').Count -eq 0) { Add-Member -InputObject $Workflow -NotePropertyName state_version -NotePropertyValue 2 }
    $sourceStateVersion=[int]$Workflow.state_version
    if ($Workflow.PSObject.Properties.Match('event_sequence').Count -eq 0) { Add-Member -InputObject $Workflow -NotePropertyName event_sequence -NotePropertyValue 0 }
    if ($Workflow.PSObject.Properties.Match('current_stage').Count -eq 0) { Add-Member -InputObject $Workflow -NotePropertyName current_stage -NotePropertyValue 'analysis' }
    foreach ($name in @('controller_thread_id','controller_host_id')) {
        if ($Workflow.PSObject.Properties.Match($name).Count -eq 0) { Add-Member -InputObject $Workflow -NotePropertyName $name -NotePropertyValue $null }
    }
    if($Workflow.PSObject.Properties.Match('controller_epoch').Count -eq 0){Add-Member -InputObject $Workflow -NotePropertyName controller_epoch -NotePropertyValue $(if([string]::IsNullOrWhiteSpace([string]$Workflow.controller_thread_id)){0}else{1})}
    if($Workflow.PSObject.Properties.Match('controller_history').Count -eq 0){Add-Member -InputObject $Workflow -NotePropertyName controller_history -NotePropertyValue @()}
    foreach ($task in $Tasks) {
        if($task.PSObject.Properties.Match('repair_of').Count -eq 0){Add-Member -InputObject $task -NotePropertyName repair_of -NotePropertyValue $null}
        if ($task.PSObject.Properties.Match('dispatch_count').Count -eq 0) { Add-Member -InputObject $task -NotePropertyName dispatch_count -NotePropertyValue 0 }
        if ($task.PSObject.Properties.Match('raw_result_path').Count -eq 0) { Add-Member -InputObject $task -NotePropertyName raw_result_path -NotePropertyValue $null }
        if ($task.PSObject.Properties.Match('normalized_result_path').Count -eq 0) { Add-Member -InputObject $task -NotePropertyName normalized_result_path -NotePropertyValue $null }
        if ($task.PSObject.Properties.Match('verified').Count -eq 0) { Add-Member -InputObject $task -NotePropertyName verified -NotePropertyValue $false }
        if ($task.PSObject.Properties.Match('dispatch_id').Count -eq 0) { Add-Member -InputObject $task -NotePropertyName dispatch_id -NotePropertyValue $null }
        if ($task.PSObject.Properties.Match('delivery_status').Count -eq 0) { Add-Member -InputObject $task -NotePropertyName delivery_status -NotePropertyValue 'not-prepared' }
        foreach ($name in @('dispatch_path','sent_message_id','result_message_id','read_cursor','dispatched_at','acknowledged_at','result_received_at')) {
            if ($task.PSObject.Properties.Match($name).Count -eq 0) { Add-Member -InputObject $task -NotePropertyName $name -NotePropertyValue $null }
        }
        foreach ($name in @('send_receipt_path','send_receipt_sha256','observation_path','observation_sha256','observed_status','observed_at')) {
            if ($task.PSObject.Properties.Match($name).Count -eq 0) { Add-Member -InputObject $task -NotePropertyName $name -NotePropertyValue $null }
        }
        foreach ($name in @('wait_snapshot_path','wait_snapshot_sha256','latest_turn_id','latest_turn_status','latest_item_id','latest_item_phase','raw_result_sha256','normalized_result_sha256','verification_receipt_path','verification_receipt_sha256','verified_at')) {
            if ($task.PSObject.Properties.Match($name).Count -eq 0) { Add-Member -InputObject $task -NotePropertyName $name -NotePropertyValue $null }
        }
        foreach ($name in @('callback_event_id','callback_receipt_path','callback_receipt_sha256','callback_received_at','callback_ack_receipt_path','callback_ack_receipt_sha256','callback_acknowledged_at')) {
            if ($task.PSObject.Properties.Match($name).Count -eq 0) { Add-Member -InputObject $task -NotePropertyName $name -NotePropertyValue $null }
        }
        if($task.PSObject.Properties.Match('callback_target_thread_id').Count -eq 0){Add-Member -InputObject $task -NotePropertyName callback_target_thread_id -NotePropertyValue $(if([string]::IsNullOrWhiteSpace([string]$task.callback_event_id)){$null}else{$Workflow.controller_thread_id})}
        if($task.PSObject.Properties.Match('callback_target_host_id').Count -eq 0){Add-Member -InputObject $task -NotePropertyName callback_target_host_id -NotePropertyValue $(if([string]::IsNullOrWhiteSpace([string]$task.callback_event_id)){$null}else{$Workflow.controller_host_id})}
        if($task.PSObject.Properties.Match('dispatch_controller_epoch').Count -eq 0){Add-Member -InputObject $task -NotePropertyName dispatch_controller_epoch -NotePropertyValue $(if([string]::IsNullOrWhiteSpace([string]$task.callback_event_id)){$null}else{[int64]$Workflow.controller_epoch})}
        if($task.PSObject.Properties.Match('callback_status').Count -eq 0){Add-Member -InputObject $task -NotePropertyName callback_status -NotePropertyValue 'not-prepared'}
        if($task.PSObject.Properties.Match('wait_revision').Count -eq 0){Add-Member -InputObject $task -NotePropertyName wait_revision -NotePropertyValue $null}
        if($task.PSObject.Properties.Match('result_truncated').Count -eq 0){Add-Member -InputObject $task -NotePropertyName result_truncated -NotePropertyValue $false}
        if($task.PSObject.Properties.Match('verification_status').Count -eq 0){
            $verificationStatus=$(if($sourceStateVersion -lt 6 -and $task.status -eq 'completed' -and $task.verified){$task.verified=$false;'legacy-unverified'}elseif($task.verified -and -not [string]::IsNullOrWhiteSpace($task.verification_receipt_path)){'trusted'}else{'unverified'})
            Add-Member -InputObject $task -NotePropertyName verification_status -NotePropertyValue $verificationStatus
        }
    }
    if ([int]$Workflow.state_version -lt 13) { $Workflow.state_version = 13 }
}

function Write-Event {
    param([string]$StateDirectory,$Workflow,[string]$Type,[string]$TaskId,[string]$From,[string]$To,[string]$Reason)
    $Workflow.event_sequence = [int]$Workflow.event_sequence + 1
    $event = [ordered]@{ sequence=$Workflow.event_sequence; workflow_id=$Workflow.workflow_id; type=$Type; task_id=$TaskId; from_status=$From; to_status=$To; reason=$Reason; created_at=(Get-UtcTimestamp) }
    $line = ($event | ConvertTo-Json -Compress)
    [System.IO.File]::AppendAllText((Join-Path $StateDirectory 'events.jsonl'),$line + [Environment]::NewLine,[System.Text.UTF8Encoding]::new($false))
}

function Initialize-WorkflowState {
    param([string]$ProjectPath,[string]$WorkflowId,[string]$ControllerThreadId,[string]$ControllerHostId='local')
    $resolved = [System.IO.Path]::GetFullPath($ProjectPath)
    $state = Join-Path $resolved '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath = Join-Path $state 'workflow.json'
        if (Test-Path -LiteralPath $workflowPath) { throw 'Workflow already exists.' }
        $now = Get-UtcTimestamp
        $workflow = [ordered]@{ workflow_id=$WorkflowId; project_path=$resolved; state_version=13; controller_thread_id=$(if([string]::IsNullOrWhiteSpace($ControllerThreadId)){$null}else{$ControllerThreadId}); controller_host_id=$(if([string]::IsNullOrWhiteSpace($ControllerThreadId)){$null}else{$ControllerHostId}); controller_epoch=$(if([string]::IsNullOrWhiteSpace($ControllerThreadId)){0}else{1}); controller_history=@(); status='draft'; current_stage='analysis'; authorization='read-only'; event_sequence=0; created_at=$now; updated_at=$now }
        $tasks = @()
        Write-Event $state $workflow 'workflow_initialized' $null $null 'draft' 'initialization'
        Write-JsonAtomic $workflow $workflowPath
        Write-JsonAtomic $tasks (Join-Path $state 'tasks.json')
        Write-JsonAtomic @() (Join-Path $state 'external-actions.json')
        Write-JsonAtomic @() (Join-Path $state 'action-executions.json')
    }
}

function Start-WorkflowExternalAction {
    param([string]$ProjectPath,[string]$TaskId,[ValidateSet('dispatch_send','callback_ack')][string]$ActionType,[int64]$ExpectedControllerEpoch)
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json';$tasksPath=Join-Path $state 'tasks.json';$actionsPath=Join-Path $state 'external-actions.json'
        $workflow=Read-StateJson $workflowPath;$tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_});Add-Defaults $workflow $tasks;$actions=@(Read-ExternalActions $state)
        if([int64]$workflow.controller_epoch -ne $ExpectedControllerEpoch){throw 'STALE_CONTROLLER_LEASE: controller epoch changed.'}
        $task=@($tasks|Where-Object{$_.task_id -eq $TaskId});if($task.Count -ne 1){throw "Task not found: $TaskId"};$task=$task[0]
        $prior=@($actions|Where-Object{$_.task_id -eq $TaskId -and $_.action_type -eq $ActionType})
        if(@($prior|Where-Object{$_.status -ne 'cancelled'}).Count -gt 0){throw 'EXTERNAL_ACTION_ALREADY_STARTED: inspect the existing action instead of sending again.'}
        if($ActionType -eq 'dispatch_send'){
            if($task.status -ne 'approved' -or $task.delivery_status -ne 'prepared'){throw 'Task is not ready for dispatch send.'}
            $payload=[ordered]@{threadId=$task.thread_id;hostId=$task.host_id;dispatch_id=$task.dispatch_id;dispatch_path=$task.dispatch_path}
        }else{
            if($task.callback_status -ne 'received'){throw 'Task callback is not ready for acknowledgement.'}
            $body=[ordered]@{type='callback_ack';event_id=$task.callback_event_id;workflow_id=$workflow.workflow_id;task_id=$task.task_id;dispatch_id=$task.dispatch_id;acknowledged_by_thread_id=$workflow.controller_thread_id;status='acknowledged'}|ConvertTo-Json -Compress
            $payload=[ordered]@{threadId=$task.thread_id;hostId=$task.host_id;callback_event_id=$task.callback_event_id;prompt=$body}
        }
        $attempt=$prior.Count+1;$actionId="$($workflow.workflow_id):$($workflow.controller_epoch):$TaskId`:$ActionType`:$attempt";$now=Get-UtcTimestamp
        $action=[pscustomobject][ordered]@{action_id=$actionId;action_type=$ActionType;task_id=$TaskId;controller_thread_id=$workflow.controller_thread_id;controller_host_id=$workflow.controller_host_id;controller_epoch=[int64]$workflow.controller_epoch;attempt=$attempt;status='prepared';payload=$payload;payload_sha256=(Get-ObjectSha256 $payload);receipt_path=$null;receipt_sha256=$null;message_id=$null;cursor=$null;resolution_evidence_path=$null;resolution_evidence_sha256=$null;created_at=$now;completed_at=$null;cancelled_at=$null}
        $actions+=$action;Write-Event $state $workflow 'external_action_started' $TaskId $null 'prepared' $actionId
        $workflow.updated_at=$now;Write-JsonAtomic $workflow $workflowPath;Write-JsonAtomic $tasks $tasksPath;Write-JsonAtomic $actions $actionsPath
        $action
    }
}

function Complete-WorkflowExternalAction {
    param([string]$ProjectPath,[string]$ActionId,[string]$ReceiptPath,[string]$MessageId,[string]$Cursor,[string]$EvidencePath)
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json';$tasksPath=Join-Path $state 'tasks.json';$actionsPath=Join-Path $state 'external-actions.json'
        $workflow=Read-StateJson $workflowPath;$tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_});Add-Defaults $workflow $tasks;$actions=@(Read-ExternalActions $state)
        $action=@($actions|Where-Object{$_.action_id -eq $ActionId});if($action.Count -ne 1){throw "External action not found: $ActionId"};$action=$action[0]
        if($action.status -eq 'completed'){
            if(-not(Test-Path -LiteralPath $ReceiptPath) -or (Get-FileHash -LiteralPath $ReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $action.receipt_sha256){throw 'Completed external action receipt does not match.'}
            return $action
        }
        if($action.status -ne 'prepared'){throw 'Only a prepared external action can be completed.'}
        if([int64]$action.controller_epoch -ne [int64]$workflow.controller_epoch -or $action.controller_thread_id -ne $workflow.controller_thread_id -or $action.controller_host_id -ne $workflow.controller_host_id){
            if([string]::IsNullOrWhiteSpace($EvidencePath) -or -not(Test-Path -LiteralPath $EvidencePath)){throw 'STALE_CONTROLLER_LEASE: takeover recovery requires separate delivery evidence.'}
            $resolvedEvidence=[IO.Path]::GetFullPath($EvidencePath);$action.resolution_evidence_path=$resolvedEvidence;$action.resolution_evidence_sha256=(Get-FileHash -LiteralPath $resolvedEvidence -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        if(-not(Test-Path -LiteralPath $ReceiptPath)){throw 'External action receipt file not found.'}
        $resolved=[IO.Path]::GetFullPath($ReceiptPath);$action.receipt_path=$resolved;$action.receipt_sha256=(Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant();$action.message_id=$(if([string]::IsNullOrWhiteSpace($MessageId)){$null}else{$MessageId});$action.cursor=$(if([string]::IsNullOrWhiteSpace($Cursor)){$null}else{$Cursor});$action.status='completed';$action.completed_at=Get-UtcTimestamp
        Write-Event $state $workflow 'external_action_completed' $action.task_id 'prepared' 'completed' $ActionId
        $workflow.updated_at=Get-UtcTimestamp;Write-JsonAtomic $workflow $workflowPath;Write-JsonAtomic $tasks $tasksPath;Write-JsonAtomic $actions $actionsPath
        $action
    }
}

function Cancel-WorkflowExternalAction {
    param([string]$ProjectPath,[string]$ActionId,[string]$EvidencePath)
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json';$tasksPath=Join-Path $state 'tasks.json';$actionsPath=Join-Path $state 'external-actions.json'
        $workflow=Read-StateJson $workflowPath;$tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_});Add-Defaults $workflow $tasks;$actions=@(Read-ExternalActions $state)
        $action=@($actions|Where-Object{$_.action_id -eq $ActionId});if($action.Count -ne 1){throw "External action not found: $ActionId"};$action=$action[0]
        if($action.status -ne 'prepared'){throw 'Only an unresolved prepared action can be cancelled.'}
        if(-not(Test-Path -LiteralPath $EvidencePath)){throw 'Resolution evidence file not found.'}
        $resolved=[IO.Path]::GetFullPath($EvidencePath);$action.resolution_evidence_path=$resolved;$action.resolution_evidence_sha256=(Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant();$action.status='cancelled';$action.cancelled_at=Get-UtcTimestamp
        Write-Event $state $workflow 'external_action_cancelled' $action.task_id 'prepared' 'cancelled' $ActionId
        $workflow.updated_at=Get-UtcTimestamp;Write-JsonAtomic $workflow $workflowPath;Write-JsonAtomic $tasks $tasksPath;Write-JsonAtomic $actions $actionsPath
        $action
    }
}

function Claim-WorkflowAction {
    param([string]$ProjectPath,[string]$PlanPath,[string]$ActionId,[int64]$ExpectedControllerEpoch,[int]$LeaseSeconds=300)
    if($LeaseSeconds -lt 30 -or $LeaseSeconds -gt 3600){throw 'LeaseSeconds must be between 30 and 3600.'}
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json';$tasksPath=Join-Path $state 'tasks.json';$externalPath=Join-Path $state 'external-actions.json';$executionsPath=Join-Path $state 'action-executions.json'
        $workflow=Read-StateJson $workflowPath;$tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_});Add-Defaults $workflow $tasks
        if([int64]$workflow.controller_epoch -ne $ExpectedControllerEpoch){throw 'STALE_CONTROLLER_LEASE: controller epoch changed.'}
        if([int64]$workflow.controller_epoch -lt 1 -or [string]::IsNullOrWhiteSpace([string]$workflow.controller_thread_id) -or [string]::IsNullOrWhiteSpace([string]$workflow.controller_host_id)){throw 'A configured controller is required to claim an action.'}
        if(-not(Test-Path -LiteralPath $PlanPath)){throw 'Action plan file not found.'};$resolvedPlan=[IO.Path]::GetFullPath($PlanPath);$plan=Read-StateJson $resolvedPlan
        if($plan.schema_version -ne 5 -or $plan.workflow_id -ne $workflow.workflow_id -or [int64]$plan.controller_epoch -ne [int64]$workflow.controller_epoch -or $plan.controller_thread_id -ne $workflow.controller_thread_id -or $plan.controller_host_id -ne $workflow.controller_host_id){throw 'STALE_ACTION_PLAN: plan identity changed.'}
        foreach($pair in @(@($plan.workflow_state_sha256,$workflowPath),@($plan.tasks_state_sha256,$tasksPath),@($plan.external_actions_sha256,$externalPath),@($plan.action_executions_sha256,$executionsPath))){$actual=$(if(Test-Path -LiteralPath $pair[1]){(Get-FileHash $pair[1] -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null});if($pair[0] -ne $actual){throw 'STALE_ACTION_PLAN: state changed.'}}
        $action=@($plan.actions|Where-Object{$_.action_id -eq $ActionId});if($action.Count -ne 1){throw 'Action not found exactly once in plan.'};$action=$action[0]
        $executions=@(Read-ActionExecutions $state);if(@($executions|Where-Object{$_.action_id -eq $ActionId}).Count){throw 'ACTION_ALREADY_CLAIMED: inspect the existing execution checkpoint.'}
        $prior=@($executions|Where-Object{$_.operation_sha256 -eq $action.operation_sha256}|Sort-Object attempt);if(@($prior|Where-Object{$_.status -in @('claimed','failed')}).Count){throw 'ACTION_OPERATION_BLOCKED: resolve or authorize retry before claiming again.'}
        $attempt=$prior.Count+1;$now=[DateTime]::UtcNow;$executionId="$ActionId`:execution:$attempt";$record=[pscustomobject][ordered]@{execution_id=$executionId;action_id=$ActionId;action_type=$action.type;task_ids=@($action.task_ids);operation_sha256=$action.operation_sha256;attempt=$attempt;plan_path=$resolvedPlan;plan_sha256=(Get-FileHash $resolvedPlan -Algorithm SHA256).Hash.ToLowerInvariant();action_sha256=(Get-ObjectSha256 $action);controller_thread_id=$workflow.controller_thread_id;controller_host_id=$workflow.controller_host_id;controller_epoch=[int64]$workflow.controller_epoch;status='claimed';lease_expires_at=$now.AddSeconds($LeaseSeconds).ToString('o');evidence_path=$null;evidence_sha256=$null;error=$null;resolution_reason=$null;retry_reason=$null;claimed_at=$now.ToString('o');completed_at=$null;failed_at=$null;resolved_at=$null;retry_authorized_at=$null}
        Add-Member -InputObject $record -NotePropertyName retry_evidence_path -NotePropertyValue $null;Add-Member -InputObject $record -NotePropertyName retry_evidence_sha256 -NotePropertyValue $null
        $executions+=$record;Write-Event $state $workflow 'action_claimed' $(@($action.task_ids)-join ',') $null 'claimed' $executionId;$workflow.updated_at=Get-UtcTimestamp
        Write-JsonAtomic $workflow $workflowPath;Write-JsonAtomic $tasks $tasksPath;Write-JsonAtomic $executions $executionsPath;$record
    }
}

function Set-WorkflowActionExecutionResult {
    param([string]$ProjectPath,[string]$ExecutionId,[ValidateSet('completed','failed')][string]$Status,[string]$EvidencePath,[string]$ErrorMessage)
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json';$tasksPath=Join-Path $state 'tasks.json';$executionsPath=Join-Path $state 'action-executions.json'
        $workflow=Read-StateJson $workflowPath;$tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_});Add-Defaults $workflow $tasks;$executions=@(Read-ActionExecutions $state)
        $record=@($executions|Where-Object{$_.execution_id -eq $ExecutionId});if($record.Count -ne 1){throw 'Action execution not found.'};$record=$record[0]
        if($record.status -eq $Status){if(-not(Test-Path -LiteralPath $EvidencePath) -or (Get-FileHash $EvidencePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $record.evidence_sha256){throw 'Action execution evidence does not match.'};return $record}
        if($record.status -ne 'claimed'){throw 'Only a claimed action execution can be resolved.'}
        if($record.controller_epoch -ne $workflow.controller_epoch -or $record.controller_thread_id -ne $workflow.controller_thread_id -or $record.controller_host_id -ne $workflow.controller_host_id){throw 'STALE_CONTROLLER_LEASE: action belongs to another controller lease.'}
        if([DateTime]::Parse($record.lease_expires_at).ToUniversalTime() -lt [DateTime]::UtcNow){throw 'ACTION_LEASE_EXPIRED: inspect the execution before recovery.'}
        if(-not(Test-Path -LiteralPath $EvidencePath)){throw 'Action execution evidence file not found.'};if($Status -eq 'failed' -and [string]::IsNullOrWhiteSpace($ErrorMessage)){throw 'ErrorMessage is required for failed execution.'}
        $resolved=[IO.Path]::GetFullPath($EvidencePath);$record.evidence_path=$resolved;$record.evidence_sha256=(Get-FileHash $resolved -Algorithm SHA256).Hash.ToLowerInvariant();$record.status=$Status;$record.error=$(if($Status -eq 'failed'){$ErrorMessage}else{$null});$now=Get-UtcTimestamp
        if($Status -eq 'completed'){$record.completed_at=$now}else{$record.failed_at=$now};Write-Event $state $workflow "action_$Status" $(@($record.task_ids)-join ',') 'claimed' $Status $ExecutionId;$workflow.updated_at=$now
        Write-JsonAtomic $workflow $workflowPath;Write-JsonAtomic $tasks $tasksPath;Write-JsonAtomic $executions $executionsPath;$record
    }
}

function Renew-WorkflowActionLease {
    param([string]$ProjectPath,[string]$ExecutionId,[int]$LeaseSeconds=300)
    if($LeaseSeconds -lt 30 -or $LeaseSeconds -gt 3600){throw 'LeaseSeconds must be between 30 and 3600.'}
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json';$tasksPath=Join-Path $state 'tasks.json';$executionsPath=Join-Path $state 'action-executions.json';$workflow=Read-StateJson $workflowPath;$tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_});Add-Defaults $workflow $tasks;$executions=@(Read-ActionExecutions $state)
        $record=@($executions|Where-Object{$_.execution_id -eq $ExecutionId});if($record.Count -ne 1){throw 'Action execution not found.'};$record=$record[0]
        if($record.status -ne 'claimed'){throw 'Only a claimed action lease can be renewed.'};if($record.controller_epoch -ne $workflow.controller_epoch -or $record.controller_thread_id -ne $workflow.controller_thread_id -or $record.controller_host_id -ne $workflow.controller_host_id){throw 'STALE_CONTROLLER_LEASE: action belongs to another controller lease.'}
        if([DateTime]::Parse($record.lease_expires_at).ToUniversalTime() -lt [DateTime]::UtcNow){throw 'ACTION_LEASE_EXPIRED: expired leases require inspection.'}
        $record.lease_expires_at=[DateTime]::UtcNow.AddSeconds($LeaseSeconds).ToString('o');Write-Event $state $workflow 'action_lease_renewed' $(@($record.task_ids)-join ',') 'claimed' 'claimed' $ExecutionId;$workflow.updated_at=Get-UtcTimestamp;Write-JsonAtomic $workflow $workflowPath;Write-JsonAtomic $tasks $tasksPath;Write-JsonAtomic $executions $executionsPath;$record
    }
}

function Resolve-WorkflowActionExecution {
    param([string]$ProjectPath,[string]$ExecutionId,[ValidateSet('abandoned','reconciled')][string]$Resolution,[string]$EvidencePath,[string]$Reason)
    foreach($value in @($ExecutionId,$EvidencePath,$Reason)){if([string]::IsNullOrWhiteSpace($value)){throw 'ExecutionId, EvidencePath, and Reason are required.'}}
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json';$tasksPath=Join-Path $state 'tasks.json';$executionsPath=Join-Path $state 'action-executions.json';$workflow=Read-StateJson $workflowPath;$tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_});Add-Defaults $workflow $tasks;$executions=@(Read-ActionExecutions $state)
        $record=@($executions|Where-Object{$_.execution_id -eq $ExecutionId});if($record.Count -ne 1){throw 'Action execution not found.'};$record=$record[0]
        if($record.status -eq $Resolution){if(-not(Test-Path $EvidencePath) -or (Get-FileHash $EvidencePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $record.evidence_sha256){throw 'Resolution evidence does not match.'};return $record}
        if($record.status -ne 'claimed'){throw 'Only a claimed execution can be resolved.'}
        $sameLease=($record.controller_epoch -eq $workflow.controller_epoch -and $record.controller_thread_id -eq $workflow.controller_thread_id -and $record.controller_host_id -eq $workflow.controller_host_id);$expired=([DateTime]::Parse($record.lease_expires_at).ToUniversalTime() -lt [DateTime]::UtcNow)
        if($sameLease -and -not $expired){throw 'ACTIVE_ACTION_LEASE: an active lease cannot be resolved.'}
        if(-not(Test-Path -LiteralPath $EvidencePath)){throw 'Resolution evidence file not found.'}
        if($Resolution -eq 'abandoned' -and $record.action_type -eq 'begin_external_action'){
            $external=@(Read-ExternalActions $state|Where-Object{$_.task_id -in @($record.task_ids) -and $_.status -ne 'cancelled'});if($external.Count){throw 'External action state must be resolved before abandoning its plan execution.'}
        }
        $resolved=[IO.Path]::GetFullPath($EvidencePath);$record.status=$Resolution;$record.evidence_path=$resolved;$record.evidence_sha256=(Get-FileHash $resolved -Algorithm SHA256).Hash.ToLowerInvariant();$record.resolution_reason=$Reason;$record.resolved_at=Get-UtcTimestamp
        Write-Event $state $workflow "action_$Resolution" $(@($record.task_ids)-join ',') 'claimed' $Resolution $ExecutionId;$workflow.updated_at=Get-UtcTimestamp;Write-JsonAtomic $workflow $workflowPath;Write-JsonAtomic $tasks $tasksPath;Write-JsonAtomic $executions $executionsPath;$record
    }
}

function Authorize-WorkflowActionRetry {
    param([string]$ProjectPath,[string]$ExecutionId,[string]$EvidencePath,[string]$Reason)
    foreach($value in @($ExecutionId,$EvidencePath,$Reason)){if([string]::IsNullOrWhiteSpace($value)){throw 'ExecutionId, EvidencePath, and Reason are required.'}}
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json';$tasksPath=Join-Path $state 'tasks.json';$executionsPath=Join-Path $state 'action-executions.json';$workflow=Read-StateJson $workflowPath;$tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_});Add-Defaults $workflow $tasks;$executions=@(Read-ActionExecutions $state)
        $record=@($executions|Where-Object{$_.execution_id -eq $ExecutionId});if($record.Count -ne 1){throw 'Action execution not found.'};$record=$record[0]
        if($record.status -eq 'retry_authorized'){if(-not(Test-Path $EvidencePath) -or (Get-FileHash $EvidencePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $record.retry_evidence_sha256){throw 'Retry evidence does not match.'};return $record}
        if($record.status -ne 'failed'){throw 'Only a failed execution can receive retry authorization.'};if(-not(Test-Path -LiteralPath $EvidencePath)){throw 'Retry authorization evidence file not found.'}
        $resolved=[IO.Path]::GetFullPath($EvidencePath);$record.status='retry_authorized';$record.retry_evidence_path=$resolved;$record.retry_evidence_sha256=(Get-FileHash $resolved -Algorithm SHA256).Hash.ToLowerInvariant();$record.retry_reason=$Reason;$record.retry_authorized_at=Get-UtcTimestamp
        Write-Event $state $workflow 'action_retry_authorized' $(@($record.task_ids)-join ',') 'failed' 'retry_authorized' $ExecutionId;$workflow.updated_at=Get-UtcTimestamp;Write-JsonAtomic $workflow $workflowPath;Write-JsonAtomic $tasks $tasksPath;Write-JsonAtomic $executions $executionsPath;$record
    }
}

function Set-WorkflowController {
    param([string]$ProjectPath,[string]$ControllerThreadId,[string]$ControllerHostId='local')
    if([string]::IsNullOrWhiteSpace($ControllerThreadId)){throw 'ControllerThreadId is required.'}
    if([string]::IsNullOrWhiteSpace($ControllerHostId)){throw 'ControllerHostId is required.'}
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json';$tasksPath=Join-Path $state 'tasks.json'
        $workflow=Read-StateJson $workflowPath;$tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_});Add-Defaults $workflow $tasks
        if(-not [string]::IsNullOrWhiteSpace($workflow.controller_thread_id)){
            if($workflow.controller_thread_id -eq $ControllerThreadId -and $workflow.controller_host_id -eq $ControllerHostId){return}
            throw 'Workflow controller identity is immutable once configured.'
        }
        if(@($tasks|Where-Object{$_.delivery_status -ne 'not-prepared'}).Count -gt 0){throw 'Controller identity must be configured before preparing dispatches.'}
        if(@($tasks|Where-Object{$_.thread_id -eq $ControllerThreadId -and $_.host_id -eq $ControllerHostId}).Count -gt 0){throw 'Controller identity cannot also be a worker task.'}
        $workflow.controller_thread_id=$ControllerThreadId;$workflow.controller_host_id=$ControllerHostId
        $workflow.controller_epoch=1
        Write-Event $state $workflow 'controller_configured' $null $null 'configured' $ControllerThreadId
        $workflow.updated_at=Get-UtcTimestamp;Write-JsonAtomic $workflow $workflowPath;Write-JsonAtomic $tasks $tasksPath
    }
}

function Set-WorkflowControllerTakeover {
    param([string]$ProjectPath,[string]$ExpectedControllerThreadId,[string]$ExpectedControllerHostId,[int64]$ExpectedControllerEpoch,[string]$ControllerThreadId,[string]$ControllerHostId='local',[string]$Reason)
    foreach($value in @($ExpectedControllerThreadId,$ExpectedControllerHostId,$ControllerThreadId,$ControllerHostId,$Reason)){if([string]::IsNullOrWhiteSpace($value)){throw 'Expected controller, new controller, and reason are required.'}}
    if($ExpectedControllerEpoch -lt 1){throw 'ExpectedControllerEpoch must be at least 1.'}
    if($ExpectedControllerThreadId -eq $ControllerThreadId -and $ExpectedControllerHostId -eq $ControllerHostId){throw 'New controller must differ from the current controller.'}
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json';$tasksPath=Join-Path $state 'tasks.json'
        $workflow=Read-StateJson $workflowPath;$tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_});Add-Defaults $workflow $tasks
        if(-not(Test-WorkflowStateIntegrity -ProjectPath $ProjectPath)){throw 'Workflow integrity audit failed before controller takeover.'}
        if($workflow.controller_thread_id -ne $ExpectedControllerThreadId -or $workflow.controller_host_id -ne $ExpectedControllerHostId -or [int64]$workflow.controller_epoch -ne $ExpectedControllerEpoch){throw 'STALE_CONTROLLER_LEASE: controller identity or epoch changed.'}
        if(@($tasks|Where-Object{$_.thread_id -eq $ControllerThreadId -and $_.host_id -eq $ControllerHostId}).Count -gt 0){throw 'Controller identity cannot also be a worker task.'}
        $now=Get-UtcTimestamp
        $history=@($workflow.controller_history)
        $history += [pscustomobject][ordered]@{epoch=[int64]$workflow.controller_epoch;thread_id=$workflow.controller_thread_id;host_id=$workflow.controller_host_id;replaced_at=$now;reason=$Reason}
        $workflow.controller_history=$history;$workflow.controller_thread_id=$ControllerThreadId;$workflow.controller_host_id=$ControllerHostId;$workflow.controller_epoch=[int64]$workflow.controller_epoch+1
        Write-Event $state $workflow 'controller_taken_over' $null $ExpectedControllerThreadId $ControllerThreadId $Reason
        $workflow.updated_at=$now;Write-JsonAtomic $workflow $workflowPath;Write-JsonAtomic $tasks $tasksPath
    }
}

function Register-WorkflowTask {
    param([string]$ProjectPath,[string]$TaskId,[string]$ThreadId,[string]$HostId,[string]$Role,[string]$Objective,[string]$Authorization,[string]$BaseRevision,[string[]]$DependsOn,[string[]]$AllowedFiles,[string]$RepairOf)
    $state = Join-Path ([System.IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath = Join-Path $state 'workflow.json'; $tasksPath = Join-Path $state 'tasks.json'
        $workflow = Read-StateJson $workflowPath; $tasks = @(Read-StateJson $tasksPath | ForEach-Object { $_ }); Add-Defaults $workflow $tasks
        if (@($tasks | Where-Object { $_.task_id -eq $TaskId }).Count -gt 0) { throw "Duplicate task_id: $TaskId" }
        if (@($tasks | Where-Object { $_.thread_id -eq $ThreadId }).Count -gt 0) { throw "Duplicate thread_id: $ThreadId" }
        if($workflow.controller_thread_id -eq $ThreadId -and $workflow.controller_host_id -eq $HostId){throw 'Worker task cannot use the controller identity.'}
        $repairSource=$null
        if(-not [string]::IsNullOrWhiteSpace($RepairOf)){
            $source=@($tasks|Where-Object{$_.task_id -eq $RepairOf});if($source.Count -ne 1){throw "Repair source not found: $RepairOf"};$repairSource=$source[0]
            if($repairSource.status -notin @('failed','blocked')){throw 'Repair source must be failed or blocked.'}
            if([int]$repairSource.repair_count -ge 1){throw 'Only one targeted repair is allowed.'}
            if($repairSource.role -ne $Role){throw 'Repair task role must match its source task.'}
            if($repairSource.authorization -ne $Authorization){throw 'Repair task cannot expand authorization.'}
            if((@($repairSource.depends_on|Sort-Object)-join '|') -ne (@($DependsOn|Sort-Object)-join '|')){throw 'Repair task must preserve source dependencies.'}
            if(@($AllowedFiles|Where-Object{$_ -notin @($repairSource.allowed_files)}).Count -gt 0){throw 'Repair task cannot expand allowed files.'}
        }
        foreach ($dependency in @($DependsOn)) { if (@($tasks | Where-Object { $_.task_id -eq $dependency }).Count -eq 0) { throw "Dependency not found: $dependency" } }
        $dependencyRoles = @($tasks | Where-Object { $_.task_id -in @($DependsOn) } | ForEach-Object { $_.role })
        if ($Role -eq 'developer' -and 'analyst' -notin $dependencyRoles) { throw 'Developer must depend on an analyst task.' }
        if ($Role -eq 'tester' -and 'developer' -notin $dependencyRoles) { throw 'Tester must depend on a developer task.' }
        if ($Role -eq 'reviewer' -and ('developer' -notin $dependencyRoles -or 'tester' -notin $dependencyRoles)) { throw 'Reviewer must depend on developer and tester tasks.' }
        if ($Role -eq 'developer' -and $Authorization -notin @('implementation-approved','git-approved','deployment-approved')) { throw 'Developer task requires implementation approval.' }
        if ($Role -eq 'tester' -and $Authorization -notin @('test-approved','deployment-approved')) { throw 'Tester task requires test approval.' }
        $activeFiles = @($tasks | Where-Object { $_.role -eq 'developer' -and $_.status -notin $script:TerminalStates } | ForEach-Object { $_.allowed_files })
        $overlap = @($AllowedFiles | Where-Object { $_ -in $activeFiles })
        if ($Role -eq 'developer' -and $overlap.Count -gt 0) { throw "File ownership conflict: $($overlap -join ', ')" }
        $task = [ordered]@{ task_id=$TaskId; thread_id=$ThreadId; host_id=$HostId; role=$Role; repair_of=$(if([string]::IsNullOrWhiteSpace($RepairOf)){$null}else{$RepairOf}); status='draft'; depends_on=@($DependsOn); project_path=$workflow.project_path; base_revision=$BaseRevision; allowed_files=@($AllowedFiles); objective=$Objective; authorization=$Authorization; repair_count=0; dispatch_count=0; dispatch_id=$null; delivery_status='not-prepared'; dispatch_path=$null; sent_message_id=$null; send_receipt_path=$null; send_receipt_sha256=$null; result_message_id=$null; read_cursor=$null; wait_revision=$null; wait_snapshot_path=$null; wait_snapshot_sha256=$null; latest_turn_id=$null; latest_turn_status=$null; latest_item_id=$null; latest_item_phase=$null; result_truncated=$false; callback_event_id=$null; callback_target_thread_id=$null; callback_target_host_id=$null; dispatch_controller_epoch=$null; callback_status='not-prepared'; callback_receipt_path=$null; callback_receipt_sha256=$null; callback_received_at=$null; callback_ack_receipt_path=$null; callback_ack_receipt_sha256=$null; callback_acknowledged_at=$null; observation_path=$null; observation_sha256=$null; observed_status=$null; observed_at=$null; dispatched_at=$null; acknowledged_at=$null; result_received_at=$null; raw_result_path=$null; raw_result_sha256=$null; normalized_result_path=$null; normalized_result_sha256=$null; verification_receipt_path=$null; verification_receipt_sha256=$null; verification_status='unverified'; verified_at=$null; verified=$false; updated_at=(Get-UtcTimestamp) }
        if($null -ne $repairSource){$repairSource.repair_count=[int]$repairSource.repair_count+1;$repairSource.updated_at=Get-UtcTimestamp}
        $tasks += [pscustomobject]$task
        Write-Event $state $workflow 'task_registered' $TaskId $null 'draft' 'registration'
        $workflow.updated_at = Get-UtcTimestamp; Write-JsonAtomic $workflow $workflowPath; Write-JsonAtomic $tasks $tasksPath
    }
}

function New-WorkflowDispatch {
    param([string]$ProjectPath,[string]$TaskId)
    $state = Join-Path ([System.IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath = Join-Path $state 'workflow.json'; $tasksPath = Join-Path $state 'tasks.json'
        $workflow = Read-StateJson $workflowPath; $tasks = @(Read-StateJson $tasksPath | ForEach-Object { $_ }); Add-Defaults $workflow $tasks
        $task = @($tasks | Where-Object { $_.task_id -eq $TaskId })
        if ($task.Count -ne 1) { throw "Task not found: $TaskId" }; $task = $task[0]
        if ($task.status -ne 'approved') { throw 'Only an approved task can be prepared for dispatch.' }
        if([string]::IsNullOrWhiteSpace($workflow.controller_thread_id) -or [string]::IsNullOrWhiteSpace($workflow.controller_host_id)){throw 'Workflow controller identity must be configured before dispatch.'}
        if ($task.delivery_status -ne 'not-prepared' -or [int]$task.dispatch_count -gt 0) { throw 'Task dispatch was already prepared or sent.' }
        $dependencyRevisions=[Collections.Generic.List[object]]::new()
        foreach ($dependency in @($task.depends_on)) {
            $dep = @($tasks | Where-Object { $_.task_id -eq $dependency })
            if ($dep.Count -ne 1 -or $dep[0].status -ne 'completed' -or -not $dep[0].verified) { throw "Dependency is not verified complete: $dependency" }
            if(-not(Test-Path -LiteralPath $dep[0].normalized_result_path)){throw "Dependency result not found: $dependency"}
            $depResult=Read-StateJson $dep[0].normalized_result_path
            $dependencyRevisions.Add([pscustomobject][ordered]@{task_id=$dependency;end_revision=$depResult.end_revision})
        }
        $distinctRevisions=@($dependencyRevisions|ForEach-Object{$_.end_revision}|Select-Object -Unique)
        if($distinctRevisions.Count -gt 1){throw 'Dependencies do not describe one shared code revision.'}
        if($distinctRevisions.Count -eq 1 -and $task.base_revision -ne $distinctRevisions[0]){throw 'Task base revision does not match the verified dependency revision.'}
        $dispatchId = "$TaskId-$([guid]::NewGuid().ToString('N'))"
        $callbackEventId="$dispatchId`:completion"
        $callback=[ordered]@{event_id=$callbackEventId;target_thread_id=$workflow.controller_thread_id;target_host_id=$workflow.controller_host_id;status='completed'}
        $dispatch = [ordered]@{ dispatch_id=$dispatchId; workflow_id=$workflow.workflow_id; controller_epoch=[int64]$workflow.controller_epoch; task_id=$task.task_id; thread_id=$task.thread_id; host_id=$task.host_id; role=$task.role; repair_of=$task.repair_of; project_path=$task.project_path; base_revision=$task.base_revision; objective=$task.objective; depends_on=@($task.depends_on); dependency_revisions=@($dependencyRevisions); allowed_files=@($task.allowed_files); authorization=$task.authorization; callback=$callback; created_at=(Get-UtcTimestamp) }
        $dispatchDirectory = Join-Path $state 'dispatches'; $dispatchPath = Join-Path $dispatchDirectory "$dispatchId.json"
        Write-JsonAtomic $dispatch $dispatchPath
        $task.dispatch_id = $dispatchId; $task.dispatch_path = [System.IO.Path]::GetFullPath($dispatchPath); $task.delivery_status = 'prepared'; $task.callback_event_id=$callbackEventId;$task.callback_target_thread_id=$workflow.controller_thread_id;$task.callback_target_host_id=$workflow.controller_host_id;$task.dispatch_controller_epoch=[int64]$workflow.controller_epoch;$task.callback_status='prepared';$task.updated_at = Get-UtcTimestamp
        Write-Event $state $workflow 'dispatch_prepared' $TaskId 'not-prepared' 'prepared' $dispatchId
        $workflow.updated_at = Get-UtcTimestamp; Write-JsonAtomic $workflow $workflowPath; Write-JsonAtomic $tasks $tasksPath
        [pscustomobject]$dispatch
    }
}

function Confirm-WorkflowDispatchSent {
    param([string]$ProjectPath,[string]$TaskId,[string]$DispatchId,[string]$ReceiptPath,[string]$MessageId,[string]$Cursor,[string]$ExternalActionId)
    $state = Join-Path ([System.IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath = Join-Path $state 'workflow.json'; $tasksPath = Join-Path $state 'tasks.json'
        $workflow = Read-StateJson $workflowPath; $tasks = @(Read-StateJson $tasksPath | ForEach-Object { $_ }); Add-Defaults $workflow $tasks
        $task = @($tasks | Where-Object { $_.task_id -eq $TaskId })
        if ($task.Count -ne 1) { throw "Task not found: $TaskId" }; $task = $task[0]
        if ($task.status -ne 'approved' -or $task.delivery_status -ne 'prepared') { throw 'Task is not waiting for send confirmation.' }
        if ($task.dispatch_id -ne $DispatchId) { throw 'Dispatch ID does not match the prepared dispatch.' }
        if ([string]::IsNullOrWhiteSpace($ReceiptPath) -or -not (Test-Path -LiteralPath $ReceiptPath)) { throw 'A raw send receipt file is required.' }
        $resolvedReceipt=[IO.Path]::GetFullPath($ReceiptPath); $receiptHash=(Get-FileHash -LiteralPath $resolvedReceipt -Algorithm SHA256).Hash.ToLowerInvariant()
        $externalAction=@(Read-ExternalActions $state|Where-Object{$_.action_id -eq $ExternalActionId});if($externalAction.Count -ne 1 -or $externalAction[0].action_type -ne 'dispatch_send' -or $externalAction[0].task_id -ne $TaskId -or $externalAction[0].status -ne 'completed' -or $externalAction[0].receipt_sha256 -ne $receiptHash){throw 'A matching completed external dispatch action is required.'}
        if([string]$externalAction[0].message_id -ne [string]$MessageId -or [string]$externalAction[0].cursor -ne [string]$Cursor){throw 'Dispatch receipt metadata does not match the completed external action.'}
        $task.sent_message_id=$(if([string]::IsNullOrWhiteSpace($MessageId)){$null}else{$MessageId}); $task.send_receipt_path=$resolvedReceipt; $task.send_receipt_sha256=$receiptHash; $task.read_cursor=$Cursor; $task.delivery_status='sent'; $task.dispatched_at=Get-UtcTimestamp; $task.dispatch_count=[int]$task.dispatch_count+1; $task.status='dispatched'; $task.updated_at=Get-UtcTimestamp
        $stageByRole = @{ analyst='analysis'; developer='implementation'; tester='test'; reviewer='review' }; $workflow.current_stage=$stageByRole[[string]$task.role]; $workflow.status='running'
        Write-Event $state $workflow 'dispatch_sent' $TaskId 'prepared' 'sent' $MessageId
        $workflow.updated_at=Get-UtcTimestamp; Write-JsonAtomic $workflow $workflowPath; Write-JsonAtomic $tasks $tasksPath
    }
}

function Record-WorkflowThreadObservation {
    param([string]$ProjectPath,[string]$TaskId,[string]$ThreadId,[string]$HostId,[string]$ObservedProjectPath,[string]$ObservedStatus,[string]$Cursor,[string]$ObservationPath)
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json'; $tasksPath=Join-Path $state 'tasks.json'
        $workflow=Read-StateJson $workflowPath; $tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_}); Add-Defaults $workflow $tasks
        $task=@($tasks|Where-Object{$_.task_id -eq $TaskId}); if($task.Count -ne 1){throw "Task not found: $TaskId"}; $task=$task[0]
        if($task.thread_id -ne $ThreadId){throw 'Thread observation does not match the assigned thread.'}
        if($task.host_id -ne $HostId){throw 'Thread observation does not match the assigned host.'}
        if([IO.Path]::GetFullPath($task.project_path) -ne [IO.Path]::GetFullPath($ObservedProjectPath)){throw 'Thread observation project path does not match the workflow.'}
        if($ObservedStatus -notin @('active','idle','completed','needs_attention','unavailable','unknown')){throw 'Unsupported observed thread status.'}
        if([string]::IsNullOrWhiteSpace($ObservationPath) -or -not(Test-Path -LiteralPath $ObservationPath)){throw 'A raw observation file is required.'}
        $resolvedObservation=[IO.Path]::GetFullPath($ObservationPath)
        $task.observation_path=$resolvedObservation; $task.observation_sha256=(Get-FileHash -LiteralPath $resolvedObservation -Algorithm SHA256).Hash.ToLowerInvariant(); $task.observed_status=$ObservedStatus; $task.observed_at=Get-UtcTimestamp
        if(-not [string]::IsNullOrWhiteSpace($Cursor)){$task.read_cursor=$Cursor}; $task.updated_at=Get-UtcTimestamp
        Write-Event $state $workflow 'thread_observed' $TaskId $null $ObservedStatus $Cursor
        $workflow.updated_at=Get-UtcTimestamp; Write-JsonAtomic $workflow $workflowPath; Write-JsonAtomic $tasks $tasksPath
    }
}

function Record-WorkflowWaitSnapshot {
    param([string]$ProjectPath,[string]$TaskId,[string]$SnapshotPath)
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json';$tasksPath=Join-Path $state 'tasks.json'
        $workflow=Read-StateJson $workflowPath;$tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_});Add-Defaults $workflow $tasks
        $task=@($tasks|Where-Object{$_.task_id -eq $TaskId});if($task.Count -ne 1){throw "Task not found: $TaskId"};$task=$task[0]
        $snapshot=Read-StateJson $SnapshotPath
        if($snapshot.thread_id -ne $task.thread_id){throw 'Wait snapshot thread does not match the task.'};if($snapshot.host_id -ne $task.host_id){throw 'Wait snapshot host does not match the task.'}
        if($null -ne $task.wait_revision -and [int64]$snapshot.revision -le [int64]$task.wait_revision){throw 'Wait snapshot revision is not newer than the recorded revision.'}
        if([string]::IsNullOrWhiteSpace($snapshot.cursor)){throw 'Wait snapshot cursor is missing.'}
        if([string]::IsNullOrWhiteSpace($snapshot.raw_response_path) -or -not(Test-Path -LiteralPath $snapshot.raw_response_path)){throw 'Wait snapshot raw response file not found.'}
        $rawResponseHash=(Get-FileHash -LiteralPath $snapshot.raw_response_path -Algorithm SHA256).Hash.ToLowerInvariant()
        if($rawResponseHash -ne $snapshot.raw_response_sha256){throw 'Wait snapshot raw response hash mismatch.'}
        $resolved=[IO.Path]::GetFullPath($SnapshotPath);$task.wait_snapshot_path=$resolved;$task.wait_snapshot_sha256=(Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
        $task.wait_revision=[int64]$snapshot.revision;$task.read_cursor=$snapshot.cursor;$task.latest_turn_id=$snapshot.latest_turn_id;$task.latest_turn_status=$snapshot.latest_turn_status;$task.latest_item_id=$snapshot.latest_item_id;$task.latest_item_phase=$snapshot.latest_item_phase;$task.result_truncated=[bool]$snapshot.result_truncated;$task.observed_status=$snapshot.status;$task.observed_at=Get-UtcTimestamp;$task.updated_at=Get-UtcTimestamp
        Write-Event $state $workflow 'wait_snapshot_recorded' $TaskId $null $snapshot.status $snapshot.cursor
        $workflow.updated_at=Get-UtcTimestamp;Write-JsonAtomic $workflow $workflowPath;Write-JsonAtomic $tasks $tasksPath
    }
}

function Confirm-WorkflowAcknowledged {
    param([string]$ProjectPath,[string]$TaskId,[string]$DispatchId,[string]$Cursor)
    $state = Join-Path ([System.IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json'; $tasksPath=Join-Path $state 'tasks.json'
        $workflow=Read-StateJson $workflowPath; $tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_}); Add-Defaults $workflow $tasks
        $task=@($tasks|Where-Object{$_.task_id -eq $TaskId}); if($task.Count -ne 1){throw "Task not found: $TaskId"}; $task=$task[0]
        if($task.status -ne 'dispatched' -or $task.delivery_status -ne 'sent'){throw 'Task is not waiting for acknowledgement.'}
        if($task.dispatch_id -ne $DispatchId){throw 'Dispatch ID does not match.'}
        $task.delivery_status='acknowledged'; $task.read_cursor=$Cursor; $task.acknowledged_at=Get-UtcTimestamp; $task.status='running'; $task.updated_at=Get-UtcTimestamp
        Write-Event $state $workflow 'dispatch_acknowledged' $TaskId 'sent' 'acknowledged' $Cursor
        $workflow.updated_at=Get-UtcTimestamp; Write-JsonAtomic $workflow $workflowPath; Write-JsonAtomic $tasks $tasksPath
    }
}

function Receive-WorkflowCallback {
    param([string]$ProjectPath,[string]$TaskId,[string]$CallbackEventId,[string]$ReceiptPath)
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json';$tasksPath=Join-Path $state 'tasks.json'
        $workflow=Read-StateJson $workflowPath;$tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_});Add-Defaults $workflow $tasks
        $task=@($tasks|Where-Object{$_.task_id -eq $TaskId});if($task.Count -ne 1){throw "Task not found: $TaskId"};$task=$task[0]
        if($task.callback_event_id -ne $CallbackEventId){throw 'Callback event ID does not match the active dispatch.'}
        if($task.callback_status -in @('received','acknowledged')){return}
        if($task.callback_status -ne 'prepared'){throw 'Task is not waiting for a completion callback.'}
        if(-not(Test-Path -LiteralPath $ReceiptPath)){throw 'Callback receipt file not found.'}
        $receipt=Read-StateJson $ReceiptPath
        $expected=@{
            event_id=$task.callback_event_id;workflow_id=$workflow.workflow_id;task_id=$task.task_id;dispatch_id=$task.dispatch_id
            source_thread_id=$task.thread_id;source_host_id=$task.host_id;target_thread_id=$task.callback_target_thread_id;target_host_id=$task.callback_target_host_id;status='completed'
        }
        foreach($name in $expected.Keys){
            if($receipt.PSObject.Properties.Match($name).Count -eq 0 -or [string]$receipt.$name -ne [string]$expected[$name]){throw "Callback receipt identity mismatch: $name"}
        }
        $resolved=[IO.Path]::GetFullPath($ReceiptPath)
        $task.callback_receipt_path=$resolved;$task.callback_receipt_sha256=(Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
        $task.callback_received_at=Get-UtcTimestamp;$task.callback_status='received';$task.updated_at=Get-UtcTimestamp
        Write-Event $state $workflow 'callback_received' $TaskId 'prepared' 'received' $CallbackEventId
        $workflow.updated_at=Get-UtcTimestamp;Write-JsonAtomic $workflow $workflowPath;Write-JsonAtomic $tasks $tasksPath
    }
}

function Confirm-WorkflowCallbackAcknowledged {
    param([string]$ProjectPath,[string]$TaskId,[string]$CallbackEventId,[string]$ReceiptPath,[string]$ExternalActionId)
    $state=Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json';$tasksPath=Join-Path $state 'tasks.json'
        $workflow=Read-StateJson $workflowPath;$tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_});Add-Defaults $workflow $tasks
        $task=@($tasks|Where-Object{$_.task_id -eq $TaskId});if($task.Count -ne 1){throw "Task not found: $TaskId"};$task=$task[0]
        if($task.callback_event_id -ne $CallbackEventId){throw 'Callback event ID does not match the active dispatch.'}
        if($task.callback_status -eq 'acknowledged'){return}
        if($task.callback_status -ne 'received'){throw 'Completion callback has not been received.'}
        if(-not(Test-Path -LiteralPath $ReceiptPath)){throw 'Callback acknowledgement receipt file not found.'}
        $ackReceipt=Read-StateJson $ReceiptPath
        if($ackReceipt.PSObject.Properties.Match('threadId').Count -eq 0 -or $ackReceipt.threadId -ne $task.thread_id){throw 'Callback acknowledgement was not sent to the worker thread.'}
        $resolved=[IO.Path]::GetFullPath($ReceiptPath)
        $receiptHash=(Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant();$externalAction=@(Read-ExternalActions $state|Where-Object{$_.action_id -eq $ExternalActionId});if($externalAction.Count -ne 1 -or $externalAction[0].action_type -ne 'callback_ack' -or $externalAction[0].task_id -ne $TaskId -or $externalAction[0].status -ne 'completed' -or $externalAction[0].receipt_sha256 -ne $receiptHash){throw 'A matching completed external callback action is required.'}
        $task.callback_ack_receipt_path=$resolved;$task.callback_ack_receipt_sha256=$receiptHash
        $task.callback_acknowledged_at=Get-UtcTimestamp;$task.callback_status='acknowledged';$task.updated_at=Get-UtcTimestamp
        Write-Event $state $workflow 'callback_acknowledged' $TaskId 'received' 'acknowledged' $CallbackEventId
        $workflow.updated_at=Get-UtcTimestamp;Write-JsonAtomic $workflow $workflowPath;Write-JsonAtomic $tasks $tasksPath
    }
}

function Receive-WorkflowResult {
    param([string]$ProjectPath,[string]$TaskId,[string]$DispatchId,[string]$ThreadId,[string]$ResultMessageId,[string]$Cursor,[string]$RawResultPath)
    $state=Join-Path ([System.IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json'; $tasksPath=Join-Path $state 'tasks.json'
        $workflow=Read-StateJson $workflowPath; $tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_}); Add-Defaults $workflow $tasks
        $task=@($tasks|Where-Object{$_.task_id -eq $TaskId}); if($task.Count -ne 1){throw "Task not found: $TaskId"}; $task=$task[0]
        if($task.status -ne 'running' -or $task.delivery_status -ne 'acknowledged'){throw 'Task is not ready to receive a result.'}
        if($task.dispatch_id -ne $DispatchId){throw 'STALE_RESULT: Dispatch ID does not match the active round.'}; if($task.thread_id -ne $ThreadId){throw 'INVALID_RESULT: Thread ID does not match the assigned task.'}
        if([string]::IsNullOrWhiteSpace($ResultMessageId)){throw 'ResultMessageId is required.'}; if(-not(Test-Path -LiteralPath $RawResultPath)){throw 'Raw result file not found.'}
        $task.result_message_id=$ResultMessageId; $task.read_cursor=$Cursor; $task.raw_result_path=[IO.Path]::GetFullPath($RawResultPath); $task.raw_result_sha256=(Get-FileHash -LiteralPath $RawResultPath -Algorithm SHA256).Hash.ToLowerInvariant(); $task.result_received_at=Get-UtcTimestamp; $task.delivery_status='result_received'; $task.status='verifying'; $task.updated_at=Get-UtcTimestamp
        Write-Event $state $workflow 'result_received' $TaskId 'acknowledged' 'result_received' $ResultMessageId
        $workflow.updated_at=Get-UtcTimestamp; Write-JsonAtomic $workflow $workflowPath; Write-JsonAtomic $tasks $tasksPath
    }
}

function Confirm-WorkflowResultVerified {
    param([string]$ProjectPath,[string]$TaskId,[string]$NormalizedResultPath)
    $resolvedProject=[IO.Path]::GetFullPath($ProjectPath)
    $state=Join-Path $resolvedProject '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath=Join-Path $state 'workflow.json';$tasksPath=Join-Path $state 'tasks.json'
        $workflow=Read-StateJson $workflowPath;$tasks=@(Read-StateJson $tasksPath|ForEach-Object{$_});Add-Defaults $workflow $tasks
        $task=@($tasks|Where-Object{$_.task_id -eq $TaskId});if($task.Count -ne 1){throw "Task not found: $TaskId"};$task=$task[0]
        if($task.status -ne 'verifying' -or $task.delivery_status -ne 'result_received'){throw 'Task is not ready for result verification.'}
        if($task.verified){throw 'Task result was already verified.'}
        if(-not(Test-Path -LiteralPath $NormalizedResultPath)){throw 'Normalized result file not found.'}
        if(-not(Test-Path -LiteralPath $task.raw_result_path)){throw 'Raw result file not found.'}
        $rawHash=(Get-FileHash -LiteralPath $task.raw_result_path -Algorithm SHA256).Hash.ToLowerInvariant()
        if($rawHash -ne $task.raw_result_sha256){throw 'Raw result hash mismatch before verification.'}
        $resolvedNormalized=[IO.Path]::GetFullPath($NormalizedResultPath)
        $validator=Join-Path $PSScriptRoot 'validate-result.ps1'
        $powershellPath=(Get-Process -Id $PID).Path
        $validationArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$validator,'-ResultPath',$resolvedNormalized,'-ProjectPath',$resolvedProject,'-ExpectedTaskId',$task.task_id,'-ExpectedDispatchId',$task.dispatch_id,'-ExpectedThreadId',$task.thread_id,'-ExpectedRole',$task.role)
        if(@($task.allowed_files).Count -gt 0){$validationArguments+=@('-AllowedFiles',(@($task.allowed_files)-join ','))}
        $validationOutput=@(& $powershellPath @validationArguments 2>&1)
        if($LASTEXITCODE -ne 0){throw "Normalized result validation failed: $($validationOutput -join ' | ')"}
        $normalized=Read-StateJson $resolvedNormalized
        if($normalized.host_id -ne $task.host_id){throw 'Normalized result host does not match the assigned task.'}
        if($normalized.normalization.source_message_id -ne $task.result_message_id){throw 'Normalized result source message does not match the received result item.'}
        if($normalized.normalization.source_thread_id -ne $task.thread_id){throw 'Normalized result source thread does not match the assigned task.'}
        $normalizedHash=(Get-FileHash -LiteralPath $resolvedNormalized -Algorithm SHA256).Hash.ToLowerInvariant()
        $verifiedAt=Get-UtcTimestamp
        $receipt=[ordered]@{
            workflow_id=$workflow.workflow_id;task_id=$task.task_id;dispatch_id=$task.dispatch_id;thread_id=$task.thread_id
            result_message_id=$task.result_message_id;raw_result_path=$task.raw_result_path;raw_result_sha256=$rawHash
            normalized_result_path=$resolvedNormalized;normalized_result_sha256=$normalizedHash
            validator='validate-result.ps1';validation_output=@($validationOutput|ForEach-Object{[string]$_});verified_at=$verifiedAt
        }
        $receiptDirectory=Join-Path $state 'verifications';$receiptPath=Join-Path $receiptDirectory "$($task.dispatch_id).json"
        if(Test-Path -LiteralPath $receiptPath){throw 'Verification receipt already exists and will not be overwritten.'}
        Write-JsonAtomic $receipt $receiptPath
        $task.normalized_result_path=$resolvedNormalized;$task.normalized_result_sha256=$normalizedHash
        $task.verification_receipt_path=[IO.Path]::GetFullPath($receiptPath);$task.verification_receipt_sha256=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $task.verified=$true;$task.verification_status='trusted';$task.verified_at=$verifiedAt;$task.updated_at=Get-UtcTimestamp
        Write-Event $state $workflow 'result_verified' $TaskId 'result_received' 'verified' $task.verification_receipt_sha256
        $workflow.updated_at=Get-UtcTimestamp;Write-JsonAtomic $workflow $workflowPath;Write-JsonAtomic $tasks $tasksPath
        [pscustomobject]$receipt
    }
}

function Get-WorkflowReconciliation {
    param([string]$ProjectPath,[string]$TaskId)
    $state=Get-WorkflowState -ProjectPath $ProjectPath
    $task=@($state.tasks|Where-Object{$_.task_id -eq $TaskId}); if($task.Count -ne 1){throw "Task not found: $TaskId"}; $task=$task[0]; Add-Defaults $state.workflow @($state.tasks)
    $actions=@(Read-ExternalActions (Join-Path ([IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'))
    function Get-ExternalDecision([string]$Type,[string]$Begin,[string]$Record){$attempts=@($actions|Where-Object{$_.task_id -eq $task.task_id -and $_.action_type -eq $Type}|Sort-Object attempt);if(-not $attempts.Count -or $attempts[-1].status -eq 'cancelled'){$Begin}elseif($attempts[-1].status -eq 'prepared'){'inspect_external_action'}else{$Record}}
    $decision = if($task.callback_status -eq 'received'){Get-ExternalDecision 'callback_ack' 'begin_callback_ack' 'record_callback_ack'}else{switch ("$($task.status)|$($task.delivery_status)") {
        'approved|prepared' {Get-ExternalDecision 'dispatch_send' 'begin_dispatch_send' 'record_dispatch_send'}
        'dispatched|sent' {'wait_for_acknowledgement'}
        'running|acknowledged' {if($task.latest_turn_status -eq 'completed' -and $task.latest_item_phase -eq 'final_answer' -and -not [string]::IsNullOrWhiteSpace($task.latest_turn_id) -and -not [string]::IsNullOrWhiteSpace($task.latest_item_id)){'fetch_full_result'}else{'wait_for_result'}}
        'verifying|result_received' {if($task.verified){'complete_verified_task'}else{'validate_received_result'}}
        'completed|result_received' {'complete'}
        default {'manual_review'}
    }}
    [ordered]@{ task_id=$task.task_id; dispatch_id=$task.dispatch_id; thread_id=$task.thread_id; host_id=$task.host_id; status=$task.status; delivery_status=$task.delivery_status; callback_event_id=$task.callback_event_id; callback_status=$task.callback_status; read_cursor=$task.read_cursor; decision=$decision }
}

function Set-WorkflowTaskState {
    param([string]$ProjectPath,[string]$TaskId,[string]$ToStatus,[string]$Reason)
    $state = Join-Path ([System.IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath = Join-Path $state 'workflow.json'; $tasksPath = Join-Path $state 'tasks.json'
        $workflow = Read-StateJson $workflowPath; $tasks = @(Read-StateJson $tasksPath | ForEach-Object { $_ }); Add-Defaults $workflow $tasks
        $task = @($tasks | Where-Object { $_.task_id -eq $TaskId })
        if ($task.Count -ne 1) { throw "Task not found: $TaskId" }; $task = $task[0]; $from = [string]$task.status
        if (-not $script:Transitions.ContainsKey($from) -or $ToStatus -notin $script:Transitions[$from]) { throw "Illegal transition: $from -> $ToStatus" }
        if ($ToStatus -eq 'dispatched') {
            if ([int]$workflow.state_version -ge 3) { throw 'Use prepare-dispatch and record-sent for managed dispatches.' }
            foreach ($dependency in @($task.depends_on)) { $dep = @($tasks | Where-Object { $_.task_id -eq $dependency }); if ($dep.Count -ne 1 -or $dep[0].status -ne 'completed' -or -not $dep[0].verified) { throw "Dependency is not verified complete: $dependency" } }
            if ([int]$task.dispatch_count -gt 0) { throw 'Task was already dispatched.' }
            $task.dispatch_count = [int]$task.dispatch_count + 1
            $stageByRole = @{ analyst='analysis'; developer='implementation'; tester='test'; reviewer='review' }
            $workflow.current_stage = $stageByRole[[string]$task.role]; $workflow.status = 'running'
        }
        if ($ToStatus -eq 'completed') {
            if(-not $task.verified -or $task.verification_status -ne 'trusted' -or [string]::IsNullOrWhiteSpace($task.verification_receipt_path) -or [string]::IsNullOrWhiteSpace($task.verification_receipt_sha256)){throw 'Completion requires a trusted verification receipt.'}
            if($task.callback_status -ne 'acknowledged'){throw 'Completion requires an acknowledged worker callback.'}
            if(-not(Test-Path -LiteralPath $task.verification_receipt_path) -or (Get-FileHash -LiteralPath $task.verification_receipt_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $task.verification_receipt_sha256){throw 'Verification receipt is missing or changed.'}
            if(-not(Test-Path -LiteralPath $task.normalized_result_path) -or (Get-FileHash -LiteralPath $task.normalized_result_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $task.normalized_result_sha256){throw 'Normalized result is missing or changed.'}
        }
        $task.status = $ToStatus; $task.updated_at = Get-UtcTimestamp
        Write-Event $state $workflow 'task_transitioned' $TaskId $from $ToStatus $Reason
        $workflow.updated_at = Get-UtcTimestamp; Write-JsonAtomic $workflow $workflowPath; Write-JsonAtomic $tasks $tasksPath
    }
}

function Test-WorkflowStateIntegrity {
    param([string]$ProjectPath)
    $state = Join-Path ([System.IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    $workflow = Read-StateJson (Join-Path $state 'workflow.json')
    $tasks = @(Read-StateJson (Join-Path $state 'tasks.json') | ForEach-Object { $_ })
    Add-Defaults $workflow $tasks
    if([string]::IsNullOrWhiteSpace([string]$workflow.controller_thread_id)){
        if([int64]$workflow.controller_epoch -ne 0 -or @($workflow.controller_history).Count -ne 0){throw 'Unconfigured controller must have epoch 0 and empty history.'}
    }else{
        if([string]::IsNullOrWhiteSpace([string]$workflow.controller_host_id) -or [int64]$workflow.controller_epoch -lt 1){throw 'Configured controller identity or epoch is invalid.'}
        if(@($workflow.controller_history).Count -ne ([int64]$workflow.controller_epoch-1)){throw 'Controller history does not match the current epoch.'}
        for($historyIndex=0;$historyIndex -lt @($workflow.controller_history).Count;$historyIndex++){if([int64]$workflow.controller_history[$historyIndex].epoch -ne ($historyIndex+1)){throw 'Controller history epoch sequence is invalid.'}}
    }
    $eventPath = Join-Path $state 'events.jsonl'
    if (-not (Test-Path -LiteralPath $eventPath)) { throw 'Event log not found.' }
    $events = @(Get-Content -LiteralPath $eventPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    for ($index=0; $index -lt $events.Count; $index++) {
        if ([int]$events[$index].sequence -ne ($index + 1)) { throw "Event sequence gap at index: $index" }
        if ($events[$index].workflow_id -ne $workflow.workflow_id) { throw "Event workflow mismatch at sequence: $($events[$index].sequence)" }
    }
    if ([int]$workflow.event_sequence -ne $events.Count) { throw 'Workflow event_sequence differs from event log.' }
    if (@($tasks | Group-Object task_id | Where-Object Count -gt 1).Count -gt 0) { throw 'Duplicate task_id detected.' }
    if (@($tasks | Group-Object thread_id | Where-Object Count -gt 1).Count -gt 0) { throw 'Duplicate thread_id detected.' }
    $externalActions=@(Read-ExternalActions $state)
    if(@($externalActions|Group-Object action_id|Where-Object Count -gt 1).Count -gt 0){throw 'Duplicate external action ID detected.'}
    foreach($externalAction in $externalActions){
        if($externalAction.status -notin @('prepared','completed','cancelled')){throw "Invalid external action status: $($externalAction.action_id)"}
        if((Get-ObjectSha256 $externalAction.payload) -ne $externalAction.payload_sha256){throw "External action payload hash mismatch: $($externalAction.action_id)"}
        if([int64]$externalAction.controller_epoch -gt [int64]$workflow.controller_epoch){throw "External action controller epoch is invalid: $($externalAction.action_id)"}
        $lease=$(if([int64]$externalAction.controller_epoch -eq [int64]$workflow.controller_epoch){$workflow}else{@($workflow.controller_history|Where-Object{[int64]$_.epoch -eq [int64]$externalAction.controller_epoch})[0]})
        $leaseThread=$(if($lease.PSObject.Properties.Match('controller_thread_id').Count){$lease.controller_thread_id}else{$lease.thread_id});$leaseHost=$(if($lease.PSObject.Properties.Match('controller_host_id').Count){$lease.controller_host_id}else{$lease.host_id})
        if($leaseThread -ne $externalAction.controller_thread_id -or $leaseHost -ne $externalAction.controller_host_id){throw "External action controller identity mismatch: $($externalAction.action_id)"}
        if($externalAction.status -eq 'completed' -and ([string]::IsNullOrWhiteSpace($externalAction.receipt_path) -or -not(Test-Path -LiteralPath $externalAction.receipt_path) -or (Get-FileHash -LiteralPath $externalAction.receipt_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $externalAction.receipt_sha256)){throw "External action receipt mismatch: $($externalAction.action_id)"}
        if(-not [string]::IsNullOrWhiteSpace($externalAction.resolution_evidence_path) -and (-not(Test-Path -LiteralPath $externalAction.resolution_evidence_path) -or (Get-FileHash -LiteralPath $externalAction.resolution_evidence_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $externalAction.resolution_evidence_sha256)){throw "External action resolution evidence mismatch: $($externalAction.action_id)"}
        if($externalAction.status -eq 'cancelled' -and ([string]::IsNullOrWhiteSpace($externalAction.resolution_evidence_path) -or -not(Test-Path -LiteralPath $externalAction.resolution_evidence_path) -or (Get-FileHash -LiteralPath $externalAction.resolution_evidence_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $externalAction.resolution_evidence_sha256)){throw "External action resolution evidence mismatch: $($externalAction.action_id)"}
        $started=@($events|Where-Object{$_.type -eq 'external_action_started' -and $_.reason -eq $externalAction.action_id}).Count;$completed=@($events|Where-Object{$_.type -eq 'external_action_completed' -and $_.reason -eq $externalAction.action_id}).Count;$cancelled=@($events|Where-Object{$_.type -eq 'external_action_cancelled' -and $_.reason -eq $externalAction.action_id}).Count
        if($started -ne 1 -or ($externalAction.status -eq 'prepared' -and ($completed -ne 0 -or $cancelled -ne 0)) -or ($externalAction.status -eq 'completed' -and ($completed -ne 1 -or $cancelled -ne 0)) -or ($externalAction.status -eq 'cancelled' -and ($completed -ne 0 -or $cancelled -ne 1))){throw "External action event history mismatch: $($externalAction.action_id)"}
    }
    foreach($group in @($externalActions|Group-Object task_id,action_type)){ $ordered=@($group.Group|Sort-Object attempt);for($attemptIndex=0;$attemptIndex -lt $ordered.Count;$attemptIndex++){if([int]$ordered[$attemptIndex].attempt -ne ($attemptIndex+1)){throw "External action attempt sequence is invalid: $($group.Name)"}} }
    $actionExecutions=@(Read-ActionExecutions $state)
    if(@($actionExecutions|Group-Object execution_id|Where-Object Count -gt 1).Count -or @($actionExecutions|Group-Object action_id|Where-Object Count -gt 1).Count){throw 'Duplicate action execution checkpoint detected.'}
    foreach($execution in $actionExecutions){
        if($execution.status -notin @('claimed','completed','failed','abandoned','reconciled','retry_authorized')){throw "Invalid action execution status: $($execution.execution_id)"}
        if([string]::IsNullOrWhiteSpace($execution.operation_sha256) -or [string]::IsNullOrWhiteSpace($execution.plan_path) -or -not(Test-Path -LiteralPath $execution.plan_path) -or (Get-FileHash $execution.plan_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $execution.plan_sha256){throw "Action execution plan evidence mismatch: $($execution.execution_id)"}
        $plan=Read-StateJson $execution.plan_path;$planAction=@($plan.actions|Where-Object{$_.action_id -eq $execution.action_id});if($planAction.Count -ne 1 -or (Get-ObjectSha256 $planAction[0]) -ne $execution.action_sha256 -or $planAction[0].operation_sha256 -ne $execution.operation_sha256){throw "Action execution snapshot mismatch: $($execution.execution_id)"}
        if([int64]$execution.controller_epoch -gt [int64]$workflow.controller_epoch){throw "Action execution controller epoch is invalid: $($execution.execution_id)"}
        $executionLease=$(if([int64]$execution.controller_epoch -eq [int64]$workflow.controller_epoch){$workflow}else{@($workflow.controller_history|Where-Object{[int64]$_.epoch -eq [int64]$execution.controller_epoch})[0]});$executionThread=$(if($executionLease.PSObject.Properties.Match('controller_thread_id').Count){$executionLease.controller_thread_id}else{$executionLease.thread_id});$executionHost=$(if($executionLease.PSObject.Properties.Match('controller_host_id').Count){$executionLease.controller_host_id}else{$executionLease.host_id})
        if($executionThread -ne $execution.controller_thread_id -or $executionHost -ne $execution.controller_host_id){throw "Action execution controller identity mismatch: $($execution.execution_id)"}
        if($execution.status -ne 'claimed' -and ([string]::IsNullOrWhiteSpace($execution.evidence_path) -or -not(Test-Path -LiteralPath $execution.evidence_path) -or (Get-FileHash $execution.evidence_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $execution.evidence_sha256)){throw "Action execution evidence mismatch: $($execution.execution_id)"}
        if($execution.status -eq 'retry_authorized' -and ([string]::IsNullOrWhiteSpace($execution.retry_evidence_path) -or -not(Test-Path -LiteralPath $execution.retry_evidence_path) -or (Get-FileHash $execution.retry_evidence_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $execution.retry_evidence_sha256)){throw "Action retry evidence mismatch: $($execution.execution_id)"}
        $claimed=@($events|Where-Object{$_.type -eq 'action_claimed' -and $_.reason -eq $execution.execution_id}).Count;$completed=@($events|Where-Object{$_.type -eq 'action_completed' -and $_.reason -eq $execution.execution_id}).Count;$failed=@($events|Where-Object{$_.type -eq 'action_failed' -and $_.reason -eq $execution.execution_id}).Count;$abandoned=@($events|Where-Object{$_.type -eq 'action_abandoned' -and $_.reason -eq $execution.execution_id}).Count;$reconciled=@($events|Where-Object{$_.type -eq 'action_reconciled' -and $_.reason -eq $execution.execution_id}).Count;$retry=@($events|Where-Object{$_.type -eq 'action_retry_authorized' -and $_.reason -eq $execution.execution_id}).Count
        $validHistory=($claimed -eq 1 -and (($execution.status -eq 'claimed' -and ($completed+$failed+$abandoned+$reconciled+$retry) -eq 0) -or ($execution.status -eq 'completed' -and $completed -eq 1 -and ($failed+$abandoned+$reconciled+$retry) -eq 0) -or ($execution.status -eq 'failed' -and $failed -eq 1 -and ($completed+$abandoned+$reconciled+$retry) -eq 0) -or ($execution.status -eq 'abandoned' -and $abandoned -eq 1 -and ($completed+$failed+$reconciled+$retry) -eq 0) -or ($execution.status -eq 'reconciled' -and $reconciled -eq 1 -and ($completed+$failed+$abandoned+$retry) -eq 0) -or ($execution.status -eq 'retry_authorized' -and $failed -eq 1 -and $retry -eq 1 -and ($completed+$abandoned+$reconciled) -eq 0)))
        if(-not $validHistory){throw "Action execution event history mismatch: $($execution.execution_id)"}
    }
    foreach($group in @($actionExecutions|Group-Object operation_sha256)){ $ordered=@($group.Group|Sort-Object attempt);for($index=0;$index -lt $ordered.Count;$index++){if([int]$ordered[$index].attempt -ne ($index+1)){throw "Action execution attempt sequence is invalid: $($group.Name)"}} }
    foreach ($task in $tasks) {
        if ($task.delivery_status -ne 'not-prepared' -and ([string]::IsNullOrWhiteSpace($task.dispatch_id) -or [string]::IsNullOrWhiteSpace($task.dispatch_path) -or -not (Test-Path -LiteralPath $task.dispatch_path))) { throw "Task dispatch evidence is incomplete: $($task.task_id)" }
        if ($task.delivery_status -in @('sent','acknowledged','result_received') -and ([string]::IsNullOrWhiteSpace($task.send_receipt_path) -or [string]::IsNullOrWhiteSpace($task.send_receipt_sha256) -or -not(Test-Path -LiteralPath $task.send_receipt_path) -or [string]::IsNullOrWhiteSpace($task.dispatched_at))) { throw "Task send evidence is incomplete: $($task.task_id)" }
        if(-not [string]::IsNullOrWhiteSpace($task.send_receipt_path) -and ((Get-FileHash -LiteralPath $task.send_receipt_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $task.send_receipt_sha256)){throw "Task send receipt hash mismatch: $($task.task_id)"}
        if(-not [string]::IsNullOrWhiteSpace($task.observation_path) -and ((Get-FileHash -LiteralPath $task.observation_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $task.observation_sha256)){throw "Task observation hash mismatch: $($task.task_id)"}
        if(-not [string]::IsNullOrWhiteSpace($task.wait_snapshot_path)){
            if((Get-FileHash -LiteralPath $task.wait_snapshot_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $task.wait_snapshot_sha256){throw "Task wait snapshot hash mismatch: $($task.task_id)"}
            $snapshot=Read-StateJson $task.wait_snapshot_path
            if($snapshot.thread_id -ne $task.thread_id -or $snapshot.host_id -ne $task.host_id -or [int64]$snapshot.revision -ne [int64]$task.wait_revision){throw "Task wait snapshot identity mismatch: $($task.task_id)"}
            if(-not(Test-Path -LiteralPath $snapshot.raw_response_path) -or (Get-FileHash -LiteralPath $snapshot.raw_response_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $snapshot.raw_response_sha256){throw "Task wait raw response hash mismatch: $($task.task_id)"}
        }
        if ($task.delivery_status -in @('acknowledged','result_received') -and [string]::IsNullOrWhiteSpace($task.acknowledged_at)) { throw "Task acknowledgement evidence is incomplete: $($task.task_id)" }
        if ($task.delivery_status -eq 'result_received' -and ([string]::IsNullOrWhiteSpace($task.result_message_id) -or [string]::IsNullOrWhiteSpace($task.result_received_at) -or -not (Test-Path -LiteralPath $task.raw_result_path))) { throw "Task result evidence is incomplete: $($task.task_id)" }
        if(-not [string]::IsNullOrWhiteSpace($task.raw_result_path) -and ((Get-FileHash -LiteralPath $task.raw_result_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $task.raw_result_sha256)){throw "Task raw result hash mismatch: $($task.task_id)"}
        if($task.callback_status -ne 'not-prepared'){
            if([string]::IsNullOrWhiteSpace($task.callback_target_thread_id) -or [string]::IsNullOrWhiteSpace($task.callback_target_host_id) -or $null -eq $task.dispatch_controller_epoch -or [string]::IsNullOrWhiteSpace($task.callback_event_id)){throw "Task callback identity is incomplete: $($task.task_id)"}
        }
        if($task.callback_status -in @('received','acknowledged')){
            if([string]::IsNullOrWhiteSpace($task.callback_received_at) -or -not(Test-Path -LiteralPath $task.callback_receipt_path) -or (Get-FileHash -LiteralPath $task.callback_receipt_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $task.callback_receipt_sha256){throw "Task callback receipt mismatch: $($task.task_id)"}
        }
        if($task.callback_status -eq 'acknowledged'){
            if([string]::IsNullOrWhiteSpace($task.callback_acknowledged_at) -or -not(Test-Path -LiteralPath $task.callback_ack_receipt_path) -or (Get-FileHash -LiteralPath $task.callback_ack_receipt_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $task.callback_ack_receipt_sha256){throw "Task callback acknowledgement mismatch: $($task.task_id)"}
        }
        if($task.verified -and $task.verification_status -ne 'trusted'){throw "Task trusted verification status is inconsistent: $($task.task_id)"}
        if($task.verified){
            if([string]::IsNullOrWhiteSpace($task.verified_at) -or -not(Test-Path -LiteralPath $task.normalized_result_path) -or (Get-FileHash -LiteralPath $task.normalized_result_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $task.normalized_result_sha256){throw "Task normalized result evidence is incomplete: $($task.task_id)"}
            if(-not(Test-Path -LiteralPath $task.verification_receipt_path) -or (Get-FileHash -LiteralPath $task.verification_receipt_path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $task.verification_receipt_sha256){throw "Task verification receipt mismatch: $($task.task_id)"}
            $receipt=Read-StateJson $task.verification_receipt_path
            if($receipt.task_id -ne $task.task_id -or $receipt.dispatch_id -ne $task.dispatch_id -or $receipt.thread_id -ne $task.thread_id -or $receipt.result_message_id -ne $task.result_message_id -or $receipt.raw_result_sha256 -ne $task.raw_result_sha256 -or $receipt.normalized_result_sha256 -ne $task.normalized_result_sha256){throw "Task verification receipt identity mismatch: $($task.task_id)"}
        }
    }
    $leftovers = @(Get-ChildItem -LiteralPath $state -File | Where-Object { $_.Name -match '\.(tmp|bak)\.' })
    if ($leftovers.Count -gt 0) { throw 'Interrupted atomic-write artifact detected.' }
    return $true
}

function Get-WorkflowState {
    param([string]$ProjectPath)
    $state = Join-Path ([System.IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    $workflow=Read-StateJson (Join-Path $state 'workflow.json');$tasks=@(Read-StateJson (Join-Path $state 'tasks.json')|ForEach-Object{$_});Add-Defaults $workflow $tasks
    [ordered]@{workflow=$workflow;tasks=$tasks;external_actions=@(Read-ExternalActions $state);action_executions=@(Read-ActionExecutions $state)}
}

Export-ModuleMember -Function Initialize-WorkflowState,Set-WorkflowController,Set-WorkflowControllerTakeover,Register-WorkflowTask,Set-WorkflowTaskState,New-WorkflowDispatch,Start-WorkflowExternalAction,Complete-WorkflowExternalAction,Cancel-WorkflowExternalAction,Claim-WorkflowAction,Renew-WorkflowActionLease,Set-WorkflowActionExecutionResult,Resolve-WorkflowActionExecution,Authorize-WorkflowActionRetry,Confirm-WorkflowDispatchSent,Confirm-WorkflowAcknowledged,Receive-WorkflowCallback,Confirm-WorkflowCallbackAcknowledged,Receive-WorkflowResult,Confirm-WorkflowResultVerified,Record-WorkflowThreadObservation,Record-WorkflowWaitSnapshot,Get-WorkflowReconciliation,Get-WorkflowState,Test-WorkflowStateIntegrity
