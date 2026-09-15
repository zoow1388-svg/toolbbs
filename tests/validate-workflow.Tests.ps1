$scriptPath = Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\validate-workflow.ps1'
$exampleWorkflow = Join-Path $PSScriptRoot '..\examples\read-only-analysis\workflow.json'
$exampleTasks = Join-Path $PSScriptRoot '..\examples\read-only-analysis\tasks.json'

Describe 'validate-workflow' {
    It 'accepts the valid read-only example' {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkflowPath $exampleWorkflow -TasksPath $exampleTasks
        $LASTEXITCODE | Should Be 0
    }

    It 'rejects a missing dependency' {
        $tempTasks = Join-Path $TestDrive 'tasks.json'
        $tasks = Get-Content -LiteralPath $exampleTasks -Raw | ConvertFrom-Json
        $tasks[0].depends_on = @('MISSING-001')
        $tasks | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempTasks -Encoding UTF8
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkflowPath $exampleWorkflow -TasksPath $tempTasks | Out-Null
        $LASTEXITCODE | Should Be 1
    }

    It 'rejects a developer without implementation approval' {
        $tempTasks = Join-Path $TestDrive 'tasks.json'
        $tasks = Get-Content -LiteralPath $exampleTasks -Raw | ConvertFrom-Json
        $tasks[0].role = 'developer'
        $tasks[0].allowed_files = @('src/app.ps1')
        $tasks | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempTasks -Encoding UTF8
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkflowPath $exampleWorkflow -TasksPath $tempTasks | Out-Null
        $LASTEXITCODE | Should Be 1
    }

    It 'rejects a project path mismatch' {
        $tempTasks = Join-Path $TestDrive 'tasks.json'
        $tasks = Get-Content -LiteralPath $exampleTasks -Raw | ConvertFrom-Json
        $tasks[0].project_path = 'D:\other-project'
        $tasks | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempTasks -Encoding UTF8
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkflowPath $exampleWorkflow -TasksPath $tempTasks | Out-Null
        $LASTEXITCODE | Should Be 1
    }

    It 'rejects more than one repair' {
        $tempTasks = Join-Path $TestDrive 'tasks.json'
        $tasks = Get-Content -LiteralPath $exampleTasks -Raw | ConvertFrom-Json
        $tasks[0].repair_count = 2
        $tasks | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempTasks -Encoding UTF8
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkflowPath $exampleWorkflow -TasksPath $tempTasks | Out-Null
        $LASTEXITCODE | Should Be 1
    }

    It 'rejects overlapping active developer files' {
        $tempTasks = Join-Path $TestDrive 'tasks.json'
        $tasks = @(
            [pscustomobject]@{ task_id='DEV-001'; thread_id='one'; host_id='local'; role='developer'; status='approved'; depends_on=@(); project_path='D:\example-project'; base_revision='abc'; allowed_files=@('src/app.ps1'); objective='one'; authorization='implementation-approved'; repair_count=0; updated_at='2026-09-15T00:00:00+08:00' },
            [pscustomobject]@{ task_id='DEV-002'; thread_id='two'; host_id='local'; role='developer'; status='approved'; depends_on=@(); project_path='D:\example-project'; base_revision='abc'; allowed_files=@('src/app.ps1'); objective='two'; authorization='implementation-approved'; repair_count=0; updated_at='2026-09-15T00:00:00+08:00' }
        )
        $tasks | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempTasks -Encoding UTF8
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkflowPath $exampleWorkflow -TasksPath $tempTasks | Out-Null
        $LASTEXITCODE | Should Be 1
    }

    It 'rejects a dependency cycle' {
        $tempTasks = Join-Path $TestDrive 'tasks.json'
        $tasks = @(
            [pscustomobject]@{ task_id='ANALYSIS-001'; thread_id='one'; host_id='local'; role='analyst'; status='approved'; depends_on=@('TEST-001'); project_path='D:\example-project'; base_revision='abc'; allowed_files=@(); objective='one'; authorization='read-only'; repair_count=0; updated_at='2026-09-15T00:00:00+08:00' },
            [pscustomobject]@{ task_id='TEST-001'; thread_id='two'; host_id='local'; role='tester'; status='approved'; depends_on=@('ANALYSIS-001'); project_path='D:\example-project'; base_revision='abc'; allowed_files=@(); objective='two'; authorization='test-approved'; repair_count=0; updated_at='2026-09-15T00:00:00+08:00' }
        )
        $tasks | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempTasks -Encoding UTF8
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -WorkflowPath $exampleWorkflow -TasksPath $tempTasks | Out-Null
        $LASTEXITCODE | Should Be 1
    }
}
