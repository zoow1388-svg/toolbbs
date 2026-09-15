[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ProjectPath,
    [Parameter(Mandatory=$true)][string]$PlanPath
)
$ErrorActionPreference='Stop'
$resolvedProject=[IO.Path]::GetFullPath($ProjectPath);$state=Join-Path $resolvedProject '.codex-orchestrator'
Import-Module (Join-Path $PSScriptRoot 'workflow-state.psm1') -Force -DisableNameChecking
if(-not(Test-WorkflowStateIntegrity -ProjectPath $resolvedProject)){throw 'Workflow integrity audit failed.'}
$plan=Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8|ConvertFrom-Json
$workflowPath=Join-Path $state 'workflow.json';$tasksPath=Join-Path $state 'tasks.json'
$workflow=Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8|ConvertFrom-Json
if($plan.schema_version -ne 4 -or $plan.PSObject.Properties.Match('external_actions_sha256').Count -eq 0 -or $plan.PSObject.Properties.Match('action_executions_sha256').Count -eq 0){throw 'STALE_ACTION_PLAN: regenerate with the action execution journal.'}
if([IO.Path]::GetFullPath([string]$plan.project_path) -ne $resolvedProject){throw 'Action plan project does not match.'}
if($plan.workflow_id -ne $workflow.workflow_id){throw 'Action plan workflow does not match.'}
if([int64]$plan.controller_epoch -ne [int64]$workflow.controller_epoch -or $plan.controller_thread_id -ne $workflow.controller_thread_id -or $plan.controller_host_id -ne $workflow.controller_host_id){throw 'STALE_ACTION_PLAN: controller lease changed.'}
if([int64]$plan.based_on_event_sequence -ne [int64]$workflow.event_sequence){throw 'STALE_ACTION_PLAN: event sequence changed.'}
if($plan.workflow_state_sha256 -ne (Get-FileHash -LiteralPath $workflowPath -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'STALE_ACTION_PLAN: workflow state changed.'}
if($plan.tasks_state_sha256 -ne (Get-FileHash -LiteralPath $tasksPath -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'STALE_ACTION_PLAN: task state changed.'}
$actionsPath=Join-Path $state 'external-actions.json';$actionsHash=$(if(Test-Path -LiteralPath $actionsPath){(Get-FileHash -LiteralPath $actionsPath -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null})
if($plan.external_actions_sha256 -ne $actionsHash){throw 'STALE_ACTION_PLAN: external action journal changed.'}
$executionsPath=Join-Path $state 'action-executions.json';$executionsHash=$(if(Test-Path -LiteralPath $executionsPath){(Get-FileHash -LiteralPath $executionsPath -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null})
if($plan.action_executions_sha256 -ne $executionsHash){throw 'STALE_ACTION_PLAN: action execution journal changed.'}
Write-Output "CURRENT: workflow=$($workflow.workflow_id); sequence=$($workflow.event_sequence)"
