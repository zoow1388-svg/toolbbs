$manager = Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\manage-workflow.ps1'

function Invoke-Manager([string[]]$Arguments) {
    if($Arguments -contains 'initialize'){$Arguments += @('-ControllerThreadId','controller-1','-ControllerHostId','local')}
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manager @Arguments 2>$null | Out-Null
    return $LASTEXITCODE
}

function Get-Task([string]$Project,[string]$TaskId) {
    @(Get-Content (Join-Path $Project '.codex-orchestrator\tasks.json') -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.task_id -eq $TaskId })[0]
}

function Start-Task([string]$Project,[string]$TaskId) {
    Invoke-Manager @('-Action','prepare-dispatch','-ProjectPath',$Project,'-TaskId',$TaskId) | Should Be 0 | Out-Null
    $dispatchId = (Get-Task $Project $TaskId).dispatch_id
    $receipt = Join-Path $Project "$TaskId.send-receipt.json"; Set-Content $receipt '{"sent":true}'
    Invoke-Manager @('-Action','record-sent','-ProjectPath',$Project,'-TaskId',$TaskId,'-DispatchId',$dispatchId,'-ReceiptPath',$receipt,'-MessageId',"sent-$TaskId",'-Cursor',"cursor-sent-$TaskId") | Should Be 0 | Out-Null
    Invoke-Manager @('-Action','record-ack','-ProjectPath',$Project,'-TaskId',$TaskId,'-DispatchId',$dispatchId,'-Cursor',"cursor-ack-$TaskId") | Should Be 0 | Out-Null
    return $dispatchId
}

function Get-ReconcileDecision([string]$Project,[string]$TaskId) {
    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manager -Action reconcile -ProjectPath $Project -TaskId $TaskId)
    $LASTEXITCODE | Should Be 0 | Out-Null
    (($output[0..($output.Count - 2)] -join "`n") | ConvertFrom-Json).decision
}

