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

function Add-Defaults {
    param($Workflow,[object[]]$Tasks)
    if ($Workflow.PSObject.Properties.Match('state_version').Count -eq 0) { Add-Member -InputObject $Workflow -NotePropertyName state_version -NotePropertyValue 2 }
    $sourceStateVersion=[int]$Workflow.state_version
    if ($Workflow.PSObject.Properties.Match('event_sequence').Count -eq 0) { Add-Member -InputObject $Workflow -NotePropertyName event_sequence -NotePropertyValue 0 }
    if ($Workflow.PSObject.Properties.Match('current_stage').Count -eq 0) { Add-Member -InputObject $Workflow -NotePropertyName current_stage -NotePropertyValue 'analysis' }
    foreach ($name in @('controller_thread_id','controller_host_id')) {
        if ($Workflow.PSObject.Properties.Match($name).Count -eq 0) { Add-Member -InputObject $Workflow -NotePropertyName $name -NotePropertyValue $null }
    }
    foreach ($task in $Tasks) {
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
        if($task.PSObject.Properties.Match('callback_status').Count -eq 0){Add-Member -InputObject $task -NotePropertyName callback_status -NotePropertyValue 'not-prepared'}
        if($task.PSObject.Properties.Match('wait_revision').Count -eq 0){Add-Member -InputObject $task -NotePropertyName wait_revision -NotePropertyValue $null}
        if($task.PSObject.Properties.Match('result_truncated').Count -eq 0){Add-Member -InputObject $task -NotePropertyName result_truncated -NotePropertyValue $false}
        if($task.PSObject.Properties.Match('verification_status').Count -eq 0){
            $verificationStatus=$(if($sourceStateVersion -lt 6 -and $task.status -eq 'completed' -and $task.verified){$task.verified=$false;'legacy-unverified'}elseif($task.verified -and -not [string]::IsNullOrWhiteSpace($task.verification_receipt_path)){'trusted'}else{'unverified'})
            Add-Member -InputObject $task -NotePropertyName verification_status -NotePropertyValue $verificationStatus
        }
    }
    if ([int]$Workflow.state_version -lt 8) { $Workflow.state_version = 8 }
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
        $workflow = [ordered]@{ workflow_id=$WorkflowId; project_path=$resolved; state_version=8; controller_thread_id=$(if([string]::IsNullOrWhiteSpace($ControllerThreadId)){$null}else{$ControllerThreadId}); controller_host_id=$(if([string]::IsNullOrWhiteSpace($ControllerThreadId)){$null}else{$ControllerHostId}); status='draft'; current_stage='analysis'; authorization='read-only'; event_sequence=0; created_at=$now; updated_at=$now }
        $tasks = @()
        Write-Event $state $workflow 'workflow_initialized' $null $null 'draft' 'initialization'
        Write-JsonAtomic $workflow $workflowPath
        Write-JsonAtomic $tasks (Join-Path $state 'tasks.json')
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
        $workflow.controller_thread_id=$ControllerThreadId;$workflow.controller_host_id=$ControllerHostId
        Write-Event $state $workflow 'controller_configured' $null $null 'configured' $ControllerThreadId
        $workflow.updated_at=Get-UtcTimestamp;Write-JsonAtomic $workflow $workflowPath;Write-JsonAtomic $tasks $tasksPath
    }
}

