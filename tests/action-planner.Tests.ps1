$manager=Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\manage-workflow.ps1'
$planner=Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\plan-next-actions.ps1'
$currentCheck=Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\test-action-plan-current.ps1'

function Invoke-Tool([string]$Path,[string[]]$Arguments){
    $output=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>$null)
    [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=$output}
}
function Invoke-Manager([string[]]$Arguments){(Invoke-Tool $manager $Arguments).ExitCode}
function Read-Task([string]$Project,[string]$TaskId){@(Get-Content (Join-Path $Project '.codex-orchestrator\tasks.json') -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_}|Where-Object{$_.task_id -eq $TaskId})[0]}
function New-Plan([string]$Project,[string]$Path){
    (Invoke-Tool $planner @('-ProjectPath',$Project,'-OutputPath',$Path)).ExitCode|Should Be 0
    Get-Content $Path -Raw -Encoding UTF8|ConvertFrom-Json
}
function Approve-Task([string]$Project,[string]$TaskId){foreach($status in @('awaiting_approval','approved')){Invoke-Manager @('-Action','transition','-ProjectPath',$Project,'-TaskId',$TaskId,'-ToStatus',$status,'-Reason','approve')|Should Be 0}}
function Write-NormalizedResult([string]$Path,[string]$Project,[string]$DispatchId){
    $value=[ordered]@{task_id='ANALYSIS-001';dispatch_id=$DispatchId;thread_id='thread-1';host_id='local';project_path=$Project;base_revision='unborn';end_revision='unborn';summary='done';preexisting_changes=@();changed_files=@();commands=@();checks=@();artifacts=@();unexecuted=@();blockers=@();risks=@();required_authorization=$null;created_at=(Get-Date).ToUniversalTime().ToString('o');normalization=[ordered]@{normalized_by='controller';source_thread_id='thread-1';source_message_id='result-1';source_format='text';decisions=@()}}
    [IO.File]::WriteAllText($Path,($value|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
}

Describe 'workflow action planner' {
    BeforeEach{$project=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $project|Out-Null;Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001')|Should Be 0}

    It 'maps approval preparation and sending without executing them' {
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze')|Should Be 0
        $plan=New-Plan $project (Join-Path $project 'draft-plan.json');@($plan.actions).Count|Should Be 1;$plan.actions[0].type|Should Be 'request_authorization'
        (Read-Task $project 'ANALYSIS-001').status|Should Be 'draft'
        Approve-Task $project 'ANALYSIS-001';$plan=New-Plan $project (Join-Path $project 'approved-plan.json');$plan.actions[0].type|Should Be 'prepare_dispatch'
        Invoke-Manager @('-Action','prepare-dispatch','-ProjectPath',$project,'-TaskId','ANALYSIS-001')|Should Be 0
        $plan=New-Plan $project (Join-Path $project 'prepared-plan.json');$plan.actions[0].type|Should Be 'send_message';$plan.actions[0].operation|Should Be 'send_message_to_thread'
        (Read-Task $project 'ANALYSIS-001').delivery_status|Should Be 'prepared'
    }

    It 'rejects an action plan after workflow state changes' {
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze')|Should Be 0
        $path=Join-Path $project 'plan.json';$null=New-Plan $project $path
        (Invoke-Tool $currentCheck @('-ProjectPath',$project,'-PlanPath',$path)).ExitCode|Should Be 0
        Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus','awaiting_approval','-Reason','changed')|Should Be 0
        (Invoke-Tool $currentCheck @('-ProjectPath',$project,'-PlanPath',$path)).ExitCode|Should Be 1
    }

    It 'batches nine waiting tasks into groups of at most eight' {
        foreach($index in 1..9){
            $taskId=('ANALYSIS-{0:D3}' -f $index);$threadId="thread-$index"
            Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId',$taskId,'-ThreadId',$threadId,'-Role','analyst','-Objective','analyze')|Should Be 0
        }
        $state=Join-Path $project '.codex-orchestrator';$tasks=@(Get-Content (Join-Path $state 'tasks.json') -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_})
        foreach($task in $tasks){
            $dispatch=Join-Path $project "$($task.task_id).dispatch.json";$receipt=Join-Path $project "$($task.task_id).receipt.json";Set-Content $dispatch '{}';Set-Content $receipt '{}'
            $task.status='dispatched';$task.delivery_status='sent';$task.dispatch_id="$($task.task_id)-dispatch";$task.dispatch_path=$dispatch;$task.send_receipt_path=$receipt;$task.send_receipt_sha256=(Get-FileHash $receipt -Algorithm SHA256).Hash.ToLowerInvariant();$task.dispatched_at=(Get-Date).ToUniversalTime().ToString('o');$task.read_cursor="cursor-$($task.task_id)"
        }
        [IO.File]::WriteAllText((Join-Path $state 'tasks.json'),($tasks|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $plan=New-Plan $project (Join-Path $project 'wait-plan.json');$waits=@($plan.actions|Where-Object{$_.type -eq 'wait_tasks'})
        $waits.Count|Should Be 2;@($waits[0].parameters.targets).Count|Should Be 8;@($waits[1].parameters.targets).Count|Should Be 1
    }

    It 'reports workflow completion only after trusted verification' {
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze')|Should Be 0;Approve-Task $project 'ANALYSIS-001'
        Invoke-Manager @('-Action','prepare-dispatch','-ProjectPath',$project,'-TaskId','ANALYSIS-001')|Should Be 0;$dispatchId=(Read-Task $project 'ANALYSIS-001').dispatch_id
        $receipt=Join-Path $project 'receipt.json';Set-Content $receipt '{}';Invoke-Manager @('-Action','record-sent','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ReceiptPath',$receipt)|Should Be 0
        $sentPlan=New-Plan $project (Join-Path $project 'sent-plan.json');$sentPlan.actions[0].type|Should Be 'wait_tasks';$sentPlan.actions[0].parameters.targets[0].PSObject.Properties.Match('afterCursor').Count|Should Be 0
        Invoke-Manager @('-Action','record-ack','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId)|Should Be 0
        (New-Plan $project (Join-Path $project 'running-plan.json')).actions[0].type|Should Be 'wait_tasks'
        $taskPath=Join-Path $project '.codex-orchestrator\tasks.json';$tasks=@(Get-Content $taskPath -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_});$tasks[0].latest_turn_id='turn-1';$tasks[0].latest_turn_status='completed';$tasks[0].latest_item_id='result-1';$tasks[0].latest_item_phase='final_answer';[IO.File]::WriteAllText($taskPath,($tasks|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        (New-Plan $project (Join-Path $project 'read-plan.json')).actions[0].type|Should Be 'read_result'
        $raw=Join-Path $project 'raw.md';Set-Content $raw 'done';Invoke-Manager @('-Action','record-result','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ThreadId','thread-1','-ResultMessageId','result-1','-RawResultPath',$raw)|Should Be 0
        $resultPlan=New-Plan $project (Join-Path $project 'normalize-plan.json');@($resultPlan.actions).Count|Should Be 2;$resultPlan.actions[0].type|Should Be 'normalize_result';$resultPlan.actions[1].type|Should Be 'verify_result'
        $normalized=Join-Path $project 'result.json';Write-NormalizedResult $normalized $project $dispatchId
        Invoke-Manager @('-Action','verify-result','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-NormalizedResultPath',$normalized)|Should Be 0
        (New-Plan $project (Join-Path $project 'verified-plan.json')).actions[0].type|Should Be 'complete_task'
        Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus','completed','-Reason','verified')|Should Be 0
        $plan=New-Plan $project (Join-Path $project 'complete-plan.json');@($plan.actions).Count|Should Be 1;$plan.actions[0].type|Should Be 'workflow_complete'
    }

    It 'routes exceptional task states to manual review' {
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze')|Should Be 0
        Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus','blocked','-Reason','blocked')|Should Be 0
        $plan=New-Plan $project (Join-Path $project 'manual-plan.json');@($plan.actions).Count|Should Be 1;$plan.actions[0].type|Should Be 'manual_review';$plan.actions[0].state_changing|Should Be $false
    }

    It 'requires task registration for an empty workflow' {
        $plan=New-Plan $project (Join-Path $project 'empty-plan.json');@($plan.actions).Count|Should Be 1;$plan.actions[0].type|Should Be 'manual_review';$plan.actions[0].operation|Should Be 'register_workflow_tasks'
    }
}
