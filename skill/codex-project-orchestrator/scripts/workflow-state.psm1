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
    if ($Workflow.PSObject.Properties.Match('event_sequence').Count -eq 0) { Add-Member -InputObject $Workflow -NotePropertyName event_sequence -NotePropertyValue 0 }
    if ($Workflow.PSObject.Properties.Match('current_stage').Count -eq 0) { Add-Member -InputObject $Workflow -NotePropertyName current_stage -NotePropertyValue 'analysis' }
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
        foreach ($name in @('wait_snapshot_path','wait_snapshot_sha256','latest_turn_id','latest_item_id','raw_result_sha256')) {
            if ($task.PSObject.Properties.Match($name).Count -eq 0) { Add-Member -InputObject $task -NotePropertyName $name -NotePropertyValue $null }
        }
        if($task.PSObject.Properties.Match('wait_revision').Count -eq 0){Add-Member -InputObject $task -NotePropertyName wait_revision -NotePropertyValue $null}
        if($task.PSObject.Properties.Match('result_truncated').Count -eq 0){Add-Member -InputObject $task -NotePropertyName result_truncated -NotePropertyValue $false}
    }
    if ([int]$Workflow.state_version -lt 5) { $Workflow.state_version = 5 }
}

function Write-Event {
    param([string]$StateDirectory,$Workflow,[string]$Type,[string]$TaskId,[string]$From,[string]$To,[string]$Reason)
    $Workflow.event_sequence = [int]$Workflow.event_sequence + 1
    $event = [ordered]@{ sequence=$Workflow.event_sequence; workflow_id=$Workflow.workflow_id; type=$Type; task_id=$TaskId; from_status=$From; to_status=$To; reason=$Reason; created_at=(Get-UtcTimestamp) }
    $line = ($event | ConvertTo-Json -Compress)
    [System.IO.File]::AppendAllText((Join-Path $StateDirectory 'events.jsonl'),$line + [Environment]::NewLine,[System.Text.UTF8Encoding]::new($false))
}