function Register-WorkflowTask {
    param([string]$ProjectPath,[string]$TaskId,[string]$ThreadId,[string]$HostId,[string]$Role,[string]$Objective,[string]$Authorization,[string]$BaseRevision,[string[]]$DependsOn,[string[]]$AllowedFiles)
    $state = Join-Path ([System.IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath = Join-Path $state 'workflow.json'; $tasksPath = Join-Path $state 'tasks.json'
        $workflow = Read-StateJson $workflowPath; $tasks = @(Read-StateJson $tasksPath | ForEach-Object { $_ }); Add-Defaults $workflow $tasks
        if (@($tasks | Where-Object { $_.task_id -eq $TaskId }).Count -gt 0) { throw "Duplicate task_id: $TaskId" }
        if (@($tasks | Where-Object { $_.thread_id -eq $ThreadId }).Count -gt 0) { throw "Duplicate thread_id: $ThreadId" }
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
        $task = [ordered]@{ task_id=$TaskId; thread_id=$ThreadId; host_id=$HostId; role=$Role; status='draft'; depends_on=@($DependsOn); project_path=$workflow.project_path; base_revision=$BaseRevision; allowed_files=@($AllowedFiles); objective=$Objective; authorization=$Authorization; repair_count=0; dispatch_count=0; dispatch_id=$null; delivery_status='not-prepared'; dispatch_path=$null; sent_message_id=$null; send_receipt_path=$null; send_receipt_sha256=$null; result_message_id=$null; read_cursor=$null; wait_revision=$null; wait_snapshot_path=$null; wait_snapshot_sha256=$null; latest_turn_id=$null; latest_turn_status=$null; latest_item_id=$null; latest_item_phase=$null; result_truncated=$false; callback_event_id=$null; callback_status='not-prepared'; callback_receipt_path=$null; callback_receipt_sha256=$null; callback_received_at=$null; callback_ack_receipt_path=$null; callback_ack_receipt_sha256=$null; callback_acknowledged_at=$null; observation_path=$null; observation_sha256=$null; observed_status=$null; observed_at=$null; dispatched_at=$null; acknowledged_at=$null; result_received_at=$null; raw_result_path=$null; raw_result_sha256=$null; normalized_result_path=$null; normalized_result_sha256=$null; verification_receipt_path=$null; verification_receipt_sha256=$null; verification_status='unverified'; verified_at=$null; verified=$false; updated_at=(Get-UtcTimestamp) }
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
        foreach ($dependency in @($task.depends_on)) {
            $dep = @($tasks | Where-Object { $_.task_id -eq $dependency })
            if ($dep.Count -ne 1 -or $dep[0].status -ne 'completed' -or -not $dep[0].verified) { throw "Dependency is not verified complete: $dependency" }
        }
        $dispatchId = "$TaskId-$([guid]::NewGuid().ToString('N'))"
        $callbackEventId="$dispatchId`:completion"
        $callback=[ordered]@{event_id=$callbackEventId;target_thread_id=$workflow.controller_thread_id;target_host_id=$workflow.controller_host_id;status='completed'}
        $dispatch = [ordered]@{ dispatch_id=$dispatchId; workflow_id=$workflow.workflow_id; task_id=$task.task_id; thread_id=$task.thread_id; host_id=$task.host_id; role=$task.role; project_path=$task.project_path; base_revision=$task.base_revision; objective=$task.objective; depends_on=@($task.depends_on); allowed_files=@($task.allowed_files); authorization=$task.authorization; callback=$callback; created_at=(Get-UtcTimestamp) }
        $dispatchDirectory = Join-Path $state 'dispatches'; $dispatchPath = Join-Path $dispatchDirectory "$dispatchId.json"
        Write-JsonAtomic $dispatch $dispatchPath
        $task.dispatch_id = $dispatchId; $task.dispatch_path = [System.IO.Path]::GetFullPath($dispatchPath); $task.delivery_status = 'prepared'; $task.callback_event_id=$callbackEventId;$task.callback_status='prepared';$task.updated_at = Get-UtcTimestamp
        Write-Event $state $workflow 'dispatch_prepared' $TaskId 'not-prepared' 'prepared' $dispatchId
        $workflow.updated_at = Get-UtcTimestamp; Write-JsonAtomic $workflow $workflowPath; Write-JsonAtomic $tasks $tasksPath
        [pscustomobject]$dispatch
    }
}

function Confirm-WorkflowDispatchSent {
    param([string]$ProjectPath,[string]$TaskId,[string]$DispatchId,[string]$ReceiptPath,[string]$MessageId,[string]$Cursor)
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
            source_thread_id=$task.thread_id;source_host_id=$task.host_id;target_thread_id=$workflow.controller_thread_id;target_host_id=$workflow.controller_host_id;status='completed'
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
    param([string]$ProjectPath,[string]$TaskId,[string]$CallbackEventId,[string]$ReceiptPath)
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
        $task.callback_ack_receipt_path=$resolved;$task.callback_ack_receipt_sha256=(Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
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
        $validationOutput=@(& $powershellPath -NoProfile -ExecutionPolicy Bypass -File $validator -ResultPath $resolvedNormalized -ProjectPath $resolvedProject -ExpectedTaskId $task.task_id -ExpectedDispatchId $task.dispatch_id -ExpectedThreadId $task.thread_id 2>&1)
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
    $decision = if($task.callback_status -eq 'received'){'send_callback_ack'}else{switch ("$($task.status)|$($task.delivery_status)") {
        'approved|prepared' {'send_prepared_dispatch'}
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
            if([string]::IsNullOrWhiteSpace($workflow.controller_thread_id) -or [string]::IsNullOrWhiteSpace($workflow.controller_host_id) -or [string]::IsNullOrWhiteSpace($task.callback_event_id)){throw "Task callback identity is incomplete: $($task.task_id)"}
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
    [ordered]@{workflow=$workflow;tasks=$tasks}
}

Export-ModuleMember -Function Initialize-WorkflowState,Set-WorkflowController,Register-WorkflowTask,Set-WorkflowTaskState,New-WorkflowDispatch,Confirm-WorkflowDispatchSent,Confirm-WorkflowAcknowledged,Receive-WorkflowCallback,Confirm-WorkflowCallbackAcknowledged,Receive-WorkflowResult,Confirm-WorkflowResultVerified,Record-WorkflowThreadObservation,Record-WorkflowWaitSnapshot,Get-WorkflowReconciliation,Get-WorkflowState,Test-WorkflowStateIntegrity
