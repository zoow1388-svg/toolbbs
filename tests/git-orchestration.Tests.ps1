$manager=Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\manage-workflow.ps1'
$planner=Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\plan-next-actions.ps1'
$executor=Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\controlled-git.ps1'
function Write-TestJson([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))}

Describe 'v1.8 Git transaction orchestration' {
    BeforeEach {
        $project=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory $project)
        & git -C $project init -b main|Out-Null;& git -C $project config user.name test;& git -C $project config user.email test@example.invalid
        Set-Content (Join-Path $project 'README.md') 'base';Set-Content (Join-Path $project '.gitignore') '.codex-orchestrator/';& git -C $project add README.md .gitignore;& git -C $project commit -m baseline|Out-Null
        $base=(& git -C $project rev-parse HEAD).Trim();$worktree=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        &$manager -Action initialize -ProjectPath $project -WorkflowId WF-GIT -ControllerThreadId controller|Out-Null
        &$manager -Action register -ProjectPath $project -TaskId ANALYSIS-001 -ThreadId analyst -Role analyst -Objective analyze -Authorization plan-approved -BaseRevision $base|Out-Null
        &$manager -Action register -ProjectPath $project -TaskId DEV-001 -ThreadId developer -Role developer -Objective develop -Authorization git-approved -BaseRevision $base -AllowedFiles README.md -DependsOn ANALYSIS-001|Out-Null
        &$manager -Action transition -ProjectPath $project -TaskId DEV-001 -ToStatus awaiting_approval -Reason plan|Out-Null
        &$manager -Action transition -ProjectPath $project -TaskId DEV-001 -ToStatus approved -Reason approved|Out-Null
        $requestPath=Join-Path $TestDrive "$([guid]::NewGuid().ToString('N'))-request.json";$receiptPath=Join-Path $TestDrive "$([guid]::NewGuid().ToString('N'))-receipt.json"
        $request=[ordered]@{operation_id='GIT-001';operation='create_worktree';authorization='git-approved';repository_root=$project;worktree_path=$worktree;base_revision=$base;branch_name='codex/dev-001';allowed_files=@('README.md');commit_message=$null;target_branch=$null;test_evidence=$null;review_evidence=$null;created_at=[DateTime]::UtcNow.ToString('o')};Write-TestJson $requestPath $request
    }
    It 'journals a Git intent before the planner exposes execution' {
        $action=&$manager -Action begin-git-action -ProjectPath $project -TaskId DEV-001 -GitRequestPath $requestPath -ExpectedControllerEpoch 1|Where-Object{$_ -notlike 'OK:*'}|ConvertFrom-Json
        $planPath=Join-Path $project 'plan.json';&$planner -ProjectPath $project -OutputPath $planPath|Out-Null;$plan=Get-Content $planPath -Raw|ConvertFrom-Json
        @($plan.actions|Where-Object{$_.type-eq'controlled_git'}).Count|Should Be 1
        ($plan.actions|Where-Object{$_.type-eq'controlled_git'}).parameters.git_action_id|Should Be $action.git_action_id
        @($plan.actions|Where-Object{$_.task_ids -contains 'DEV-001' -and $_.type-ne'controlled_git'}).Count|Should Be 0
    }
    It 'rejects a request that self-asserts authorization or changes after journaling' {
        $tasksPath=Join-Path $project '.codex-orchestrator\tasks.json';$tasks=Get-Content $tasksPath -Raw|ConvertFrom-Json;$tasks[1].authorization='implementation-approved';Write-TestJson $tasksPath $tasks
        {&$manager -Action begin-git-action -ProjectPath $project -TaskId DEV-001 -GitRequestPath $requestPath -ExpectedControllerEpoch 1}|Should Throw
        $tasks[1].authorization='git-approved';Write-TestJson $tasksPath $tasks
        $action=&$manager -Action begin-git-action -ProjectPath $project -TaskId DEV-001 -GitRequestPath $requestPath -ExpectedControllerEpoch 1|Where-Object{$_ -notlike 'OK:*'}|ConvertFrom-Json
        $request=Get-Content $requestPath -Raw|ConvertFrom-Json;$request.branch_name='codex/tampered';Write-TestJson $requestPath $request
        {&$manager -Action controlled-git -ProjectPath $project -GitActionId $action.git_action_id -GitRequestPath $requestPath -GitReceiptPath $receiptPath}|Should Throw
        Test-Path $worktree|Should Be $false
    }
    It 'completes once and refuses duplicate logical execution' {
        $action=&$manager -Action begin-git-action -ProjectPath $project -TaskId DEV-001 -GitRequestPath $requestPath -ExpectedControllerEpoch 1|Where-Object{$_ -notlike 'OK:*'}|ConvertFrom-Json
        &$executor -RequestPath $requestPath -ReceiptPath $receiptPath|Out-Null
        &$manager -Action complete-git-action -ProjectPath $project -GitActionId $action.git_action_id -GitReceiptPath $receiptPath|Out-Null
        {&$manager -Action begin-git-action -ProjectPath $project -TaskId DEV-001 -GitRequestPath $requestPath -ExpectedControllerEpoch 1}|Should Throw
        $planPath=Join-Path $project 'plan.json';&$planner -ProjectPath $project -OutputPath $planPath|Out-Null;$plan=Get-Content $planPath -Raw|ConvertFrom-Json
        @($plan.actions|Where-Object{$_.type-eq'controlled_git'}).Count|Should Be 0
    }
    It 'routes failed Git execution to manual review without retrying' {
        $action=&$manager -Action begin-git-action -ProjectPath $project -TaskId DEV-001 -GitRequestPath $requestPath -ExpectedControllerEpoch 1|Where-Object{$_ -notlike 'OK:*'}|ConvertFrom-Json
        $evidence=Join-Path $project 'failure.txt';Set-Content $evidence 'baseline changed'
        &$manager -Action fail-git-action -ProjectPath $project -GitActionId $action.git_action_id -EvidencePath $evidence -ErrorMessage 'baseline changed'|Out-Null
        $planPath=Join-Path $project 'plan.json';&$planner -ProjectPath $project -OutputPath $planPath|Out-Null;$plan=Get-Content $planPath -Raw|ConvertFrom-Json
        @($plan.actions|Where-Object{$_.operation-eq'inspect_git_action'}).Count|Should Be 1
        @($plan.actions|Where-Object{$_.type-eq'controlled_git'}).Count|Should Be 0
    }
}
