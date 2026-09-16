$manager = Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\manage-workflow.ps1'
$inspector = Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\inspect-worktree.ps1'

function Invoke-WorktreeManager([string[]]$Arguments) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manager @Arguments 2>$null | Out-Null
    $LASTEXITCODE
}

Describe 'v1.5 Git worktree isolation' {
    BeforeEach {
        $caseRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $repository = Join-Path $caseRoot 'repository'
        $worktree = Join-Path $caseRoot 'worktree-dev-001'
        New-Item -ItemType Directory -Path $repository | Out-Null
        & git -C $repository init | Out-Null
        & git -C $repository config user.name 'Codex Test' | Out-Null
        & git -C $repository config user.email 'codex-test@example.invalid' | Out-Null
        [IO.File]::WriteAllText((Join-Path $repository 'baseline.txt'),'baseline',[Text.UTF8Encoding]::new($false))
        & git -C $repository add baseline.txt
        & git -C $repository commit -m baseline | Out-Null
        $baseRevision = (& git -C $repository rev-parse HEAD).Trim()
        & git -C $repository worktree add -b codex/dev-001 $worktree $baseRevision | Out-Null
        $binding = Join-Path $repository 'binding.json'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $inspector -WorktreePath $worktree -OutputPath $binding | Out-Null
        $LASTEXITCODE | Should Be 0
        Invoke-WorktreeManager @('-Action','initialize','-ProjectPath',$repository,'-WorkflowId','WF-WORKTREE','-ControllerThreadId','controller-1') | Should Be 0
        Invoke-WorktreeManager @('-Action','register','-ProjectPath',$repository,'-TaskId','ANALYSIS-001','-ThreadId','thread-analysis','-Role','analyst','-Objective','analyze','-BaseRevision',$baseRevision) | Should Be 0
    }

    It 'binds a clean branch worktree and preserves immutable evidence' {
        Invoke-WorktreeManager @('-Action','register','-ProjectPath',$repository,'-TaskId','DEV-001','-ThreadId','thread-dev-1','-Role','developer','-Objective','develop','-Authorization','implementation-approved','-DependsOn','ANALYSIS-001','-AllowedFiles','src/app.ps1','-BaseRevision',$baseRevision) | Should Be 0
        Invoke-WorktreeManager @('-Action','bind-worktree','-ProjectPath',$repository,'-TaskId','DEV-001','-BindingPath',$binding) | Should Be 0
        $task=@(Get-Content (Join-Path $repository '.codex-orchestrator\tasks.json') -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_}|Where-Object{$_.task_id -eq 'DEV-001'})[0]
        $task.project_path | Should Be ([IO.Path]::GetFullPath($worktree))
        $task.branch_name | Should Be 'codex/dev-001'
        $task.worktree_head_revision | Should Be $baseRevision
        (Test-Path -LiteralPath $task.worktree_binding_path) | Should Be $true
        (Get-FileHash $task.worktree_binding_path -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be $task.worktree_binding_sha256
        Invoke-WorktreeManager @('-Action','audit','-ProjectPath',$repository) | Should Be 0
    }

    It 'rejects reuse of one worktree by two active developer tasks' {
        Invoke-WorktreeManager @('-Action','register','-ProjectPath',$repository,'-TaskId','DEV-001','-ThreadId','thread-dev-1','-Role','developer','-Objective','one','-Authorization','implementation-approved','-DependsOn','ANALYSIS-001','-AllowedFiles','src/one.ps1','-BaseRevision',$baseRevision) | Should Be 0
        Invoke-WorktreeManager @('-Action','register','-ProjectPath',$repository,'-TaskId','DEV-002','-ThreadId','thread-dev-2','-Role','developer','-Objective','two','-Authorization','implementation-approved','-DependsOn','ANALYSIS-001','-AllowedFiles','src/two.ps1','-BaseRevision',$baseRevision) | Should Be 0
        Invoke-WorktreeManager @('-Action','bind-worktree','-ProjectPath',$repository,'-TaskId','DEV-001','-BindingPath',$binding) | Should Be 0
        Invoke-WorktreeManager @('-Action','bind-worktree','-ProjectPath',$repository,'-TaskId','DEV-002','-BindingPath',$binding) | Should Be 1
    }

    It 'embeds the verified worktree identity in a developer dispatch' {
        Invoke-WorktreeManager @('-Action','register','-ProjectPath',$repository,'-TaskId','DEV-001','-ThreadId','thread-dev-1','-Role','developer','-Objective','develop','-Authorization','implementation-approved','-DependsOn','ANALYSIS-001','-AllowedFiles','src/app.ps1','-BaseRevision',$baseRevision) | Should Be 0
        Invoke-WorktreeManager @('-Action','bind-worktree','-ProjectPath',$repository,'-TaskId','DEV-001','-BindingPath',$binding) | Should Be 0
        $tasksPath=Join-Path $repository '.codex-orchestrator\tasks.json'
        $tasks=@(Get-Content $tasksPath -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_})
        $analysis=@($tasks|Where-Object{$_.task_id -eq 'ANALYSIS-001'})[0]
        $dependencyResult=Join-Path $repository 'analysis-result.json'
        [IO.File]::WriteAllText($dependencyResult,(@{end_revision=$baseRevision}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        $analysis.status='completed';$analysis.verified=$true;$analysis.normalized_result_path=$dependencyResult
        [IO.File]::WriteAllText($tasksPath,($tasks|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        foreach($state in @('awaiting_approval','approved')){Invoke-WorktreeManager @('-Action','transition','-ProjectPath',$repository,'-TaskId','DEV-001','-ToStatus',$state,'-Reason','approved')|Should Be 0}
        Invoke-WorktreeManager @('-Action','prepare-dispatch','-ProjectPath',$repository,'-TaskId','DEV-001') | Should Be 0
        $developer=@(Get-Content $tasksPath -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_}|Where-Object{$_.task_id -eq 'DEV-001'})[0]
        $dispatch=Get-Content $developer.dispatch_path -Raw -Encoding UTF8|ConvertFrom-Json
        $dispatch.worktree.path | Should Be ([IO.Path]::GetFullPath($worktree))
        $dispatch.worktree.branch_name | Should Be 'codex/dev-001'
        $dispatch.worktree.head_revision | Should Be $baseRevision
    }

    It 'rejects dirty evidence and requires binding before a commit-based developer dispatch' {
        Invoke-WorktreeManager @('-Action','register','-ProjectPath',$repository,'-TaskId','DEV-001','-ThreadId','thread-dev-1','-Role','developer','-Objective','develop','-Authorization','implementation-approved','-DependsOn','ANALYSIS-001','-AllowedFiles','src/app.ps1','-BaseRevision',$baseRevision) | Should Be 0
        foreach($state in @('awaiting_approval','approved')){Invoke-WorktreeManager @('-Action','transition','-ProjectPath',$repository,'-TaskId','DEV-001','-ToStatus',$state,'-Reason','approved')|Should Be 0}
        Invoke-WorktreeManager @('-Action','prepare-dispatch','-ProjectPath',$repository,'-TaskId','DEV-001') | Should Be 1
        [IO.File]::WriteAllText((Join-Path $worktree 'dirty.txt'),'dirty',[Text.UTF8Encoding]::new($false))
        $dirtyBinding=Join-Path $repository 'dirty-binding.json'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $inspector -WorktreePath $worktree -OutputPath $dirtyBinding | Out-Null
        $LASTEXITCODE | Should Be 0
        Invoke-WorktreeManager @('-Action','bind-worktree','-ProjectPath',$repository,'-TaskId','DEV-001','-BindingPath',$dirtyBinding) | Should Be 1
    }
}
