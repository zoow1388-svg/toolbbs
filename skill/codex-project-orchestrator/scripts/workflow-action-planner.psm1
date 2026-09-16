Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Get-FileSha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Get-ValueSha256($Value){
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 20 -Compress));$sha=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function New-WaitTarget($Task,[string]$Purpose){
    $target=[ordered]@{task_id=$Task.task_id;threadId=$Task.thread_id;hostId=$Task.host_id;purpose=$Purpose}
    if(-not [string]::IsNullOrWhiteSpace([string]$Task.read_cursor)){$target.afterCursor=$Task.read_cursor}
    [pscustomobject]$target
}

function New-WorkflowActionPlan {
    param([Parameter(Mandatory=$true)][string]$ProjectPath)
    $resolvedProject=[IO.Path]::GetFullPath($ProjectPath)
    $stateDirectory=Join-Path $resolvedProject '.codex-orchestrator'
    $stateModule=Join-Path $PSScriptRoot 'workflow-state.psm1'
    Import-Module $stateModule -Force -DisableNameChecking
    if(-not(Test-WorkflowStateIntegrity -ProjectPath $resolvedProject)){throw 'Workflow integrity audit failed.'}
    $workflowPath=Join-Path $stateDirectory 'workflow.json';$tasksPath=Join-Path $stateDirectory 'tasks.json'
    $currentState=Get-WorkflowState -ProjectPath $resolvedProject
    $workflow=$currentState.workflow
    $tasks=@($currentState.tasks)
    $externalActionsPath=Join-Path $stateDirectory 'external-actions.json'
    $externalActions=$(if(Test-Path -LiteralPath $externalActionsPath){@(Get-Content -LiteralPath $externalActionsPath -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_})}else{@()})
    $actionExecutionsPath=Join-Path $stateDirectory 'action-executions.json'
    $actionExecutions=$(if(Test-Path -LiteralPath $actionExecutionsPath){@(Get-Content -LiteralPath $actionExecutionsPath -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_})}else{@()})
    $gitActionsPath=Join-Path $stateDirectory 'git-actions.json'
    $gitActions=$(if(Test-Path -LiteralPath $gitActionsPath){@(Get-Content -LiteralPath $gitActionsPath -Raw -Encoding UTF8|ConvertFrom-Json|ForEach-Object{$_})}else{@()})
    $actions=[Collections.Generic.List[object]]::new();$waitTargets=[Collections.Generic.List[object]]::new()
    $sequence=[int64]$workflow.event_sequence

    function Add-Action([string]$Type,[object[]]$TaskIds,[string]$Operation,$Parameters,[string[]]$Evidence,[bool]$StateChanging,$Authorization,[string]$Reason){
        $key=$(if($TaskIds.Count -eq 0){'workflow'}else{($TaskIds -join '+')})
        $operationHash=Get-ValueSha256 ([ordered]@{type=$Type;task_ids=@($TaskIds);operation=$Operation;parameters=$Parameters})
        $unresolved=@($actionExecutions|Where-Object{$_.operation_sha256 -eq $operationHash -and $_.status -in @('claimed','failed')}|Sort-Object attempt)
        if($unresolved.Count){
            $checkpoint=$unresolved[-1];$expired=([DateTime]::Parse($checkpoint.lease_expires_at).ToUniversalTime() -lt [DateTime]::UtcNow);$staleLease=([int64]$checkpoint.controller_epoch -ne [int64]$workflow.controller_epoch)
            $checkpointType=$(if($checkpoint.status -eq 'failed'){'request_retry_authorization'}elseif($expired -or $staleLease){'resolve_action_execution'}else{'inspect_action_execution'})
            $actions.Add([pscustomobject][ordered]@{action_id="$($checkpoint.action_id):checkpoint";type=$checkpointType;task_ids=@($TaskIds);based_on_event_sequence=$sequence;operation=$checkpointType;parameters=[ordered]@{execution_id=$checkpoint.execution_id;status=$checkpoint.status;lease_expires_at=$checkpoint.lease_expires_at;controller_epoch=[int64]$checkpoint.controller_epoch};operation_sha256=$operationHash;evidence_required=@('action execution checkpoint','independent operation evidence');state_changing=$false;authorization_required='explicit-user-direction';reason='An earlier execution of this logical action requires evidence-based resolution before another attempt.'})
            return
        }
        $actions.Add([pscustomobject][ordered]@{
            action_id="$($workflow.workflow_id):$($workflow.controller_epoch):$sequence`:$Type`:$key";type=$Type;task_ids=@($TaskIds)
            based_on_event_sequence=$sequence;operation=$Operation;parameters=$Parameters;evidence_required=@($Evidence)
            operation_sha256=$operationHash;state_changing=$StateChanging;authorization_required=$Authorization;reason=$Reason
        })
    }

    $roleOrder=@{analyst=0;developer=1;tester=2;reviewer=3}
    foreach($gitAction in @($gitActions|Sort-Object created_at)){
        if($gitAction.status -eq 'prepared'){
            Add-Action 'controlled_git' @($gitAction.task_id) 'manage-workflow:controlled-git' ([ordered]@{git_action_id=$gitAction.git_action_id;request_path=$gitAction.request_path;request_sha256=$gitAction.request_sha256;receipt_path=(Join-Path $stateDirectory "git-receipts\$($gitAction.operation_id).json")}) @('controlled Git receipt','unchanged request hash','unchanged repository baseline') $true 'git-approved' 'A journaled Git operation is ready for deterministic execution.'
        }elseif($gitAction.status -eq 'failed'){
            Add-Action 'manual_review' @($gitAction.task_id) 'inspect_git_action' ([ordered]@{git_action_id=$gitAction.git_action_id;error=$gitAction.error}) @('Git repository inspection','failure evidence','explicit retry decision') $false 'explicit-user-direction' 'A Git operation failed and must not be retried automatically.'
        }
    }
    $orderedTasks=@($tasks|Sort-Object @{Expression={$roleOrder[[string]$_.role]}},task_id)
    foreach($task in $orderedTasks){
        if(@($gitActions|Where-Object{$_.task_id-eq$task.task_id-and$_.status-in@('prepared','failed')}).Count){continue}
        if($task.callback_status -eq 'received'){
            $attempts=@($externalActions|Where-Object{$_.task_id -eq $task.task_id -and $_.action_type -eq 'callback_ack'}|Sort-Object attempt)
            $attempt=$(if($attempts.Count){$attempts[-1]}else{$null})
            if($null -eq $attempt -or $attempt.status -eq 'cancelled'){
                Add-Action 'begin_external_action' @($task.task_id) 'manage-workflow:begin-external-action' ([ordered]@{task_id=$task.task_id;external_action_type='callback_ack';expected_controller_epoch=[int64]$workflow.controller_epoch}) @('persisted external action intent before tool call') $true $null 'Persist the callback acknowledgement intent before calling the host tool.'
            }elseif($attempt.status -eq 'prepared'){
                Add-Action 'inspect_external_action' @($task.task_id) 'inspect_task_delivery' ([ordered]@{external_action_id=$attempt.action_id;task_id=$task.task_id;action_type='callback_ack'}) @('target task observation','host tool history or recovered receipt') $false 'explicit-user-direction' 'The acknowledgement may already have been sent; never resend it automatically.'
            }elseif($attempt.status -eq 'completed'){
                Add-Action 'record_external_action' @($task.task_id) 'manage-workflow:record-callback-ack' ([ordered]@{task_id=$task.task_id;callback_event_id=$task.callback_event_id;receipt_path=$attempt.receipt_path;external_action_id=$attempt.action_id}) @('completed external action','matching receipt hash') $true $null 'Apply the completed acknowledgement receipt without another host call.'
            }
            continue
        }
        if($task.status -in @('blocked','failed','cancelled','stale')){
            if($task.status -in @('blocked','failed') -and @($tasks|Where-Object{$_.repair_of -eq $task.task_id}).Count -eq 1){continue}
            Add-Action 'manual_review' @($task.task_id) 'inspect_task' ([ordered]@{task_id=$task.task_id;status=$task.status}) @('current task state','blocking evidence') $false $null 'Terminal or exceptional state requires inspection.'
            continue
        }
        if($task.status-eq'awaiting_commit'){
            if($task.git_phase-eq'changes-ready'){$requestPath=Join-Path $stateDirectory "git-requests\$($task.task_id)-stage.json";Add-Action 'controlled_git' @($task.task_id) 'manage-workflow:prepare-git-request' ([ordered]@{task_id=$task.task_id;git_operation='stage';request_path=$requestPath;expected_controller_epoch=[int64]$workflow.controller_epoch}) @('verified development handoff','immutable stage request') $true 'git-approved' 'Authorized developer changes are ready for controlled staging.'}
            elseif($task.git_phase-eq'staged'){$requestPath=Join-Path $stateDirectory "git-requests\$($task.task_id)-commit.json";Add-Action 'controlled_git' @($task.task_id) 'manage-workflow:prepare-git-request' ([ordered]@{task_id=$task.task_id;git_operation='commit';request_path=$requestPath;expected_controller_epoch=[int64]$workflow.controller_epoch}) @('staged authorized files','immutable commit request') $true 'git-approved' 'Staged developer changes are ready for controlled commit.'}
            elseif($task.git_phase-eq'committed'){
                $pendingTargets=@($tasks|Where-Object{$_.role-in@('tester','reviewer')-and$_.status-eq'approved'-and$_.delivery_status-eq'not-prepared'-and$_.depends_on-contains$task.task_id-and$_.base_revision-ne$task.commit_revision})
                foreach($target in $pendingTargets){Add-Action 'publish_revision' @($task.task_id,$target.task_id) 'manage-workflow:publish-verification-revision' ([ordered]@{task_id=$target.task_id;developer_task_id=$task.task_id;commit_revision=$task.commit_revision}) @('controlled commit receipt','unchanged verification task scope') $true $null 'Publish the immutable developer commit to an undispatched verification task.'}
                $gates=@($tasks|Where-Object{$_.role-in@('tester','reviewer')-and$_.status-eq'completed'-and$_.verified-and$_.verification_status-eq'trusted'-and$_.depends_on-contains$task.task_id})
                if(@($gates|Where-Object{$_.role-eq'tester'}).Count-eq1-and@($gates|Where-Object{$_.role-eq'reviewer'}).Count-eq1){$requestPath=Join-Path $stateDirectory "git-requests\$($task.task_id)-merge.json";Add-Action 'controlled_git' @($task.task_id) 'manage-workflow:prepare-git-request' ([ordered]@{task_id=$task.task_id;git_operation='merge';request_path=$requestPath;expected_controller_epoch=[int64]$workflow.controller_epoch}) @('trusted tester evidence','trusted reviewer evidence','immutable merge request') $true 'git-approved' 'The exact developer commit passed both gates and is ready for an authorized controlled merge.'}
                else{Add-Action 'manual_review' @($task.task_id) 'resume_developer_result' ([ordered]@{task_id=$task.task_id;commit_revision=$task.commit_revision}) @('developer final result bound to commit') $false $null 'Controlled commit completed; testing and review must inspect this exact revision.'}
            }
            elseif($task.git_phase-eq'merged'){Add-Action 'manual_review' @($task.task_id) 'finalize_merged_development' ([ordered]@{task_id=$task.task_id;commit_revision=$task.commit_revision;merge_revision=$task.merge_revision}) @('merge receipt','trusted tester evidence','trusted reviewer evidence') $false $null 'Controlled merge completed without push; finalize workflow delivery.'}
            continue
        }
        if($task.status -eq 'completed'){
            if(-not $task.verified -or $task.verification_status -ne 'trusted'){
                Add-Action 'manual_review' @($task.task_id) 'inspect_legacy_result' ([ordered]@{task_id=$task.task_id;verification_status=$task.verification_status}) @('trusted verification receipt') $false $null 'Completed history is not trusted for dependency release.'
            }
            continue
        }
        if($task.status -in @('draft','awaiting_approval')){
            Add-Action 'request_authorization' @($task.task_id) 'request_user_authorization' ([ordered]@{task_id=$task.task_id;current_status=$task.status;requested_authorization=$task.authorization}) @('explicit user approval') $false 'explicit-user-approval' 'Task cannot advance without explicit approval.'
            continue
        }
        if($task.status -eq 'approved' -and $task.delivery_status -eq 'not-prepared'){
            if([string]::IsNullOrWhiteSpace([string]$workflow.controller_thread_id) -or [string]::IsNullOrWhiteSpace([string]$workflow.controller_host_id)){
                Add-Action 'manual_review' @($task.task_id) 'configure_controller' ([ordered]@{task_id=$task.task_id}) @('controller thread ID','controller host ID') $false 'explicit-user-direction' 'Active callback requires an immutable controller identity before dispatch.'
                continue
            }
            if($task.role-eq'developer'-and[string]::IsNullOrWhiteSpace([string]$task.worktree_path)){
                if($task.authorization-ne'git-approved'){Add-Action 'request_authorization' @($task.task_id) 'request_git_authorization' ([ordered]@{task_id=$task.task_id;requested_authorization='git-approved'}) @('explicit Git approval') $false 'git-approved' 'Automatic worktree creation requires explicit Git authorization.'}
                elseif([string]::IsNullOrWhiteSpace([string]$workflow.git_worktree_root)){Add-Action 'manual_review' @($task.task_id) 'configure_git_worktree_root' ([ordered]@{task_id=$task.task_id}) @('safe worktree root') $false 'explicit-user-direction' 'Automatic worktree creation requires a safe absolute root outside the project.'}
                else{$requestPath=Join-Path $stateDirectory "git-requests\$($task.task_id)-create-worktree.json";Add-Action 'controlled_git' @($task.task_id) 'manage-workflow:prepare-git-request' ([ordered]@{task_id=$task.task_id;request_path=$requestPath;expected_controller_epoch=[int64]$workflow.controller_epoch}) @('immutable generated request','journaled Git transaction') $true 'git-approved' 'Approved developer task requires an isolated worktree before dispatch.'}
                continue
            }
            $dependencies=@($task.depends_on|ForEach-Object{$id=$_;@($tasks|Where-Object{$_.task_id -eq $id})[0]})
            if(@($dependencies|Where-Object{$null -eq $_ -or $_.status -ne 'completed' -or -not $_.verified -or $_.verification_status -ne 'trusted'}).Count -eq 0){
                Add-Action 'prepare_dispatch' @($task.task_id) 'manage-workflow:prepare-dispatch' ([ordered]@{task_id=$task.task_id}) @('immutable dispatch envelope') $true $null 'Approved task and all dependencies are trusted complete.'
            }
            continue
        }
        if($task.status -eq 'approved' -and $task.delivery_status -eq 'prepared'){
            $attempts=@($externalActions|Where-Object{$_.task_id -eq $task.task_id -and $_.action_type -eq 'dispatch_send'}|Sort-Object attempt)
            $attempt=$(if($attempts.Count){$attempts[-1]}else{$null})
            if($null -eq $attempt -or $attempt.status -eq 'cancelled'){
                Add-Action 'begin_external_action' @($task.task_id) 'manage-workflow:begin-external-action' ([ordered]@{task_id=$task.task_id;external_action_type='dispatch_send';expected_controller_epoch=[int64]$workflow.controller_epoch}) @('persisted external action intent before tool call') $true $null 'Persist the dispatch intent before calling the host tool.'
            }elseif($attempt.status -eq 'prepared'){
                Add-Action 'inspect_external_action' @($task.task_id) 'inspect_task_delivery' ([ordered]@{external_action_id=$attempt.action_id;task_id=$task.task_id;action_type='dispatch_send'}) @('target task observation','host tool history or recovered receipt') $false 'explicit-user-direction' 'The dispatch may already have been sent; never resend it automatically.'
            }elseif($attempt.status -eq 'completed'){
                Add-Action 'record_external_action' @($task.task_id) 'manage-workflow:record-sent' ([ordered]@{task_id=$task.task_id;dispatch_id=$task.dispatch_id;receipt_path=$attempt.receipt_path;message_id=$attempt.message_id;cursor=$attempt.cursor;external_action_id=$attempt.action_id}) @('completed external action','matching receipt hash') $true $null 'Apply the completed send receipt without another host call.'
            }
            continue
        }
        if($task.status -eq 'dispatched' -and $task.delivery_status -eq 'sent'){
            $waitTargets.Add((New-WaitTarget $task 'acknowledgement'))
            continue
        }
        if($task.status -eq 'running' -and $task.delivery_status -eq 'acknowledged'){
            if($task.latest_turn_status -eq 'completed' -and $task.latest_item_phase -eq 'final_answer' -and -not [string]::IsNullOrWhiteSpace([string]$task.latest_turn_id) -and -not [string]::IsNullOrWhiteSpace([string]$task.latest_item_id)){
                Add-Action 'read_result' @($task.task_id) 'read_thread' ([ordered]@{threadId=$task.thread_id;hostId=$task.host_id;turnId=$task.latest_turn_id;itemId=$task.latest_item_id}) @('raw read_thread response','exact final result','SHA-256') $false $null 'Wait snapshot identifies a completed result item.'
            }else{
                $waitTargets.Add((New-WaitTarget $task 'result'))
            }
            continue
        }
        if($task.status -eq 'verifying' -and $task.delivery_status -eq 'result_received'){
            if($task.verified -and $task.verification_status -eq 'trusted'){
                if($task.callback_status -eq 'acknowledged'){
                    Add-Action 'complete_task' @($task.task_id) 'manage-workflow:transition' ([ordered]@{task_id=$task.task_id;to_status='completed';reason='trusted verification and callback acknowledgement passed'}) @('trusted verification receipt','callback acknowledgement receipt','successful audit') $true $null 'Trusted verification and acknowledged callback allow completion.'
                }else{
                    Add-Action 'wait_callback' @($task.task_id) 'yield_controller' ([ordered]@{callback_event_id=$task.callback_event_id;controller_thread_id=$task.callback_target_thread_id;controller_host_id=$task.callback_target_host_id}) @('matching completion callback') $false $null 'Verified result cannot complete until the worker callback is received and acknowledged.'
                }
            }else{
                $suggestedOutput=Join-Path $stateDirectory "results\$($task.task_id).json"
                Add-Action 'normalize_result' @($task.task_id) 'controller_normalization' ([ordered]@{task_id=$task.task_id;thread_id=$task.thread_id;dispatch_id=$task.dispatch_id;source_message_id=$task.result_message_id;raw_result_path=$task.raw_result_path;suggested_output=$suggestedOutput}) @('complete normalized result JSON','documented normalization decisions') $true $null 'Received raw result must be normalized before verify-result.'
                Add-Action 'verify_result' @($task.task_id) 'manage-workflow:verify-result' ([ordered]@{task_id=$task.task_id;normalized_result_path=$suggestedOutput}) @('successful deterministic validation','immutable verification receipt') $true $null 'Verify the newly normalized result before completion.'
            }
            continue
        }
        Add-Action 'manual_review' @($task.task_id) 'inspect_task' ([ordered]@{task_id=$task.task_id;status=$task.status;delivery_status=$task.delivery_status}) @('current task state','event log') $false $null 'State combination has no safe automatic action.'
    }

    for($offset=0;$offset -lt $waitTargets.Count;$offset+=8){
        $count=[Math]::Min(8,$waitTargets.Count-$offset);$batch=@($waitTargets.GetRange($offset,$count));$taskIds=@($batch|ForEach-Object{$_.task_id})
        Add-Action 'wait_tasks' $taskIds 'wait_threads' ([ordered]@{targets=$batch;timeoutMs=0}) @('raw wait_threads response','new cursors and revisions') $false $null 'Wait for acknowledgement or result without replaying delivered output.'
    }
    if($tasks.Count -eq 0){
        Add-Action 'manual_review' @() 'register_workflow_tasks' ([ordered]@{workflow_id=$workflow.workflow_id}) @('project analysis','registered task identities') $false 'explicit-user-direction' 'Workflow has no registered tasks.'
    }elseif(@($tasks|Where-Object{$_.status -ne 'completed' -or -not $_.verified -or $_.verification_status -ne 'trusted'}).Count -eq 0){
        Add-Action 'workflow_complete' @() 'report_completion' ([ordered]@{workflow_id=$workflow.workflow_id}) @('successful workflow audit','final delivery report') $false $null 'Every task is trusted complete.'
    }
    [pscustomobject][ordered]@{
        schema_version=7;workflow_id=$workflow.workflow_id;project_path=$resolvedProject;controller_thread_id=$workflow.controller_thread_id;controller_host_id=$workflow.controller_host_id;controller_epoch=[int64]$workflow.controller_epoch;based_on_event_sequence=$sequence
        workflow_state_sha256=(Get-FileSha256 $workflowPath);tasks_state_sha256=(Get-FileSha256 $tasksPath);external_actions_sha256=$(if(Test-Path -LiteralPath $externalActionsPath){Get-FileSha256 $externalActionsPath}else{$null});action_executions_sha256=$(if(Test-Path -LiteralPath $actionExecutionsPath){Get-FileSha256 $actionExecutionsPath}else{$null});git_actions_sha256=$(if(Test-Path -LiteralPath $gitActionsPath){Get-FileSha256 $gitActionsPath}else{$null})
        generated_at=(Get-Date).ToUniversalTime().ToString('o');actions=@($actions)
    }
}

Export-ModuleMember -Function New-WorkflowActionPlan
