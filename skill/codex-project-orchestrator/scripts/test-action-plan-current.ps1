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
if([IO.Path]::GetFullPath([string]$plan.project_path) -ne $resolvedProject){throw 'Action plan project does not match.'}
if($plan.workflow_id -ne $workflow.workflow_id){throw 'Action plan workflow does not match.'}
if([int64]$plan.based_on_event_sequence -ne [int64]$workflow.event_sequence){throw 'STALE_ACTION_PLAN: event sequence changed.'}
if($plan.workflow_state_sha256 -ne (Get-FileHash -LiteralPath $workflowPath -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'STALE_ACTION_PLAN: workflow state changed.'}
if($plan.tasks_state_sha256 -ne (Get-FileHash -LiteralPath $tasksPath -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'STALE_ACTION_PLAN: task state changed.'}
Write-Output "CURRENT: workflow=$($workflow.workflow_id); sequence=$($workflow.event_sequence)"
