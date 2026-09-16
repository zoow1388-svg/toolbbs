$manager = Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\manage-workflow.ps1'

function Invoke-Manager([string[]]$Arguments) {
    if($Arguments -contains 'initialize'){$Arguments += @('-ControllerThreadId','controller-1','-ControllerHostId','local')}
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manager @Arguments 2>$null | Out-Null
    return $LASTEXITCODE
}

function Get-Task([string]$Project,[string]$TaskId) {
    @(Get-Content (Join-Path $Project '.codex-orchestrator\tasks.json') -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.task_id -eq $TaskId })[0]
}

function Complete-ExternalAction([string]$Project,[string]$TaskId,[string]$Type,[string]$Receipt,[string]$MessageId,[string]$Cursor){
    $workflow=Get-Content (Join-Path $Project '.codex-orchestrator\workflow.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Invoke-Manager @('-Action','begin-external-action','-ProjectPath',$Project,'-TaskId',$TaskId,'-ExternalActionType',$Type,'-ExpectedControllerEpoch',[string]$workflow.controller_epoch)|Should Be 0|Out-Null
    $action=@(Get-Content (Join-Path $Project '.codex-orchestrator\external-actions.json') -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_}|Where-Object{$_.task_id -eq $TaskId -and $_.action_type -eq $Type}|Sort-Object attempt)[-1]
    $arguments=@('-Action','complete-external-action','-ProjectPath',$Project,'-ExternalActionId',$action.action_id,'-ReceiptPath',$Receipt)
    if($MessageId){$arguments+=@('-MessageId',$MessageId)};if($Cursor){$arguments+=@('-Cursor',$Cursor)}
    Invoke-Manager $arguments|Should Be 0|Out-Null
    $action.action_id
}

