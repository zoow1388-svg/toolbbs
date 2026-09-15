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
    $actions=[Collections.Generic.List[object]]::new();$waitTargets=[Collections.Generic.List[object]]::new()
    $sequence=[int64]$workflow.event_sequence

    function Add-Action([string]$Type,[object[]]$TaskIds,[string]$Operation,$Parameters,[string[]]$Evidence,[bool]$StateChanging,$Authorization,[string]$Reason){
        $key=$(if($TaskIds.Count -eq 0){'workflow'}else{($TaskIds -join '+')})
        $operationHash=Get-ValueSha256 ([ordered]@{type=$Type;task_ids=@($TaskIds);operation=$Operation;parameters=$Parameters})
        $unresolved=@($actionExecutions|Where-Object{$_.operation_sha256 -eq $operationHash -and $_.status -in @('claimed','failed')}|Sort-Object claimed_at)
        if($unresolved.Count){
            $checkpoint=$unresolved[-1];$checkpointType=$(if($checkpoint.status -eq 'claimed'){'inspect_action_execution'}else{'manual_review'})
            $actions.Add([pscustomobject][ordered]@{action_id="$($checkpoint.action_id):checkpoint";type=$checkpointType;task_ids=@($TaskIds);based_on_event_sequence=$sequence;operation='inspect_action_execution';parameters=[ordered]@{execution_id=$checkpoint.execution_id;status=$checkpoint.status;lease_expires_at=$checkpoint.lease_expires_at};operation_sha256=$operationHash;evidence_required=@('action execution checkpoint','operation evidence');state_changing=$false;authorization_required='explicit-user-direction';reason='An earlier execution of this logical action is unresolved; do not execute it again.'})
            return
        }
        $actions.Add([pscustomobject][ordered]@{
            action_id="$($workflow.workflow_id):$($workflow.controller_epoch):$sequence`:$Type`:$key";type=$Type;task_ids=@($TaskIds)
            based_on_event_sequence=$sequence;operation=$Operation;parameters=$Parameters;evidence_required=@($Evidence)
            operation_sha256=$operationHash;state_changing=$StateChanging;authorization_required=$Authorization;reason=$Reason
        })
    }

    $roleOrder=@{analyst=0;developer=1;tester=2;reviewer=3}
    $orderedTasks=@($tasks|Sort-Object @{Expression={$roleOrder[[string]$_.role]}},task_id)
    foreach($task in $orderedTasks){
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
        schema_version=4;workflow_id=$workflow.workflow_id;project_path=$resolvedProject;controller_thread_id=$workflow.controller_thread_id;controller_host_id=$workflow.controller_host_id;controller_epoch=[int64]$workflow.controller_epoch;based_on_event_sequence=$sequence
        workflow_state_sha256=(Get-FileSha256 $workflowPath);tasks_state_sha256=(Get-FileSha256 $tasksPath);external_actions_sha256=$(if(Test-Path -LiteralPath $externalActionsPath){Get-FileSha256 $externalActionsPath}else{$null});action_executions_sha256=$(if(Test-Path -LiteralPath $actionExecutionsPath){Get-FileSha256 $actionExecutionsPath}else{$null})
        generated_at=(Get-Date).ToUniversalTime().ToString('o');actions=@($actions)
    }
}

Export-ModuleMember -Function New-WorkflowActionPlan
