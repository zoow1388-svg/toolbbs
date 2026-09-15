$manager = Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\manage-workflow.ps1'

function Invoke-Manager([string[]]$Arguments) {
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

Describe 'manage-workflow lifecycle' {
    BeforeEach {
        $project = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $project | Out-Null
    }

    It 'initializes versioned state and an event log' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        $workflow = Get-Content (Join-Path $project '.codex-orchestrator\workflow.json') -Raw | ConvertFrom-Json
        $workflow.state_version | Should Be 5
        $workflow.event_sequence | Should Be 1
        @(Get-Content (Join-Path $project '.codex-orchestrator\events.jsonl')).Count | Should Be 1
    }

    It 'rejects duplicate thread ids' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','TEST-001','-ThreadId','thread-1','-Role','tester','-Objective','test') | Should Be 1
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
        Set-Content $raw 'raw'; [IO.File]::WriteAllText($normalized,([ordered]@{task_id='ANALYSIS-001';thread_id='thread-1';dispatch_id=$dispatchId}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        Invoke-Manager @('-Action','record-result','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ThreadId','thread-1','-ResultMessageId','result-1','-Cursor','cursor-result-1','-RawResultPath',$raw) | Should Be 0
        Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus','completed','-Reason','verified','-RawResultPath',$raw,'-NormalizedResultPath',$normalized,'-Verified') | Should Be 0
        $tasks = @(Get-Content (Join-Path $project '.codex-orchestrator\tasks.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ })
        $tasks[0].verified | Should Be $true
        $events = @(Get-Content (Join-Path $project '.codex-orchestrator\events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        for ($i=0; $i -lt $events.Count; $i++) { $events[$i].sequence | Should Be ($i + 1) }
    }

    It 'rejects completion without both evidence files' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        foreach ($state in @('awaiting_approval','approved')) { Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$state,'-Reason','advance') | Should Be 0 }
        $dispatchId = Start-Task $project 'ANALYSIS-001'
        $raw = Join-Path $project 'raw.md'; Set-Content $raw 'raw'
        Invoke-Manager @('-Action','record-result','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ThreadId','thread-1','-ResultMessageId','result-1','-RawResultPath',$raw) | Should Be 0
        Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus','completed','-Reason','missing evidence','-Verified') | Should Be 1
    }

    It 'upgrades v0.1 state defaults on the next successful mutation' {
        $state = Join-Path $project '.codex-orchestrator'; New-Item -ItemType Directory -Path $state | Out-Null
        $now = (Get-Date).ToUniversalTime().ToString('o')
        [pscustomobject]@{ workflow_id='WF-OLD'; project_path=$project; status='draft'; authorization='read-only'; created_at=$now; updated_at=$now } | ConvertTo-Json | Set-Content (Join-Path $state 'workflow.json')
        Set-Content (Join-Path $state 'tasks.json') '[]'
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        $workflow = Get-Content (Join-Path $state 'workflow.json') -Raw | ConvertFrom-Json
        $workflow.state_version | Should Be 5
        $workflow.event_sequence | Should Be 1
    }

    It 'upgrades v0.2 state to the current version without manual edits' {
        $state = Join-Path $project '.codex-orchestrator'; New-Item -ItemType Directory -Path $state | Out-Null
        $now = (Get-Date).ToUniversalTime().ToString('o')
        [pscustomobject]@{workflow_id='WF-V2';project_path=$project;state_version=2;status='draft';current_stage='analysis';authorization='read-only';event_sequence=0;created_at=$now;updated_at=$now} | ConvertTo-Json | Set-Content (Join-Path $state 'workflow.json')
        Set-Content (Join-Path $state 'tasks.json') '[]'
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        $workflow = Get-Content (Join-Path $state 'workflow.json') -Raw | ConvertFrom-Json
        $workflow.state_version | Should Be 5
        (Get-Task $project 'ANALYSIS-001').delivery_status | Should Be 'not-prepared'
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
        [IO.File]::WriteAllText($normalized,([ordered]@{task_id='ANALYSIS-001';thread_id='thread-1';dispatch_id='old-dispatch'}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus','completed','-Reason','verify','-RawResultPath',$raw,'-NormalizedResultPath',$normalized,'-Verified') | Should Be 1
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

    It 'runs the complete analysis development test and review dependency chain' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','DEV-001','-ThreadId','thread-2','-Role','developer','-Objective','develop','-Authorization','implementation-approved','-DependsOn','ANALYSIS-001','-AllowedFiles','src/app.ps1') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','TEST-001','-ThreadId','thread-3','-Role','tester','-Objective','test','-Authorization','test-approved','-DependsOn','DEV-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','REVIEW-001','-ThreadId','thread-4','-Role','reviewer','-Objective','review','-DependsOn','DEV-001,TEST-001') | Should Be 0
        foreach ($taskId in @('ANALYSIS-001','DEV-001','TEST-001','REVIEW-001')) {
            foreach ($stateName in @('awaiting_approval','approved')) { Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId',$taskId,'-ToStatus',$stateName,'-Reason','advance') | Should Be 0 }
            $dispatchId = Start-Task $project $taskId
            $threadId = (Get-Task $project $taskId).thread_id
            $raw = Join-Path $project "$taskId.raw.md"; $normalized = Join-Path $project "$taskId.result.json"
            Set-Content $raw 'raw'; [IO.File]::WriteAllText($normalized,([ordered]@{task_id=$taskId;thread_id=$threadId;dispatch_id=$dispatchId}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
            Invoke-Manager @('-Action','record-result','-ProjectPath',$project,'-TaskId',$taskId,'-DispatchId',$dispatchId,'-ThreadId',$threadId,'-ResultMessageId',"result-$taskId",'-RawResultPath',$raw) | Should Be 0
            Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId',$taskId,'-ToStatus','completed','-Reason','verified','-RawResultPath',$raw,'-NormalizedResultPath',$normalized,'-Verified') | Should Be 0
        }
        Invoke-Manager @('-Action','audit','-ProjectPath',$project) | Should Be 0
        $tasks = @(Get-Content (Join-Path $project '.codex-orchestrator\tasks.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ })
        @($tasks | Where-Object { $_.status -eq 'completed' -and $_.verified }).Count | Should Be 4
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
