$importer = Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\import-wait-snapshot.ps1'
$extractor = Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\extract-thread-result.ps1'
$manager = Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\manage-workflow.ps1'
$fixtures = Join-Path $PSScriptRoot '..\examples\native-task-responses'

function Invoke-Script([string]$Path,[string[]]$Arguments) {
    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>$null)
    [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=$output }
}

function Get-RecordedTask([string]$Project) {
    @(Get-Content (Join-Path $Project '.codex-orchestrator\tasks.json') -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ })[0]
}

Describe 'native task result ingestion' {
    BeforeEach {
        $project = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $project | Out-Null
    }

    It 'imports a truncated wait response without treating its text as the full result' {
        $output = Join-Path $project 'wait-snapshot.json'
        $run = Invoke-Script $importer @('-RawWaitPath',(Join-Path $fixtures 'wait-completed-truncated.json'),'-ExpectedThreadId','thread-001','-ExpectedHostId','local','-OutputPath',$output)
        $run.ExitCode | Should Be 0
        $snapshot = Get-Content $output -Raw -Encoding UTF8 | ConvertFrom-Json
        $snapshot.revision | Should Be 12
        $snapshot.latest_turn_id | Should Be 'turn-001'
        $snapshot.latest_item_id | Should Be 'item-001'
        $snapshot.result_truncated | Should Be $true
        $snapshot.PSObject.Properties.Name -contains 'text' | Should Be $false
        $snapshot.raw_response_sha256.Length | Should Be 64
    }

    It 'accepts a JSON string wrapper and rejects wrong task identity or overwrite' {
        $source = Get-Content (Join-Path $fixtures 'wait-completed-truncated.json') -Raw -Encoding UTF8
        $wrapped = Join-Path $project 'wrapped.json'
        [IO.File]::WriteAllText($wrapped,(ConvertTo-Json -InputObject ([string]$source) -Compress),[Text.UTF8Encoding]::new($false))
        $output = Join-Path $project 'wait-snapshot.json'
        (Invoke-Script $importer @('-RawWaitPath',$wrapped,'-ExpectedThreadId','thread-001','-ExpectedHostId','local','-OutputPath',$output)).ExitCode | Should Be 0
        (Invoke-Script $importer @('-RawWaitPath',$wrapped,'-ExpectedThreadId','wrong-thread','-ExpectedHostId','local','-OutputPath',(Join-Path $project 'wrong.json'))).ExitCode | Should Be 1
        (Invoke-Script $importer @('-RawWaitPath',$wrapped,'-ExpectedThreadId','thread-001','-ExpectedHostId','local','-OutputPath',$output)).ExitCode | Should Be 1
    }

    It 'extracts only the exact completed final item and records its hash' {
        $output = Join-Path $project 'raw-result.md'
        $run = Invoke-Script $extractor @('-RawThreadPath',(Join-Path $fixtures 'read-thread-complete.json'),'-ExpectedThreadId','thread-001','-ExpectedTurnId','turn-001','-ExpectedItemId','item-001','-OutputPath',$output)
        $run.ExitCode | Should Be 0
        (Get-Content $output -Raw -Encoding UTF8) | Should Be 'complete full result'
        $metadata = $run.Output[-1] | ConvertFrom-Json
        $metadata.item_id | Should Be 'item-001'
        $metadata.raw_result_sha256 | Should Be ((Get-FileHash $output -Algorithm SHA256).Hash.ToLowerInvariant())
        (Invoke-Script $extractor @('-RawThreadPath',(Join-Path $fixtures 'read-thread-complete.json'),'-ExpectedThreadId','thread-001','-ExpectedTurnId','turn-001','-ExpectedItemId','missing-item','-OutputPath',(Join-Path $project 'missing.md'))).ExitCode | Should Be 1
        (Invoke-Script $extractor @('-RawThreadPath',(Join-Path $fixtures 'read-thread-complete.json'),'-ExpectedThreadId','thread-001','-ExpectedTurnId','turn-001','-ExpectedItemId','item-001','-OutputPath',$output)).ExitCode | Should Be 1
    }

    It 'records one increasing wait revision and routes recovery to full-result fetch' {
        $activeRaw = Join-Path $project 'wait-active.json'
        Copy-Item (Join-Path $fixtures 'wait-active-commentary.json') $activeRaw
        $activeSnapshot = Join-Path $project 'wait-active.snapshot.json'
        (Invoke-Script $importer @('-RawWaitPath',$activeRaw,'-ExpectedThreadId','thread-001','-ExpectedHostId','local','-OutputPath',$activeSnapshot)).ExitCode | Should Be 0
        $rawWait = Join-Path $project 'wait.json'
        Copy-Item (Join-Path $fixtures 'wait-completed-truncated.json') $rawWait
        $snapshot = Join-Path $project 'wait-snapshot.json'
        (Invoke-Script $importer @('-RawWaitPath',$rawWait,'-ExpectedThreadId','thread-001','-ExpectedHostId','local','-OutputPath',$snapshot)).ExitCode | Should Be 0
        (Invoke-Script $manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001')).ExitCode | Should Be 0
        (Invoke-Script $manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-001','-HostId','local','-Role','analyst','-Objective','analyze')).ExitCode | Should Be 0
        foreach ($state in @('awaiting_approval','approved')) { (Invoke-Script $manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$state,'-Reason','advance')).ExitCode | Should Be 0 }
        (Invoke-Script $manager @('-Action','prepare-dispatch','-ProjectPath',$project,'-TaskId','ANALYSIS-001')).ExitCode | Should Be 0
        $dispatchId = (Get-RecordedTask $project).dispatch_id
        $receipt = Join-Path $project 'receipt.json'; Set-Content $receipt '{"sent":true}'
        (Invoke-Script $manager @('-Action','record-sent','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ReceiptPath',$receipt)).ExitCode | Should Be 0
        (Invoke-Script $manager @('-Action','record-ack','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId)).ExitCode | Should Be 0
        (Invoke-Script $manager @('-Action','record-wait','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-SnapshotPath',$activeSnapshot)).ExitCode | Should Be 0
        $activeTask=Get-RecordedTask $project;$activeTask.latest_turn_status|Should Be 'inProgress';$activeTask.latest_item_phase|Should Be 'commentary'
        $activeReconcile=Invoke-Script $manager @('-Action','reconcile','-ProjectPath',$project,'-TaskId','ANALYSIS-001')
        (($activeReconcile.Output[0..($activeReconcile.Output.Count - 2)] -join "`n")|ConvertFrom-Json).decision|Should Be 'wait_for_result'
        (Invoke-Script $manager @('-Action','record-wait','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-SnapshotPath',$snapshot)).ExitCode | Should Be 0
        $task = Get-RecordedTask $project
        $task.wait_revision | Should Be 12
        $task.latest_item_id | Should Be 'item-001'
        $task.latest_turn_status | Should Be 'completed'
        $task.latest_item_phase | Should Be 'final_answer'
        $task.result_truncated | Should Be $true
        $reconcile = Invoke-Script $manager @('-Action','reconcile','-ProjectPath',$project,'-TaskId','ANALYSIS-001')
        (($reconcile.Output[0..($reconcile.Output.Count - 2)] -join "`n") | ConvertFrom-Json).decision | Should Be 'fetch_full_result'
        (Invoke-Script $manager @('-Action','record-wait','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-SnapshotPath',$snapshot)).ExitCode | Should Be 1
        (Get-RecordedTask $project).wait_revision | Should Be 12
        (Invoke-Script $manager @('-Action','audit','-ProjectPath',$project)).ExitCode | Should Be 0
        Add-Content $rawWait ' '
        (Invoke-Script $manager @('-Action','audit','-ProjectPath',$project)).ExitCode | Should Be 1
    }

    It 'rejects a wait snapshot when its raw response hash no longer matches' {
        $raw = Join-Path $project 'wait.json'; Copy-Item (Join-Path $fixtures 'wait-completed-truncated.json') $raw
        $snapshot = Join-Path $project 'wait-snapshot.json'
        (Invoke-Script $importer @('-RawWaitPath',$raw,'-ExpectedThreadId','thread-001','-ExpectedHostId','local','-OutputPath',$snapshot)).ExitCode | Should Be 0
        Add-Content $raw ' '
        (Invoke-Script $manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001')).ExitCode | Should Be 0
        (Invoke-Script $manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-001','-HostId','local','-Role','analyst','-Objective','analyze')).ExitCode | Should Be 0
        (Invoke-Script $manager @('-Action','record-wait','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-SnapshotPath',$snapshot)).ExitCode | Should Be 1
        (Get-RecordedTask $project).wait_revision | Should Be $null
    }
}