function Initialize-WorkflowState {
    param([string]$ProjectPath,[string]$WorkflowId)
    $resolved = [System.IO.Path]::GetFullPath($ProjectPath)
    $state = Join-Path $resolved '.codex-orchestrator'
    Invoke-WithStateLock $state {
        $workflowPath = Join-Path $state 'workflow.json'
        if (Test-Path -LiteralPath $workflowPath) { throw 'Workflow already exists.' }
        $now = Get-UtcTimestamp
        $workflow = [ordered]@{ workflow_id=$WorkflowId; project_path=$resolved; state_version=5; status='draft'; current_stage='analysis'; authorization='read-only'; event_sequence=0; created_at=$now; updated_at=$now }
        $tasks = @()
        Write-Event $state $workflow 'workflow_initialized' $null $null 'draft' 'initialization'
        Write-JsonAtomic $workflow $workflowPath
        Write-JsonAtomic $tasks (Join-Path $state 'tasks.json')
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
        $task = [ordered]@{ task_id=$TaskId; thread_id=$ThreadId; host_id=$HostId; role=$Role; status='draft'; depends_on=@($DependsOn); project_path=$workflow.project_path; base_revision=$BaseRevision; allowed_files=@($AllowedFiles); objective=$Objective; authorization=$Authorization; repair_count=0; dispatch_count=0; dispatch_id=$null; delivery_status='not-prepared'; dispatch_path=$null; sent_message_id=$null; send_receipt_path=$null; send_receipt_sha256=$null; result_message_id=$null; read_cursor=$null; wait_revision=$null; wait_snapshot_path=$null; wait_snapshot_sha256=$null; latest_turn_id=$null; latest_item_id=$null; result_truncated=$false; observation_path=$null; observation_sha256=$null; observed_status=$null; observed_at=$null; dispatched_at=$null; acknowledged_at=$null; result_received_at=$null; raw_result_path=$null; raw_result_sha256=$null; normalized_result_path=$null; verified=$false; updated_at=(Get-UtcTimestamp) }
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
        if ($task.delivery_status -ne 'not-prepared' -or [int]$task.dispatch_count -gt 0) { throw 'Task dispatch was already prepared or sent.' }
        foreach ($dependency in @($task.depends_on)) {
            $dep = @($tasks | Where-Object { $_.task_id -eq $dependency })
            if ($dep.Count -ne 1 -or $dep[0].status -ne 'completed' -or -not $dep[0].verified) { throw "Dependency is not verified complete: $dependency" }
        }
        $dispatchId = "$TaskId-$([guid]::NewGuid().ToString('N'))"
        $dispatch = [ordered]@{ dispatch_id=$dispatchId; workflow_id=$workflow.workflow_id; task_id=$task.task_id; thread_id=$task.thread_id; host_id=$task.host_id; role=$task.role; project_path=$task.project_path; base_revision=$task.base_revision; objective=$task.objective; depends_on=@($task.depends_on); allowed_files=@($task.allowed_files); authorization=$task.authorization; created_at=(Get-UtcTimestamp) }
        $dispatchDirectory = Join-Path $state 'dispatches'; $dispatchPath = Join-Path $dispatchDirectory "$dispatchId.json"
        Write-JsonAtomic $dispatch $dispatchPath
        $task.dispatch_id = $dispatchId; $task.dispatch_path = [System.IO.Path]::GetFullPath($dispatchPath); $task.delivery_status = 'prepared'; $task.updated_at = Get-UtcTimestamp
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
        $task.wait_revision=[int64]$snapshot.revision;$task.read_cursor=$snapshot.cursor;$task.latest_turn_id=$snapshot.latest_turn_id;$task.latest_item_id=$snapshot.latest_item_id;$task.result_truncated=[bool]$snapshot.result_truncated;$task.observed_status=$snapshot.status;$task.observed_at=Get-UtcTimestamp;$task.updated_at=Get-UtcTimestamp
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

function Get-WorkflowReconciliation {
    param([string]$ProjectPath,[string]$TaskId)
    $state=Get-WorkflowState -ProjectPath $ProjectPath
    $task=@($state.tasks|Where-Object{$_.task_id -eq $TaskId}); if($task.Count -ne 1){throw "Task not found: $TaskId"}; $task=$task[0]; Add-Defaults $state.workflow @($state.tasks)
    $decision = switch ("$($task.status)|$($task.delivery_status)") {
        'approved|prepared' {'send_prepared_dispatch'}
        'dispatched|sent' {'wait_for_acknowledgement'}
        'running|acknowledged' {if(-not [string]::IsNullOrWhiteSpace($task.latest_turn_id) -and -not [string]::IsNullOrWhiteSpace($task.latest_item_id)){'fetch_full_result'}else{'wait_for_result'}}
        'verifying|result_received' {'validate_received_result'}
        'completed|result_received' {'complete'}
        default {'manual_review'}
    }
    [ordered]@{ task_id=$task.task_id; dispatch_id=$task.dispatch_id; thread_id=$task.thread_id; host_id=$task.host_id; status=$task.status; delivery_status=$task.delivery_status; read_cursor=$task.read_cursor; decision=$decision }
}

function Set-WorkflowTaskState {
    param([string]$ProjectPath,[string]$TaskId,[string]$ToStatus,[string]$Reason,[string]$RawResultPath,[string]$NormalizedResultPath,[switch]$Verified)
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
            if (-not $Verified -or [string]::IsNullOrWhiteSpace($RawResultPath) -or [string]::IsNullOrWhiteSpace($NormalizedResultPath)) { throw 'Completion requires verified raw and normalized results.' }
            if (-not (Test-Path -LiteralPath $RawResultPath) -or -not (Test-Path -LiteralPath $NormalizedResultPath)) { throw 'Result evidence file not found.' }
            $normalized = Read-StateJson $NormalizedResultPath
            if ($normalized.task_id -ne $task.task_id -or $normalized.thread_id -ne $task.thread_id -or $normalized.dispatch_id -ne $task.dispatch_id) { throw 'Normalized result identity does not match task, thread, and dispatch.' }
            $task.raw_result_path = [System.IO.Path]::GetFullPath($RawResultPath); $task.normalized_result_path = [System.IO.Path]::GetFullPath($NormalizedResultPath); $task.verified = $true
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
    }
    $leftovers = @(Get-ChildItem -LiteralPath $state -File | Where-Object { $_.Name -match '\.(tmp|bak)\.' })
    if ($leftovers.Count -gt 0) { throw 'Interrupted atomic-write artifact detected.' }
    return $true
}

function Get-WorkflowState {
    param([string]$ProjectPath)
    $state = Join-Path ([System.IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    [ordered]@{ workflow=(Read-StateJson (Join-Path $state 'workflow.json')); tasks=@(Read-StateJson (Join-Path $state 'tasks.json') | ForEach-Object { $_ }) }
}

Export-ModuleMember -Function Initialize-WorkflowState,Register-WorkflowTask,Set-WorkflowTaskState,New-WorkflowDispatch,Confirm-WorkflowDispatchSent,Confirm-WorkflowAcknowledged,Receive-WorkflowResult,Record-WorkflowThreadObservation,Record-WorkflowWaitSnapshot,Get-WorkflowReconciliation,Get-WorkflowState,Test-WorkflowStateIntegrity
