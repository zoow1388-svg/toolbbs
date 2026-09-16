$manager=Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\manage-workflow.ps1'
$planner=Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\plan-next-actions.ps1'
$executor=Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\controlled-git.ps1'
function Write-TestJson([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))}

Describe 'v1.9 Git lifecycle orchestration' {
    AfterEach {if($script:autoRoot -and(Test-Path $script:autoRoot)){Remove-Item -LiteralPath $script:autoRoot -Recurse -Force};$script:autoRoot=$null}
    BeforeEach {
        $project=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory $project)
        & git -C $project init -b main|Out-Null;& git -C $project config user.name test;& git -C $project config user.email test@example.invalid
        Set-Content (Join-Path $project 'README.md') 'base';Set-Content (Join-Path $project '.gitignore') '.codex-orchestrator/';& git -C $project add README.md .gitignore;& git -C $project commit -m baseline|Out-Null
        $base=(& git -C $project rev-parse HEAD).Trim();$worktree=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $preflight=Join-Path $TestDrive "$([guid]::NewGuid().ToString('N'))-readiness.json";&$manager -Action preflight -ProjectPath $project|Set-Content -LiteralPath $preflight -Encoding UTF8
        &$manager -Action initialize -ProjectPath $project -WorkflowId WF-GIT -ControllerThreadId controller -PreflightPath $preflight|Out-Null
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
    It 'generates, journals, executes, and binds a developer worktree automatically' {
        $planPath=Join-Path $TestDrive 'auto-plan.json';&$planner -ProjectPath $project -OutputPath $planPath|Out-Null;$plan=Get-Content $planPath -Raw|ConvertFrom-Json
        $prepare=@($plan.actions|Where-Object{$_.operation-eq'manage-workflow:prepare-git-request'});$prepare.Count|Should Be 1
        $generated=$prepare[0].parameters.request_path
        $action=&$manager -Action prepare-git-request -ProjectPath $project -TaskId DEV-001 -GitRequestPath $generated -ExpectedControllerEpoch 1|Where-Object{$_ -notlike 'OK:*'}|ConvertFrom-Json
        $receipt=Join-Path $TestDrive 'generated-receipt.json';&$manager -Action controlled-git -ProjectPath $project -GitActionId $action.git_action_id -GitRequestPath $generated -GitReceiptPath $receipt|Out-Null
        &$manager -Action complete-git-action -ProjectPath $project -GitActionId $action.git_action_id -GitReceiptPath $receipt|Out-Null
        $task=@((Get-Content (Join-Path $project '.codex-orchestrator\tasks.json') -Raw|ConvertFrom-Json)|Where-Object{$_.task_id-eq'DEV-001'})[0]
        $task.worktree_mode|Should Be 'developer';$task.branch_name|Should Be 'codex/dev-001';Test-Path $task.worktree_path|Should Be $true
        $task.worktree_path.StartsWith((Join-Path (Split-Path -Parent $project) '.codex-worktrees'),[StringComparison]::OrdinalIgnoreCase)|Should Be $true
    }
    It 'accepts an uncommitted handoff and performs controlled stage and commit' {
        $script:autoRoot=Join-Path $TestDrive "toolbbs-test-worktrees-$([guid]::NewGuid().ToString('N'))";&$manager -Action configure-git -ProjectPath $project -WorktreeRoot $script:autoRoot|Out-Null
        $create=Join-Path $TestDrive 'create.json';$createAction=&$manager -Action prepare-git-request -ProjectPath $project -TaskId DEV-001 -GitOperation create_worktree -GitRequestPath $create -ExpectedControllerEpoch 1|Where-Object{$_-notlike'OK:*'}|ConvertFrom-Json;$createReceipt=Join-Path $TestDrive 'create-receipt.json';&$manager -Action controlled-git -ProjectPath $project -GitActionId $createAction.git_action_id -GitRequestPath $create -GitReceiptPath $createReceipt|Out-Null;&$manager -Action complete-git-action -ProjectPath $project -GitActionId $createAction.git_action_id -GitReceiptPath $createReceipt|Out-Null
        $tasksPath=Join-Path $project '.codex-orchestrator\tasks.json';$tasks=Get-Content $tasksPath -Raw|ConvertFrom-Json;$dev=$tasks[1];$dev.status='running';Write-TestJson $tasksPath $tasks;Set-Content (Join-Path $dev.worktree_path 'README.md') 'changed'
        $handoff=Join-Path $TestDrive 'handoff.json';Write-TestJson $handoff ([ordered]@{task_id='DEV-001';base_revision=$base;changed_files=@('README.md');summary='done';created_at=[DateTime]::UtcNow.ToString('o')} );&$manager -Action record-development-handoff -ProjectPath $project -TaskId DEV-001 -HandoffPath $handoff|Out-Null
        foreach($operation in @('stage','commit')){$request=Join-Path $TestDrive "$operation.json";$receipt=Join-Path $TestDrive "$operation-receipt.json";$action=&$manager -Action prepare-git-request -ProjectPath $project -TaskId DEV-001 -GitOperation $operation -GitRequestPath $request -ExpectedControllerEpoch 1|Where-Object{$_-notlike'OK:*'}|ConvertFrom-Json;&$manager -Action controlled-git -ProjectPath $project -GitActionId $action.git_action_id -GitRequestPath $request -GitReceiptPath $receipt|Out-Null;&$manager -Action complete-git-action -ProjectPath $project -GitActionId $action.git_action_id -GitReceiptPath $receipt|Out-Null}
        $dev=@((Get-Content $tasksPath -Raw|ConvertFrom-Json)|Where-Object{$_.task_id-eq'DEV-001'})[0];$dev.git_phase|Should Be 'committed';$dev.commit_revision|Should Match '^[a-f0-9]{40}$';@(&git -C $dev.worktree_path status --porcelain).Count|Should Be 0
    }
    It 'builds and completes a merge only from trusted gates on the same commit' {
        $script:autoRoot=Join-Path $TestDrive "toolbbs-test-worktrees-$([guid]::NewGuid().ToString('N'))";&$manager -Action configure-git -ProjectPath $project -WorktreeRoot $script:autoRoot -TargetBranch main|Out-Null
        $create=Join-Path $TestDrive 'create-merge.json';$action=&$manager -Action prepare-git-request -ProjectPath $project -TaskId DEV-001 -GitOperation create_worktree -GitRequestPath $create -ExpectedControllerEpoch 1|Where-Object{$_-notlike'OK:*'}|ConvertFrom-Json;$receipt=Join-Path $TestDrive 'create-merge-receipt.json';&$manager -Action controlled-git -ProjectPath $project -GitActionId $action.git_action_id -GitRequestPath $create -GitReceiptPath $receipt|Out-Null;&$manager -Action complete-git-action -ProjectPath $project -GitActionId $action.git_action_id -GitReceiptPath $receipt|Out-Null
        $tasksPath=Join-Path $project '.codex-orchestrator\tasks.json';$tasks=Get-Content $tasksPath -Raw|ConvertFrom-Json;$dev=$tasks[1];$dev.status='running';Write-TestJson $tasksPath $tasks;Set-Content (Join-Path $dev.worktree_path 'README.md') 'ready to merge';$handoff=Join-Path $TestDrive 'merge-handoff.json';Write-TestJson $handoff ([ordered]@{task_id='DEV-001';base_revision=$base;changed_files=@('README.md');summary='done';created_at=[DateTime]::UtcNow.ToString('o')});&$manager -Action record-development-handoff -ProjectPath $project -TaskId DEV-001 -HandoffPath $handoff|Out-Null
        foreach($operation in @('stage','commit')){$request=Join-Path $TestDrive "merge-$operation.json";$operationReceipt=Join-Path $TestDrive "merge-$operation-receipt.json";$operationAction=&$manager -Action prepare-git-request -ProjectPath $project -TaskId DEV-001 -GitOperation $operation -GitRequestPath $request -ExpectedControllerEpoch 1|Where-Object{$_-notlike'OK:*'}|ConvertFrom-Json;&$manager -Action controlled-git -ProjectPath $project -GitActionId $operationAction.git_action_id -GitRequestPath $request -GitReceiptPath $operationReceipt|Out-Null;&$manager -Action complete-git-action -ProjectPath $project -GitActionId $operationAction.git_action_id -GitReceiptPath $operationReceipt|Out-Null}
        $tasks=@(Get-Content $tasksPath -Raw|ConvertFrom-Json|ForEach-Object{$_});$dev=@($tasks|Where-Object{$_.task_id-eq'DEV-001'})[0]
        foreach($role in @('tester','reviewer')){$id=$(if($role-eq'tester'){'TEST-001'}else{'REVIEW-001'});$authorization=$(if($role-eq'tester'){'test-approved'}else{'read-only'});$dependencies=$(if($role-eq'tester'){'DEV-001'}else{'DEV-001,TEST-001'});&$manager -Action register -ProjectPath $project -TaskId $id -ThreadId $role -Role $role -Objective "$role gate" -Authorization $authorization -BaseRevision $base -DependsOn $dependencies|Out-Null;&$manager -Action transition -ProjectPath $project -TaskId $id -ToStatus awaiting_approval -Reason plan|Out-Null;&$manager -Action transition -ProjectPath $project -TaskId $id -ToStatus approved -Reason approved|Out-Null;&$manager -Action publish-verification-revision -ProjectPath $project -TaskId $id -DeveloperTaskId DEV-001|Out-Null}
        $tasks=@(Get-Content $tasksPath -Raw|ConvertFrom-Json|ForEach-Object{$_});@($tasks|Where-Object{$_.role-in@('tester','reviewer')}|ForEach-Object{$_.base_revision}|Select-Object -Unique)|Should Be @($dev.commit_revision)
        foreach($role in @('tester','reviewer')){$gate=@($tasks|Where-Object{$_.role-eq$role})[0];$result=Join-Path $TestDrive "$role-result.json";$gateReceipt=Join-Path $TestDrive "$role-verification.json";Write-TestJson $result ([ordered]@{stage_evidence=[ordered]@{role=$role;outcome='passed';inspected_revision=$dev.commit_revision}});Set-Content $gateReceipt "$role trusted";$gate.status='completed';$gate.verified=$true;$gate.verification_status='trusted';$gate.normalized_result_path=$result;$gate.verification_receipt_path=$gateReceipt}
        Write-TestJson $tasksPath $tasks
        $mergeRequest=Join-Path $TestDrive 'auto-merge.json';$mergeAction=&$manager -Action prepare-git-request -ProjectPath $project -TaskId DEV-001 -GitOperation merge -GitRequestPath $mergeRequest -ExpectedControllerEpoch 1|Where-Object{$_-notlike'OK:*'}|ConvertFrom-Json;$request=Get-Content $mergeRequest -Raw|ConvertFrom-Json;$request.test_evidence.inspected_revision|Should Be $dev.commit_revision;$request.review_evidence.inspected_revision|Should Be $dev.commit_revision
        $mergeReceipt=Join-Path $TestDrive 'auto-merge-receipt.json';&$manager -Action controlled-git -ProjectPath $project -GitActionId $mergeAction.git_action_id -GitRequestPath $mergeRequest -GitReceiptPath $mergeReceipt|Out-Null;&$manager -Action complete-git-action -ProjectPath $project -GitActionId $mergeAction.git_action_id -GitReceiptPath $mergeReceipt|Out-Null
        $merged=@((Get-Content $tasksPath -Raw|ConvertFrom-Json)|Where-Object{$_.task_id-eq'DEV-001'})[0];$merged.git_phase|Should Be 'merged';$merged.merge_revision|Should Be (&git -C $project rev-parse HEAD).Trim()
    }
}
