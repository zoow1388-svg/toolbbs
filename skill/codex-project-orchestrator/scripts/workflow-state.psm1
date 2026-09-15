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
    }
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
        $workflow = [ordered]@{ workflow_id=$WorkflowId; project_path=$resolved; state_version=2; status='draft'; current_stage='analysis'; authorization='read-only'; event_sequence=0; created_at=$now; updated_at=$now }
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
        $task = [ordered]@{ task_id=$TaskId; thread_id=$ThreadId; host_id=$HostId; role=$Role; status='draft'; depends_on=@($DependsOn); project_path=$workflow.project_path; base_revision=$BaseRevision; allowed_files=@($AllowedFiles); objective=$Objective; authorization=$Authorization; repair_count=0; dispatch_count=0; raw_result_path=$null; normalized_result_path=$null; verified=$false; updated_at=(Get-UtcTimestamp) }
        $tasks += [pscustomobject]$task
        Write-Event $state $workflow 'task_registered' $TaskId $null 'draft' 'registration'
        $workflow.updated_at = Get-UtcTimestamp; Write-JsonAtomic $workflow $workflowPath; Write-JsonAtomic $tasks $tasksPath
    }
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
            foreach ($dependency in @($task.depends_on)) { $dep = @($tasks | Where-Object { $_.task_id -eq $dependency }); if ($dep.Count -ne 1 -or $dep[0].status -ne 'completed' -or -not $dep[0].verified) { throw "Dependency is not verified complete: $dependency" } }
            if ([int]$task.dispatch_count -gt 0) { throw 'Task was already dispatched.' }
            $task.dispatch_count = [int]$task.dispatch_count + 1
            $stageByRole = @{ analyst='analysis'; developer='implementation'; tester='test'; reviewer='review' }
            $workflow.current_stage = $stageByRole[[string]$task.role]; $workflow.status = 'running'
        }
        if ($ToStatus -eq 'completed') {
            if (-not $Verified -or [string]::IsNullOrWhiteSpace($RawResultPath) -or [string]::IsNullOrWhiteSpace($NormalizedResultPath)) { throw 'Completion requires verified raw and normalized results.' }
            if (-not (Test-Path -LiteralPath $RawResultPath) -or -not (Test-Path -LiteralPath $NormalizedResultPath)) { throw 'Result evidence file not found.' }
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
    $leftovers = @(Get-ChildItem -LiteralPath $state -File | Where-Object { $_.Name -match '\.(tmp|bak)\.' })
    if ($leftovers.Count -gt 0) { throw 'Interrupted atomic-write artifact detected.' }
    return $true
}

function Get-WorkflowState {
    param([string]$ProjectPath)
    $state = Join-Path ([System.IO.Path]::GetFullPath($ProjectPath)) '.codex-orchestrator'
    [ordered]@{ workflow=(Read-StateJson (Join-Path $state 'workflow.json')); tasks=@(Read-StateJson (Join-Path $state 'tasks.json') | ForEach-Object { $_ }) }
}

Export-ModuleMember -Function Initialize-WorkflowState,Register-WorkflowTask,Set-WorkflowTaskState,Get-WorkflowState,Test-WorkflowStateIntegrity
