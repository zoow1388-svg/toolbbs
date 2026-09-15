Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Get-FileSha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
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
    $actions=[Collections.Generic.List[object]]::new();$waitTargets=[Collections.Generic.List[object]]::new()
    $sequence=[int64]$workflow.event_sequence

    function Add-Action([string]$Type,[object[]]$TaskIds,[string]$Operation,$Parameters,[string[]]$Evidence,[bool]$StateChanging,$Authorization,[string]$Reason){
        $key=$(if($TaskIds.Count -eq 0){'workflow'}else{($TaskIds -join '+')})
        $actions.Add([pscustomobject][ordered]@{
            action_id="$($workflow.workflow_id):$sequence`:$Type`:$key";type=$Type;task_ids=@($TaskIds)
            based_on_event_sequence=$sequence;operation=$Operation;parameters=$Parameters;evidence_required=@($Evidence)
            state_changing=$StateChanging;authorization_required=$Authorization;reason=$Reason
        })
    }

    $roleOrder=@{analyst=0;developer=1;tester=2;reviewer=3}
    $orderedTasks=@($tasks|Sort-Object @{Expression={$roleOrder[[string]$_.role]}},task_id)
    foreach($task in $orderedTasks){
        if($task.callback_status -eq 'received'){
            $ackBody=[ordered]@{type='callback_ack';event_id=$task.callback_event_id;workflow_id=$workflow.workflow_id;task_id=$task.task_id;dispatch_id=$task.dispatch_id;acknowledged_by_thread_id=$workflow.controller_thread_id;status='acknowledged'}|ConvertTo-Json -Compress
            Add-Action 'send_callback_ack' @($task.task_id) 'send_message_to_thread' ([ordered]@{threadId=$task.thread_id;hostId=$task.host_id;callback_event_id=$task.callback_event_id;prompt=$ackBody}) @('raw send receipt','callback event ID') $true $null 'A received completion callback must be acknowledged exactly once before further processing.'
            continue
        }
        if($task.status -in @('blocked','failed','cancelled','stale')){
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
            Add-Action 'send_message' @($task.task_id) 'send_message_to_thread' ([ordered]@{threadId=$task.thread_id;hostId=$task.host_id;dispatch_path=$task.dispatch_path}) @('raw send receipt','optional host message ID','cursor') $true $null 'Prepared dispatch is ready for its assigned task.'
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
                    Add-Action 'wait_callback' @($task.task_id) 'yield_controller' ([ordered]@{callback_event_id=$task.callback_event_id;controller_thread_id=$workflow.controller_thread_id}) @('matching completion callback') $false $null 'Verified result cannot complete until the worker callback is received and acknowledged.'
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
        schema_version=1;workflow_id=$workflow.workflow_id;project_path=$resolvedProject;based_on_event_sequence=$sequence
        workflow_state_sha256=(Get-FileSha256 $workflowPath);tasks_state_sha256=(Get-FileSha256 $tasksPath)
        generated_at=(Get-Date).ToUniversalTime().ToString('o');actions=@($actions)
    }
}

Export-ModuleMember -Function New-WorkflowActionPlan