function Start-Task([string]$Project,[string]$TaskId) {
    Invoke-Manager @('-Action','prepare-dispatch','-ProjectPath',$Project,'-TaskId',$TaskId) | Should Be 0 | Out-Null
    $dispatchId = (Get-Task $Project $TaskId).dispatch_id
    $receipt = Join-Path $Project "$TaskId.send-receipt.json"; Set-Content $receipt '{"sent":true}'
    $externalActionId=Complete-ExternalAction $Project $TaskId 'dispatch_send' $receipt "sent-$TaskId" "cursor-sent-$TaskId"
    Invoke-Manager @('-Action','record-sent','-ProjectPath',$Project,'-TaskId',$TaskId,'-DispatchId',$dispatchId,'-ReceiptPath',$receipt,'-MessageId',"sent-$TaskId",'-Cursor',"cursor-sent-$TaskId",'-ExternalActionId',$externalActionId) | Should Be 0 | Out-Null
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
    $callback=[ordered]@{type='completion_callback';event_id=$task.callback_event_id;workflow_id=$state.workflow_id;task_id=$task.task_id;dispatch_id=$task.dispatch_id;source_thread_id=$task.thread_id;source_host_id=$task.host_id;target_thread_id=$task.callback_target_thread_id;target_host_id=$task.callback_target_host_id;status='completed'}
    $receipt=Join-Path $Project "$TaskId.callback.json";[IO.File]::WriteAllText($receipt,($callback|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    Invoke-Manager @('-Action','record-callback','-ProjectPath',$Project,'-TaskId',$TaskId,'-CallbackEventId',$task.callback_event_id,'-ReceiptPath',$receipt)|Should Be 0|Out-Null
    $ack=Join-Path $Project "$TaskId.callback-ack.json";[IO.File]::WriteAllText($ack,(@{threadId=$task.thread_id}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    $externalActionId=Complete-ExternalAction $Project $TaskId 'callback_ack' $ack $null $null
    Invoke-Manager @('-Action','record-callback-ack','-ProjectPath',$Project,'-TaskId',$TaskId,'-CallbackEventId',$task.callback_event_id,'-ReceiptPath',$ack,'-ExternalActionId',$externalActionId)|Should Be 0|Out-Null
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
        $workflow.state_version | Should Be 19
        $workflow.controller_thread_id | Should Be 'controller-1'
        $workflow.event_sequence | Should Be 1
        $workflow.git_worktree_root | Should Be (Join-Path (Join-Path (Split-Path -Parent $project) '.codex-worktrees') (Split-Path -Leaf $project))
        @(Get-Content (Join-Path $project '.codex-orchestrator\events.jsonl')).Count | Should Be 1
        @(Get-Content (Join-Path $project '.codex-orchestrator\action-executions.json') -Raw|ConvertFrom-Json).Count | Should Be 0
    }

    It 'derives a sibling worktree root and rejects roots inside the project' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001')|Should Be 0
        $outside=Join-Path (Split-Path -Parent $project) 'custom-worktrees'
        Invoke-Manager @('-Action','configure-git','-ProjectPath',$project,'-WorktreeRoot',$outside,'-TargetBranch','main')|Should Be 0
        (Get-Content (Join-Path $project '.codex-orchestrator\workflow.json') -Raw|ConvertFrom-Json).git_worktree_root|Should Be ([IO.Path]::GetFullPath($outside))
        Invoke-Manager @('-Action','configure-git','-ProjectPath',$project,'-WorktreeRoot',(Join-Path $project 'worktrees'),'-TargetBranch','main')|Should Be 1
    }

    It 'claims one current action and rejects duplicate or stale controllers' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001')|Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze')|Should Be 0
        $planPath=Join-Path $project 'plan.json';powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\plan-next-actions.ps1') -ProjectPath $project -OutputPath $planPath|Out-Null;$LASTEXITCODE|Should Be 0
        $plan=Get-Content $planPath -Raw -Encoding UTF8|ConvertFrom-Json;$actionId=$plan.actions[0].action_id
        Invoke-Manager @('-Action','claim-action','-ProjectPath',$project,'-PlanPath',$planPath,'-ActionId',$actionId,'-ExpectedControllerEpoch','1','-LeaseSeconds','60')|Should Be 0
        Invoke-Manager @('-Action','claim-action','-ProjectPath',$project,'-PlanPath',$planPath,'-ActionId',$actionId,'-ExpectedControllerEpoch','1')|Should Be 1
        $execution=@(Get-Content (Join-Path $project '.codex-orchestrator\action-executions.json') -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_})[0]
        $execution.status|Should Be 'claimed';$execution.operation_sha256|Should Be $plan.actions[0].operation_sha256
        $activeEvidence=Join-Path $project 'active.json';Set-Content $activeEvidence '{}';Invoke-Manager @('-Action','resolve-action','-ProjectPath',$project,'-ExecutionId',$execution.execution_id,'-Resolution','abandoned','-EvidencePath',$activeEvidence,'-Reason','too early')|Should Be 1
        Invoke-Manager @('-Action','takeover-controller','-ProjectPath',$project,'-ExpectedControllerThreadId','controller-1','-ExpectedControllerEpoch','1','-ControllerThreadId','controller-2','-TakeoverReason','replace')|Should Be 0
        $recoveryPlan=Join-Path $project 'recovery-plan.json';powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\plan-next-actions.ps1') -ProjectPath $project -OutputPath $recoveryPlan|Out-Null
        (Get-Content $recoveryPlan -Raw -Encoding UTF8|ConvertFrom-Json).actions[0].type|Should Be 'resolve_action_execution'
        $evidence=Join-Path $project 'done.json';Set-Content $evidence '{}'
        Invoke-Manager @('-Action','complete-action','-ProjectPath',$project,'-ExecutionId',$execution.execution_id,'-EvidencePath',$evidence)|Should Be 1
        Invoke-Manager @('-Action','resolve-action','-ProjectPath',$project,'-ExecutionId',$execution.execution_id,'-Resolution','abandoned','-EvidencePath',$evidence,'-Reason','independent inspection found no effect')|Should Be 0
        $retryPlan=Join-Path $project 'retry-plan.json';powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\plan-next-actions.ps1') -ProjectPath $project -OutputPath $retryPlan|Out-Null;$retry=Get-Content $retryPlan -Raw -Encoding UTF8|ConvertFrom-Json
        Invoke-Manager @('-Action','claim-action','-ProjectPath',$project,'-PlanPath',$retryPlan,'-ActionId',$retry.actions[0].action_id,'-ExpectedControllerEpoch','2')|Should Be 0
        @(Get-Content (Join-Path $project '.codex-orchestrator\action-executions.json') -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_}|Sort-Object attempt)[-1].attempt|Should Be 2
    }

    It 'does not abandon a send operation while its external transaction remains unresolved' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001')|Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze')|Should Be 0
        foreach($status in @('awaiting_approval','approved')){Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$status,'-Reason','approve')|Should Be 0};Invoke-Manager @('-Action','prepare-dispatch','-ProjectPath',$project,'-TaskId','ANALYSIS-001')|Should Be 0
        $planner=Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\plan-next-actions.ps1';$planPath=Join-Path $project 'send-plan.json';powershell.exe -NoProfile -ExecutionPolicy Bypass -File $planner -ProjectPath $project -OutputPath $planPath|Out-Null;$plan=Get-Content $planPath -Raw -Encoding UTF8|ConvertFrom-Json
        Invoke-Manager @('-Action','claim-action','-ProjectPath',$project,'-PlanPath',$planPath,'-ActionId',$plan.actions[0].action_id,'-ExpectedControllerEpoch','1')|Should Be 0
        $execution=@(Get-Content (Join-Path $project '.codex-orchestrator\action-executions.json') -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_})[0]
        Invoke-Manager @('-Action','begin-external-action','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ExternalActionType','dispatch_send','-ExpectedControllerEpoch','1')|Should Be 0
        Invoke-Manager @('-Action','takeover-controller','-ProjectPath',$project,'-ExpectedControllerThreadId','controller-1','-ExpectedControllerEpoch','1','-ControllerThreadId','controller-2','-TakeoverReason','replace')|Should Be 0
        $evidence=Join-Path $project 'not-sent.json';Set-Content $evidence '{}';Invoke-Manager @('-Action','resolve-action','-ProjectPath',$project,'-ExecutionId',$execution.execution_id,'-Resolution','abandoned','-EvidencePath',$evidence,'-Reason','claimed no send')|Should Be 1
    }

    It 'completes or fails claimed actions with immutable evidence' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001')|Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze')|Should Be 0
        $planner=Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\plan-next-actions.ps1';$planPath=Join-Path $project 'plan.json';powershell.exe -NoProfile -ExecutionPolicy Bypass -File $planner -ProjectPath $project -OutputPath $planPath|Out-Null;$plan=Get-Content $planPath -Raw -Encoding UTF8|ConvertFrom-Json
        Invoke-Manager @('-Action','claim-action','-ProjectPath',$project,'-PlanPath',$planPath,'-ActionId',$plan.actions[0].action_id,'-ExpectedControllerEpoch','1')|Should Be 0
        $execution=@(Get-Content (Join-Path $project '.codex-orchestrator\action-executions.json') -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_})[0];$evidence=Join-Path $project 'evidence.json';Set-Content $evidence '{"shown":true}'
        Invoke-Manager @('-Action','renew-action','-ProjectPath',$project,'-ExecutionId',$execution.execution_id,'-LeaseSeconds','600')|Should Be 0
        Invoke-Manager @('-Action','complete-action','-ProjectPath',$project,'-ExecutionId',$execution.execution_id,'-EvidencePath',$evidence)|Should Be 0
        Invoke-Manager @('-Action','complete-action','-ProjectPath',$project,'-ExecutionId',$execution.execution_id,'-EvidencePath',$evidence)|Should Be 0
        Add-Content $evidence 'tamper';Invoke-Manager @('-Action','audit','-ProjectPath',$project)|Should Be 1
    }

    It 'records a failed action and routes the same logical operation to manual review' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001')|Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze')|Should Be 0
        $planner=Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\plan-next-actions.ps1';$planPath=Join-Path $project 'plan.json';powershell.exe -NoProfile -ExecutionPolicy Bypass -File $planner -ProjectPath $project -OutputPath $planPath|Out-Null;$plan=Get-Content $planPath -Raw -Encoding UTF8|ConvertFrom-Json
        Invoke-Manager @('-Action','claim-action','-ProjectPath',$project,'-PlanPath',$planPath,'-ActionId',$plan.actions[0].action_id,'-ExpectedControllerEpoch','1')|Should Be 0
        $execution=@(Get-Content (Join-Path $project '.codex-orchestrator\action-executions.json') -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_})[0];$evidence=Join-Path $project 'failure.json';Set-Content $evidence '{"exit_code":1}'
        Invoke-Manager @('-Action','fail-action','-ProjectPath',$project,'-ExecutionId',$execution.execution_id,'-EvidencePath',$evidence,'-ErrorMessage','operation failed')|Should Be 0
        $recovery=Join-Path $project 'recovery.json';powershell.exe -NoProfile -ExecutionPolicy Bypass -File $planner -ProjectPath $project -OutputPath $recovery|Out-Null;$recoveryPlan=Get-Content $recovery -Raw -Encoding UTF8|ConvertFrom-Json
        $recoveryPlan.actions[0].type|Should Be 'request_retry_authorization';$recoveryPlan.actions[0].parameters.execution_id|Should Be $execution.execution_id
        $retryEvidence=Join-Path $project 'retry-approved.json';Set-Content $retryEvidence '{"approved":true}'
        Invoke-Manager @('-Action','authorize-action-retry','-ProjectPath',$project,'-ExecutionId',$execution.execution_id,'-EvidencePath',$retryEvidence,'-Reason','user approved after cause removed')|Should Be 0
        $retryPlanPath=Join-Path $project 'retry-plan.json';powershell.exe -NoProfile -ExecutionPolicy Bypass -File $planner -ProjectPath $project -OutputPath $retryPlanPath|Out-Null;$retryPlan=Get-Content $retryPlanPath -Raw -Encoding UTF8|ConvertFrom-Json
        Invoke-Manager @('-Action','claim-action','-ProjectPath',$project,'-PlanPath',$retryPlanPath,'-ActionId',$retryPlan.actions[0].action_id,'-ExpectedControllerEpoch','1')|Should Be 0
        @(Get-Content (Join-Path $project '.codex-orchestrator\action-executions.json') -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_}|Sort-Object attempt)[-1].attempt|Should Be 2
        Invoke-Manager @('-Action','audit','-ProjectPath',$project)|Should Be 0
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
        $workflow=Get-Content (Join-Path $state 'workflow.json') -Raw|ConvertFrom-Json;$workflow.controller_thread_id|Should Be 'controller-new';$workflow.state_version|Should Be 19
        Invoke-Manager @('-Action','configure-controller','-ProjectPath',$project,'-ControllerThreadId','controller-new')|Should Be 0
        Invoke-Manager @('-Action','configure-controller','-ProjectPath',$project,'-ControllerThreadId','controller-other')|Should Be 1
    }

    It 'takes over one controller lease without rewriting an existing dispatch' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        foreach($status in @('awaiting_approval','approved')){Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$status,'-Reason','advance')|Should Be 0}
        $null=Start-Task $project 'ANALYSIS-001'
        $before=Get-Task $project 'ANALYSIS-001';$dispatchBefore=Get-Content $before.dispatch_path -Raw -Encoding UTF8
        $before.callback_target_thread_id | Should Be 'controller-1';$before.dispatch_controller_epoch | Should Be 1
        Invoke-Manager @('-Action','takeover-controller','-ProjectPath',$project,'-ExpectedControllerThreadId','controller-1','-ExpectedControllerEpoch','1','-ControllerThreadId','controller-2','-TakeoverReason','original controller unavailable') | Should Be 0
        $workflow=Get-Content (Join-Path $project '.codex-orchestrator\workflow.json') -Raw -Encoding UTF8|ConvertFrom-Json
        $workflow.controller_thread_id|Should Be 'controller-2';$workflow.controller_epoch|Should Be 2;@($workflow.controller_history).Count|Should Be 1;$workflow.controller_history[0].thread_id|Should Be 'controller-1'
        $after=Get-Task $project 'ANALYSIS-001';$after.callback_target_thread_id|Should Be 'controller-1';$after.dispatch_controller_epoch|Should Be 1
        (Get-Content $after.dispatch_path -Raw -Encoding UTF8)|Should Be $dispatchBefore
        Invoke-Manager @('-Action','takeover-controller','-ProjectPath',$project,'-ExpectedControllerThreadId','controller-1','-ExpectedControllerEpoch','1','-ControllerThreadId','controller-3','-TakeoverReason','stale contender') | Should Be 1
        Complete-CallbackHandshake $project 'ANALYSIS-001'
        (Get-Task $project 'ANALYSIS-001').callback_status|Should Be 'acknowledged'
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-002','-ThreadId','thread-2','-Role','analyst','-Objective','new work')|Should Be 0
        foreach($status in @('awaiting_approval','approved')){Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-002','-ToStatus',$status,'-Reason','advance')|Should Be 0}
        Invoke-Manager @('-Action','prepare-dispatch','-ProjectPath',$project,'-TaskId','ANALYSIS-002')|Should Be 0
        $newTask=Get-Task $project 'ANALYSIS-002';$newTask.callback_target_thread_id|Should Be 'controller-2';$newTask.dispatch_controller_epoch|Should Be 2
        Invoke-Manager @('-Action','audit','-ProjectPath',$project) | Should Be 0
    }

    It 'rejects using one identity as controller and worker' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001') | Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','controller-1','-Role','analyst','-Objective','invalid') | Should Be 1
    }

    It 'stops on an unresolved external send and rejects completion from an old controller lease' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001')|Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze')|Should Be 0
        foreach($status in @('awaiting_approval','approved')){Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$status,'-Reason','advance')|Should Be 0}
        Invoke-Manager @('-Action','prepare-dispatch','-ProjectPath',$project,'-TaskId','ANALYSIS-001')|Should Be 0
        Invoke-Manager @('-Action','begin-external-action','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ExternalActionType','dispatch_send','-ExpectedControllerEpoch','1')|Should Be 0
        Invoke-Manager @('-Action','begin-external-action','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ExternalActionType','dispatch_send','-ExpectedControllerEpoch','1')|Should Be 1
        Get-ReconcileDecision $project 'ANALYSIS-001'|Should Be 'inspect_external_action'
        $action=@(Get-Content (Join-Path $project '.codex-orchestrator\external-actions.json') -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_})[0]
        Invoke-Manager @('-Action','takeover-controller','-ProjectPath',$project,'-ExpectedControllerThreadId','controller-1','-ExpectedControllerEpoch','1','-ControllerThreadId','controller-2','-TakeoverReason','controller lost after send')|Should Be 0
        $receipt=Join-Path $project 'late-receipt.json';Set-Content $receipt '{"threadId":"thread-1"}'
        Invoke-Manager @('-Action','complete-external-action','-ProjectPath',$project,'-ExternalActionId',$action.action_id,'-ReceiptPath',$receipt)|Should Be 1
        $deliveryEvidence=Join-Path $project 'delivery-observation.json';Set-Content $deliveryEvidence '{"observed":"delivered"}'
        Invoke-Manager @('-Action','complete-external-action','-ProjectPath',$project,'-ExternalActionId',$action.action_id,'-ReceiptPath',$receipt,'-EvidencePath',$deliveryEvidence)|Should Be 0
        Get-ReconcileDecision $project 'ANALYSIS-001'|Should Be 'record_dispatch_send'
    }

    It 'cancels a proven unsent action and completes one replacement idempotently' {
        Invoke-Manager @('-Action','initialize','-ProjectPath',$project,'-WorkflowId','WF-001')|Should Be 0
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze')|Should Be 0
        foreach($status in @('awaiting_approval','approved')){Invoke-Manager @('-Action','transition','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ToStatus',$status,'-Reason','advance')|Should Be 0};Invoke-Manager @('-Action','prepare-dispatch','-ProjectPath',$project,'-TaskId','ANALYSIS-001')|Should Be 0
        $dispatchId=(Get-Task $project 'ANALYSIS-001').dispatch_id;$bypassReceipt=Join-Path $project 'bypass.json';Set-Content $bypassReceipt '{"threadId":"thread-1"}'
        Invoke-Manager @('-Action','record-sent','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ReceiptPath',$bypassReceipt,'-ExternalActionId','missing')|Should Be 1
        Invoke-Manager @('-Action','begin-external-action','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ExternalActionType','dispatch_send','-ExpectedControllerEpoch','1')|Should Be 0
        $first=@(Get-Content (Join-Path $project '.codex-orchestrator\external-actions.json') -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_})[0];$evidence=Join-Path $project 'not-sent.json';Set-Content $evidence '{"verified":"not-sent"}'
        Invoke-Manager @('-Action','cancel-external-action','-ProjectPath',$project,'-ExternalActionId',$first.action_id,'-EvidencePath',$evidence)|Should Be 0
        Get-ReconcileDecision $project 'ANALYSIS-001'|Should Be 'begin_dispatch_send'
        Invoke-Manager @('-Action','begin-external-action','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ExternalActionType','dispatch_send','-ExpectedControllerEpoch','1')|Should Be 0
        $second=@(Get-Content (Join-Path $project '.codex-orchestrator\external-actions.json') -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_}|Sort-Object attempt)[-1];$second.attempt|Should Be 2
        $receipt=Join-Path $project 'receipt.json';Set-Content $receipt '{"threadId":"thread-1"}';Invoke-Manager @('-Action','complete-external-action','-ProjectPath',$project,'-ExternalActionId',$second.action_id,'-ReceiptPath',$receipt)|Should Be 0
        Invoke-Manager @('-Action','complete-external-action','-ProjectPath',$project,'-ExternalActionId',$second.action_id,'-ReceiptPath',$receipt)|Should Be 0
        $wrongReceipt=Join-Path $project 'wrong-receipt.json';Set-Content $wrongReceipt '{"threadId":"other"}';Invoke-Manager @('-Action','complete-external-action','-ProjectPath',$project,'-ExternalActionId',$second.action_id,'-ReceiptPath',$wrongReceipt)|Should Be 1
        Invoke-Manager @('-Action','audit','-ProjectPath',$project)|Should Be 0
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
        $workflow.state_version | Should Be 19
        $workflow.event_sequence | Should Be 1
    }

    It 'upgrades v0.2 state to the current version without manual edits' {
        $state = Join-Path $project '.codex-orchestrator'; New-Item -ItemType Directory -Path $state | Out-Null
        $now = (Get-Date).ToUniversalTime().ToString('o')
        [pscustomobject]@{workflow_id='WF-V2';project_path=$project;state_version=2;status='draft';current_stage='analysis';authorization='read-only';event_sequence=0;created_at=$now;updated_at=$now} | ConvertTo-Json | Set-Content (Join-Path $state 'workflow.json')
        Set-Content (Join-Path $state 'tasks.json') '[]'
        Invoke-Manager @('-Action','register','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-ThreadId','thread-1','-Role','analyst','-Objective','analyze') | Should Be 0
        $workflow = Get-Content (Join-Path $state 'workflow.json') -Raw | ConvertFrom-Json
        $workflow.state_version | Should Be 19
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
        (Get-Content (Join-Path $state 'workflow.json') -Raw|ConvertFrom-Json).state_version | Should Be 19
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
        Get-ReconcileDecision $project 'ANALYSIS-001' | Should Be 'begin_dispatch_send'
        $dispatchId = (Get-Task $project 'ANALYSIS-001').dispatch_id
        $receipt = Join-Path $project 'send-receipt.json'; Set-Content $receipt '{"sent":true}'
        $externalActionId=Complete-ExternalAction $project 'ANALYSIS-001' 'dispatch_send' $receipt 'sent-1' 'cursor-1'
        Invoke-Manager @('-Action','record-sent','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ReceiptPath',$receipt,'-MessageId','sent-1','-Cursor','cursor-1','-ExternalActionId',$externalActionId) | Should Be 0
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
        $externalActionId=Complete-ExternalAction $project 'ANALYSIS-001' 'dispatch_send' $receipt $null 'cursor-1'
        Invoke-Manager @('-Action','record-sent','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ReceiptPath',$receipt,'-MessageId','forged-message','-Cursor','cursor-1','-ExternalActionId',$externalActionId) | Should Be 1
        Invoke-Manager @('-Action','record-sent','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ReceiptPath',$receipt,'-Cursor','forged-cursor','-ExternalActionId',$externalActionId) | Should Be 1
        Invoke-Manager @('-Action','record-sent','-ProjectPath',$project,'-TaskId','ANALYSIS-001','-DispatchId',$dispatchId,'-ReceiptPath',$receipt,'-Cursor','cursor-1','-ExternalActionId',$externalActionId) | Should Be 0
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