function Complete-CallbackHandshake([string]$Project,[string]$TaskId) {
    $state=Get-Content (Join-Path $Project '.codex-orchestrator\workflow.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $task=Get-Task $Project $TaskId
    $callback=[ordered]@{type='completion_callback';event_id=$task.callback_event_id;workflow_id=$state.workflow_id;task_id=$task.task_id;dispatch_id=$task.dispatch_id;source_thread_id=$task.thread_id;source_host_id=$task.host_id;target_thread_id=$state.controller_thread_id;target_host_id=$state.controller_host_id;status='completed'}
    $receipt=Join-Path $Project "$TaskId.callback.json";[IO.File]::WriteAllText($receipt,($callback|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    Invoke-Manager @('-Action','record-callback','-ProjectPath',$Project,'-TaskId',$TaskId,'-CallbackEventId',$task.callback_event_id,'-ReceiptPath',$receipt)|Should Be 0|Out-Null
    $ack=Join-Path $Project "$TaskId.callback-ack.json";[IO.File]::WriteAllText($ack,(@{threadId=$task.thread_id}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    Invoke-Manager @('-Action','record-callback-ack','-ProjectPath',$Project,'-TaskId',$TaskId,'-CallbackEventId',$task.callback_event_id,'-ReceiptPath',$ack)|Should Be 0|Out-Null
}

function Write-NormalizedResult([string]$Path,[string]$Project,[string]$TaskId,[string]$ThreadId,[string]$DispatchId,[string]$MessageId) {
    $task=Get-Task $Project $TaskId;$criterionByRole=@{analyst='plan_ready';developer='implementation_complete';tester='tests_executed';reviewer='code_review_complete'}
    $changedFiles=@();if($task.role -eq 'developer'){$changedFiles=@($task.allowed_files[0])};$stageChecks=@();if($task.role -eq 'tester'){$stageChecks=@([ordered]@{name='automated test';status='passed'})}
    $value=[ordered]@{
        task_id=$TaskId;dispatch_id=$DispatchId;thread_id=$ThreadId;host_id='local';project_path=$Project
        base_revision='unborn';end_revision='unborn';summary='verified result';preexisting_changes=@();changed_files=$changedFiles
        commands=@();checks=$stageChecks;artifacts=@();unexecuted=@();blockers=@();risks=@();required_authorization=$null
        created_at=(Get-Date).ToUniversalTime().ToString('o')
        stage_evidence=[ordered]@{role=$task.role;outcome='passed';inspected_revision='unborn';criteria=@($criterionByRole[[string]$task.role]);findings=@()}
        normalization=[ordered]@{normalized_by='controller';source_thread_id=$ThreadId;source_message_id=$MessageId;source_format='text';decisions=@()}
    }
    [IO.File]::WriteAllText($Path,($value|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
}

Describe 'manage-workflow lifecycle' {
    BeforeEach {
        $project = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $project | Out-Null
    }

    It 'initializes versioned state and an event log' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        $workflow = Get-Content (Join-Path $project '.codex-orchestrator\workflow.json') -Raw | ConvertFrom-Json
        $workflow.state_version | Should Be 9
        $workflow.controller_thread_id | Should Be 'controller-1'
        $workflow.event_sequence | Should Be 1
        @(Get-Content (Join-Path $project '.codex-orchestrator\events.jsonl')).Count | Should Be 1
    }

    It 'rejects duplicate thread ids' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','TEST-001','-ThreadId','thread-1','-Role','tester','-Objective','test') | Should Be 1
    }

    It 'configures one immutable controller for a legacy workflow' {
        $state=Join-Path $project '.codex-orchestrator';New-Item -ItemType Directory $state|Out-Null;$now=(Get-Date).ToUniversalTime().ToString('o')
        @{workflow_id='WF-OLD';project_path=$project;state_version=7;status='draft';current_stage='analysis';authorization='read-only';event_sequence=0;created_at=$now;updated_at=$now}|ConvertTo-Json|Set-Content (Join-Path $state 'workflow.json');Set-Content (Join-Path $state 'tasks.json') '[]';Set-Content (Join-Path $state 'events.jsonl') -Value @()
        Invoke-Manager @('-Action','configure-controller','-ProjectPath',$project,'-ControllerThreadId','controller-new')|Should Be 0
        $workflow=Get-Content (Join-Path $state 'workflow.json') -Raw|ConvertFrom-Json;$workflow.controller_thread_id|Should Be 'controller-new';$workflow.state_version|Should Be 9
        Invoke-Manager @('-Action','configure-controller','-ProjectPath',$project,'-ControllerThreadId','controller-new')|Should Be 0
        Invoke-Manager @('-Action','configure-controller','-ProjectPath',$project,'-ControllerThreadId','controller-other')|Should Be 1
    }

    It 'rejects duplicate task ids and insufficient role authorization' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-2','-Role','analyst','-Objective','again') | Should Be 1
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','DEV-001','-ThreadId','thread-2','-Role','developer','-Objective','develop','-DependsOn','ANALYSIS-001') | Should Be 1
    }

    It 'rejects an illegal state jump' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus','completed','-Reason','skip') | Should Be 1
    }

    It 'rejects dispatch while a dependency is incomplete' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','DEV-001','-ThreadId','thread-2','-Role','developer','-Objective','develop','-Authorization','implementation-approved','-DependsOn','ANALYSIS-001','-AllowedFiles','src/app.ps1') | Should Be 0
        foreach ($state in @('awaiting_approval','approved')) { Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','DEV-001','-ToStatus',$state,'-Reason','advance') | Should Be 0 }
        Invoke-Manager @('-Action','prepare-dispatch','-ProjectPath',$project,'-TaskId','DEV-001') | Should Be 1
    }

    It 'enforces role dependency gates' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','DEV-001','-ThreadId','thread-1','-Role','developer','-Objective','develop','-Authorization','implementation-approved') | Should Be 1
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-2','-Role','analyst','-Objective','analyze') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','DEV-001','-ThreadId','thread-1','-Role','developer','-Objective','develop','-Authorization','implementation-approved','-DependsOn','ANALYSIS-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','TEST-001','-ThreadId','thread-3','-Role','tester','-Objective','test','-DependsOn','ANALYSIS-001') | Should Be 1
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','TEST-001','-ThreadId','thread-3','-Role','tester','-Objective','test','-Authorization','test-approved','-DependsOn','DEV-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','REVIEW-001','-ThreadId','thread-4','-Role','reviewer','-Objective','review','-DependsOn','TEST-001') | Should Be 1
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','REVIEW-001','-ThreadId','thread-4','-Role','reviewer','-Objective','review','-DependsOn','DEV-001,TEST-001') | Should Be 0
    }

    It 'rejects overlapping active developer file ownership' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','DEV-001','-ThreadId','thread-2','-Role','developer','-Objective','one','-Authorization','implementation-approved','-DependsOn','ANALYSIS-001','-AllowedFiles','src/app.ps1') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','DEV-002','-ThreadId','thread-3','-Role','developer','-Objective','two','-Authorization','implementation-approved','-DependsOn','ANALYSIS-001','-AllowedFiles','src/app.ps1') | Should Be 1
    }

    It 'completes a verified task and records ordered events' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        foreach ($state in @('awaiting_approval','approved')) { Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$state,'-Reason','advance') | Should Be 0 }
        $dispatchId = Start-Task $project 'ANALYSIS-001'
        $raw = Join-Path $project 'raw.md'; $normalized = Join-Path $project 'result.json'
        Set-Content $raw 'raw'; Write-NormalizedResult $normalized $project 'ANALYSIS-001' 'thread-1' $dispatchId 'result-1'
        Invoke-Manager @('-Action','record-result','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ThreadId','thread-1','-ResultMessageId','result-1','-Cursor','cursor-result-1','-RawResultPath',$raw) | Should Be 0
        Invoke-Manager @('-Action','verify-result','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-NormalizedResultPath',$normalized) | Should Be 0
        Complete-CallbackHandshake $project 'ANALYSIS-001'
        Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus','completed','-Reason','verified') | Should Be 0
        $tasks = @(Get-Content (Join-Path $project '.codex-orchestrator\tasks.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ })
        $tasks[0].verified | Should Be $true
        $tasks[0].normalized_result_sha256.Length | Should Be 64
        $tasks[0].verification_receipt_sha256.Length | Should Be 64
        Test-Path $tasks[0].verification_receipt_path | Should Be $true
        Invoke-Manager @('-Action','audit','-ProjectPath',$project) | Should Be 0
        $events = @(Get-Content (Join-Path $project '.codex-orchestrator\events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        for ($i=0; $i -lt $events.Count; $i++) { $events[$i].sequence | Should Be ($i + 1) }
        Add-Content $normalized 'tampered'
        Invoke-Manager @('-Action','audit','-ProjectPath',$project) | Should Be 1
    }

    It 'rejects completion without both evidence files' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        foreach ($state in @('awaiting_approval','approved')) { Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$state,'-Reason','advance') | Should Be 0 }
        $dispatchId = Start-Task $project 'ANALYSIS-001'
        $raw = Join-Path $project 'raw.md'; Set-Content $raw 'raw'
        Invoke-Manager @('-Action','record-result','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ThreadId','thread-1','-ResultMessageId','result-1','-RawResultPath',$raw) | Should Be 0
        Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus','completed','-Reason','missing evidence') | Should Be 1
    }

    It 'upgrades v0.1 state defaults on the next successful mutation' {
        $state = Join-Path $project '.codex-orchestrator'; New-Item -ItemType Directory -Path $state | Out-Null
        $now = (Get-Date).ToUniversalTime().ToString('o')
        [pscustomobject]@{ workflow_id='WF-OLD'; project_path=$project; status='draft'; authorization='read-only'; created_at=$now; updated_at=$now } | ConvertTo-Json | Set-Content (Join-Path $state 'workflow.json')
        Set-Content (Join-Path $state 'tasks.json') '[]'
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        $workflow = Get-Content (Join-Path $state 'workflow.json') -Raw | ConvertFrom-Json
        $workflow.state_version | Should Be 9
        $workflow.event_sequence | Should Be 1
    }

    It 'upgrades v0.2 state to the current version without manual edits' {
        $state = Join-Path $project '.codex-orchestrator'; New-Item -ItemType Directory -Path $state | Out-Null
        $now = (Get-Date).ToUniversalTime().ToString('o')
        [pscustomobject]@{workflow_id='WF-V2';project_path=$project;state_version=2;status='draft';current_stage='analysis';authorization='read-only';event_sequence=0;created_at=$now;updated_at=$now} | ConvertTo-Json | Set-Content (Join-Path $state 'workflow.json')
        Set-Content (Join-Path $state 'tasks.json') '[]'
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        $workflow = Get-Content (Join-Path $state 'workflow.json') -Raw | ConvertFrom-Json
        $workflow.state_version | Should Be 9
        (Get-Task $project 'ANALYSIS-001').delivery_status | Should Be 'not-prepared'
    }

    It 'upgrades v0.5 task verification defaults on the next legal mutation' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        $state=Join-Path $project '.codex-orchestrator'
        $workflow=Get-Content (Join-Path $state 'workflow.json') -Raw|ConvertFrom-Json;$workflow.state_version=5;$workflow|ConvertTo-Json -Depth 20|Set-Content (Join-Path $state 'workflow.json')
        $tasks=@(Get-Content (Join-Path $state 'tasks.json') -Raw|ConvertFrom-Json|ForEach-Object{$_})
        foreach($name in @('normalized_result_sha256','verification_receipt_path','verification_receipt_sha256','verified_at','latest_turn_status','latest_item_phase')){$tasks[0].PSObject.Properties.Remove($name)}
        $tasks|ConvertTo-Json -Depth 20|Set-Content (Join-Path $state 'tasks.json')
        Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus','awaiting_approval','-Reason','upgrade') | Should Be 0
        (Get-Content (Join-Path $state 'workflow.json') -Raw|ConvertFrom-Json).state_version | Should Be 9
        $upgraded=Get-Task $project 'ANALYSIS-001';$upgraded.PSObject.Properties.Name -contains 'verification_receipt_path' | Should Be $true;$upgraded.PSObject.Properties.Name -contains 'latest_turn_status'|Should Be $true;$upgraded.latest_item_phase|Should Be $null
    }

    It 'keeps legacy completion history without trusting its old self-verified flag' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','old analysis') | Should Be 0
        $state=Join-Path $project '.codex-orchestrator'
        $workflow=Get-Content (Join-Path $state 'workflow.json') -Raw|ConvertFrom-Json;$workflow.state_version=5;$workflow|ConvertTo-Json -Depth 20|Set-Content (Join-Path $state 'workflow.json')
        $tasks=@(Get-Content (Join-Path $state 'tasks.json') -Raw|ConvertFrom-Json|ForEach-Object{$_});$tasks[0].status='completed';$tasks[0].verified=$true
        foreach($name in @('normalized_result_sha256','verification_receipt_path','verification_receipt_sha256','verification_status','verified_at')){$tasks[0].PSObject.Properties.Remove($name)}
        $tasks|ConvertTo-Json -Depth 20|Set-Content (Join-Path $state 'tasks.json')
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-002','-ThreadId','thread-2','-Role','analyst','-Objective','new analysis') | Should Be 0
        $legacy=Get-Task $project 'ANALYSIS-001';$legacy.status|Should Be 'completed';$legacy.verified|Should Be $false;$legacy.verification_status|Should Be 'legacy-unverified'
    }

    It 'rejects incomplete normalized results and the legacy self-verified completion switch' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        foreach($state in @('awaiting_approval','approved')){Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$state,'-Reason','advance')|Should Be 0}
        $dispatchId=Start-Task $project 'ANALYSIS-001';$raw=Join-Path $project 'raw.md';Set-Content $raw 'raw'
        Invoke-Manager @('-Action','record-result','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ThreadId','thread-1','-ResultMessageId','result-1','-RawResultPath',$raw)|Should Be 0
        $incomplete=Join-Path $project 'incomplete.json';Set-Content $incomplete '{"task_id":"ANALYSIS-001"}'
        Invoke-Manager @('-Action','verify-result','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-NormalizedResultPath',$incomplete)|Should Be 1
        Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus','completed','-Reason','legacy','-RawResultPath',$raw,'-NormalizedResultPath',$incomplete,'-Verified')|Should Be 1
        $task=Get-Task $project 'ANALYSIS-001';$task.status|Should Be 'verifying';$task.verified|Should Be $false
    }

    It 'prepares one immutable dispatch envelope and rejects duplicate preparation' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        foreach ($state in @('awaiting_approval','approved')) { Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$state,'-Reason','advance') | Should Be 0 }
        Invoke-Manager @('-Action','prepare-dispatch','-ProjectPath',$project,'-TaskId','ANALYSIS-001') | Should Be 0
        $task = Get-Task $project 'ANALYSIS-001'
        $task.delivery_status | Should Be 'prepared'
        Test-Path $task.dispatch_path | Should Be $true
        Invoke-Manager @('-Action','prepare-dispatch','-ProjectPath',$project,'-TaskId','ANALYSIS-001') | Should Be 1
    }

    It 'rejects a result from the wrong dispatch or thread' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        foreach ($state in @('awaiting_approval','approved')) { Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$state,'-Reason','advance') | Should Be 0 }
        $dispatchId = Start-Task $project 'ANALYSIS-001'
        $raw = Join-Path $project 'raw.md'; Set-Content $raw 'raw'
        Invoke-Manager @('-Action','record-result','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId','wrong-dispatch','-ThreadId','thread-1','-ResultMessageId','result-1','-RawResultPath',$raw) | Should Be 1
        Invoke-Manager @('-Action','record-result','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ThreadId','wrong-thread','-ResultMessageId','result-1','-RawResultPath',$raw) | Should Be 1
        (Get-Task $project 'ANALYSIS-001').delivery_status | Should Be 'acknowledged'
    }

    It 'rejects completion when normalized identity belongs to another dispatch' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        foreach ($state in @('awaiting_approval','approved')) { Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$state,'-Reason','advance') | Should Be 0 }
        $dispatchId = Start-Task $project 'ANALYSIS-001'
        $raw = Join-Path $project 'raw.md'; Set-Content $raw 'raw'
        Invoke-Manager @('-Action','record-result','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ThreadId','thread-1','-ResultMessageId','result-1','-RawResultPath',$raw) | Should Be 0
        $normalized = Join-Path $project 'result.json'
        Write-NormalizedResult $normalized $project 'ANALYSIS-001' 'thread-1' 'old-dispatch' 'result-1'
        Invoke-Manager @('-Action','verify-result','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-NormalizedResultPath',$normalized) | Should Be 1
        Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus','completed','-Reason','verify') | Should Be 1
        (Get-Task $project 'ANALYSIS-001').status | Should Be 'verifying'
    }

    It 'returns deterministic recovery decisions for each delivery stage' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        foreach ($state in @('awaiting_approval','approved')) { Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$state,'-Reason','advance') | Should Be 0 }
        Invoke-Manager @('-Action','prepare-dispatch','-ProjectPath',$project,'-TaskId','ANALYSIS-001') | Should Be 0
        Get-ReconcileDecision $project 'ANALYSIS-001' | Should Be 'send_prepared_dispatch'
        $dispatchId = (Get-Task $project 'ANALYSIS-001').dispatch_id
        $receipt = Join-Path $project 'send-receipt.json'; Set-Content $receipt '{"sent":true}'
        Invoke-Manager @('-Action','record-sent','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ReceiptPath',$receipt,'-MessageId','sent-1','-Cursor','cursor-1') | Should Be 0
        Get-ReconcileDecision $project 'ANALYSIS-001' | Should Be 'wait_for_acknowledgement'
        Invoke-Manager @('-Action','record-ack','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-Cursor','cursor-2') | Should Be 0
        Get-ReconcileDecision $project 'ANALYSIS-001' | Should Be 'wait_for_result'
        $raw = Join-Path $project 'raw.md'; Set-Content $raw 'raw'
        Invoke-Manager @('-Action','record-result','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ThreadId','thread-1','-ResultMessageId','result-1','-Cursor','cursor-3','-RawResultPath',$raw) | Should Be 0
        Get-ReconcileDecision $project 'ANALYSIS-001' | Should Be 'validate_received_result'
    }

    It 'records a real send receipt without inventing a message id and detects tampering' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        foreach($state in @('awaiting_approval','approved')){Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$state,'-Reason','advance')|Should Be 0}
        Invoke-Manager @('-Action','prepare-dispatch','-ProjectPath',$project,'-TaskId','ANALYSIS-001') | Should Be 0
        $dispatchId=(Get-Task $project 'ANALYSIS-001').dispatch_id
        $receipt=Join-Path $project 'receipt.json'; Set-Content $receipt '{"accepted":true}'
        Invoke-Manager @('-Action','record-sent','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ReceiptPath',$receipt,'-Cursor','cursor-1') | Should Be 0
        $task=Get-Task $project 'ANALYSIS-001'; $task.sent_message_id | Should Be $null; $task.send_receipt_sha256.Length | Should Be 64
        Invoke-Manager @('-Action','audit','-ProjectPath',$project)|Should Be 0
        Add-Content $receipt 'tampered'
        Invoke-Manager @('-Action','audit','-ProjectPath',$project)|Should Be 1
    }

    It 'records matching native thread observations and rejects project mismatch' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        $observation=Join-Path $project 'observation.json'; Set-Content $observation '{"status":"idle"}'
        Invoke-Manager @('-Action','record-observation','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-HostId','local','-ObservedProjectPath',$project,'-ObservedStatus','idle','-Cursor','cursor-observed','-ObservationPath',$observation)|Should Be 0
        $task=Get-Task $project 'ANALYSIS-001'; $task.observed_status|Should Be 'idle'; $task.read_cursor|Should Be 'cursor-observed'
        Invoke-Manager @('-Action','record-observation','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-HostId','local','-ObservedProjectPath','D:\wrong-project','-ObservedStatus','idle','-ObservationPath',$observation)|Should Be 1
    }

    It 'records one trusted callback handshake and rejects wrong identity or tampering' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001')|Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze')|Should Be 0
        foreach($status in @('awaiting_approval','approved')){Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$status,'-Reason','advance')|Should Be 0}
        Invoke-Manager @('-Action','prepare-dispatch','-ProjectPath',$project,'-TaskId','ANALYSIS-001')|Should Be 0
        $task=Get-Task $project 'ANALYSIS-001';$wrong=Join-Path $project 'wrong-callback.json';Set-Content $wrong '{"type":"completion_callback","event_id":"wrong"}'
        Invoke-Manager @('-Action','record-callback','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-CallbackEventId',$task.callback_event_id,'-ReceiptPath',$wrong)|Should Be 1
        Complete-CallbackHandshake $project 'ANALYSIS-001'
        $task=Get-Task $project 'ANALYSIS-001';$task.callback_status|Should Be 'acknowledged';$task.callback_receipt_sha256.Length|Should Be 64;$task.callback_ack_receipt_sha256.Length|Should Be 64
        Invoke-Manager @('-Action','record-callback','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-CallbackEventId',$task.callback_event_id,'-ReceiptPath',$task.callback_receipt_path)|Should Be 0
        Invoke-Manager @('-Action','audit','-ProjectPath',$project)|Should Be 0
        Add-Content $task.callback_receipt_path 'tampered';Invoke-Manager @('-Action','audit','-ProjectPath',$project)|Should Be 1
    }

    It 'runs the complete analysis development test and review dependency chain' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze','-BaseRevision','unborn') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','DEV-001','-ThreadId','thread-2','-Role','developer','-Objective','develop','-Authorization','implementation-approved','-DependsOn','ANALYSIS-001','-AllowedFiles','src/app.ps1','-BaseRevision','unborn') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','TEST-001','-ThreadId','thread-3','-Role','tester','-Objective','test','-Authorization','test-approved','-DependsOn','DEV-001','-BaseRevision','unborn') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','REVIEW-001','-ThreadId','thread-4','-Role','reviewer','-Objective','review','-DependsOn','DEV-001,TEST-001','-BaseRevision','unborn') | Should Be 0
        foreach ($taskId in @('ANALYSIS-001','DEV-001','TEST-001','REVIEW-001')) {
            foreach ($stateName in @('awaiting_approval','approved')) { Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId',$taskId,'-ToStatus',$stateName,'-Reason','advance') | Should Be 0 }
            $dispatchId = Start-Task $project $taskId
            $threadId = (Get-Task $project $taskId).thread_id
            $raw = Join-Path $project "$taskId.raw.md"; $normalized = Join-Path $project "$taskId.result.json"
            Set-Content $raw 'raw'; Write-NormalizedResult $normalized $project $taskId $threadId $dispatchId "result-$taskId"
            Invoke-Manager @('-Action','record-result','-ProjectPath',$project,'-TaskId',$taskId,'-DispatchId',$dispatchId,'-ThreadId',$threadId,'-ResultMessageId',"result-$taskId",'-RawResultPath',$raw) | Should Be 0
            Invoke-Manager @('-Action','verify-result','-ProjectPath',$project,'-TaskId',$taskId,'-NormalizedResultPath',$normalized) | Should Be 0
            Complete-CallbackHandshake $project $taskId
            Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId',$taskId,'-ToStatus','completed','-Reason','verified') | Should Be 0
        }
        Invoke-Manager @('-Action','audit','-ProjectPath',$project) | Should Be 0
        $tasks = @(Get-Content (Join-Path $project '.codex-orchestrator\tasks.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ })
        @($tasks | Where-Object { $_.status -eq 'completed' -and $_.verified }).Count | Should Be 4
    }

    It 'allows exactly one scope-preserving repair task' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','DEV-001','-ThreadId','thread-2','-Role','developer','-Objective','develop','-Authorization','implementation-approved','-DependsOn','ANALYSIS-001','-AllowedFiles','src/app.ps1') | Should Be 0
        Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','DEV-001','-ToStatus','failed','-Reason','test failure') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','DEV-002','-ThreadId','thread-3','-Role','developer','-Objective','repair','-Authorization','implementation-approved','-DependsOn','ANALYSIS-001','-AllowedFiles','src/app.ps1','-RepairOf','DEV-001') | Should Be 0
        (Get-Task $project 'DEV-001').repair_count | Should Be 1
        (Get-Task $project 'DEV-002').repair_of | Should Be 'DEV-001'
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','DEV-003','-ThreadId','thread-4','-Role','developer','-Objective','second repair','-Authorization','implementation-approved','-DependsOn','ANALYSIS-001','-AllowedFiles','src/app.ps1','-RepairOf','DEV-001') | Should Be 1
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','DEV-004','-ThreadId','thread-5','-Role','developer','-Objective','expanded repair','-Authorization','implementation-approved','-DependsOn','ANALYSIS-001','-AllowedFiles','src/app.ps1,src/extra.ps1','-RepairOf','DEV-001') | Should Be 1
    }

    It 'does not overwrite valid state when another controller holds the lock' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        $workflowPath = Join-Path $project '.codex-orchestrator\workflow.json'
        $before = Get-Content $workflowPath -Raw
        $lockPath = Join-Path $project '.codex-orchestrator\workflow.lock'
        $stream = [System.IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
        try { Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 1 }
        finally { $stream.Dispose() }
        (Get-Content $workflowPath -Raw) | Should Be $before
    }

    It 'detects event sequence corruption' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','audit','-ProjectPath',$project) | Should Be 0
        $eventPath = Join-Path $project '.codex-orchestrator\events.jsonl'
        $event = Get-Content $eventPath -Raw | ConvertFrom-Json; $event.sequence = 3
        $event | ConvertTo-Json -Compress | Set-Content $eventPath
        Invoke-Manager @('-Action','audit','-ProjectPath',$project) | Should Be 1
    }
}
