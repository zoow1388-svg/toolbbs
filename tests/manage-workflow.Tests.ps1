$manager = Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\manage-workflow.ps1'

function Invoke-Manager([string[]]$Arguments) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manager @Arguments 2>$null | Out-Null
    return $LASTEXITCODE
}

Describe 'manage-workflow lifecycle' {
    BeforeEach {
        $project = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $project | Out-Null
    }

    It 'initializes versioned state and an event log' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        $workflow = Get-Content (Join-Path $project '.codex-orchestrator\workflow.json') -Raw | ConvertFrom-Json
        $workflow.state_version | Should Be 2
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
        Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','DEV-001','-ToStatus','dispatched','-Reason','dispatch') | Should Be 1
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
        foreach ($state in @('awaiting_approval','approved','dispatched','running','verifying')) { Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$state,'-Reason','advance') | Should Be 0 }
        $raw = Join-Path $project 'raw.md'; $normalized = Join-Path $project 'result.json'
        Set-Content $raw 'raw'; Set-Content $normalized '{}'
        Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus','completed','-Reason','verified','-RawResultPath',$raw,'-NormalizedResultPath',$normalized,'-Verified') | Should Be 0
        $tasks = @(Get-Content (Join-Path $project '.codex-orchestrator\tasks.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ })
        $tasks[0].verified | Should Be $true
        $events = @(Get-Content (Join-Path $project '.codex-orchestrator\events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        for ($i=0; $i -lt $events.Count; $i++) { $events[$i].sequence | Should Be ($i + 1) }
    }

    It 'rejects completion without both evidence files' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        foreach ($state in @('awaiting_approval','approved','dispatched','running','verifying')) { Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$state,'-Reason','advance') | Should Be 0 }
        Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus','completed','-Reason','missing evidence','-Verified') | Should Be 1
    }

    It 'upgrades v0.1 state defaults on the next successful mutation' {
        $state = Join-Path $project '.codex-orchestrator'; New-Item -ItemType Directory -Path $state | Out-Null
        $now = (Get-Date).ToUniversalTime().ToString('o')
        [pscustomobject]@{ workflow_id='WF-OLD'; project_path=$project; status='draft'; authorization='read-only'; created_at=$now; updated_at=$now } | ConvertTo-Json | Set-Content (Join-Path $state 'workflow.json')
        Set-Content (Join-Path $state 'tasks.json') '[]'
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        $workflow = Get-Content (Join-Path $state 'workflow.json') -Raw | ConvertFrom-Json
        $workflow.state_version | Should Be 2
        $workflow.event_sequence | Should Be 1
    }

    It 'runs the complete analysis development test and review dependency chain' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','DEV-001','-ThreadId','thread-2','-Role','developer','-Objective','develop','-Authorization','implementation-approved','-DependsOn','ANALYSIS-001','-AllowedFiles','src/app.ps1') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','TEST-001','-ThreadId','thread-3','-Role','tester','-Objective','test','-Authorization','test-approved','-DependsOn','DEV-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','REVIEW-001','-ThreadId','thread-4','-Role','reviewer','-Objective','review','-DependsOn','DEV-001,TEST-001') | Should Be 0
        foreach ($taskId in @('ANALYSIS-001','DEV-001','TEST-001','REVIEW-001')) {
            foreach ($stateName in @('awaiting_approval','approved','dispatched','running','verifying')) { Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId',$taskId,'-ToStatus',$stateName,'-Reason','advance') | Should Be 0 }
            $raw = Join-Path $project "$taskId.raw.md"; $normalized = Join-Path $project "$taskId.result.json"
            Set-Content $raw 'raw'; Set-Content $normalized '{}'
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
