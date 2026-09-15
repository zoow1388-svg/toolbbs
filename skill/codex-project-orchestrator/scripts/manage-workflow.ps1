[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('initialize','configure-controller','takeover-controller','register','transition','prepare-dispatch','claim-action','renew-action','complete-action','fail-action','begin-external-action','complete-external-action','cancel-external-action','record-sent','record-observation','record-wait','record-ack','record-callback','record-callback-ack','record-result','verify-result','reconcile','show','audit')][string]$Action,
    [Parameter(Mandatory=$true)][string]$ProjectPath,
    [string]$WorkflowId,[string]$TaskId,[string]$ThreadId,[string]$HostId='local',[string]$ControllerThreadId,[string]$ControllerHostId='local',[string]$ExpectedControllerThreadId,[string]$ExpectedControllerHostId='local',[int64]$ExpectedControllerEpoch,[string]$TakeoverReason,
    [ValidateSet('analyst','developer','tester','reviewer')][string]$Role,
    [string]$Objective,[string]$Authorization='read-only',[string]$BaseRevision='unknown',
    [string]$DependsOn='',[string]$AllowedFiles='',[string]$RepairOf,
    [string]$ToStatus,[string]$Reason,[string]$RawResultPath,[string]$NormalizedResultPath,[switch]$Verified,
    [string]$DispatchId,[string]$CallbackEventId,[string]$MessageId,[string]$ResultMessageId,[string]$Cursor,[string]$ReceiptPath,
    [string]$ObservedProjectPath,[string]$ObservedStatus,[string]$ObservationPath,[string]$SnapshotPath,
    [ValidateSet('dispatch_send','callback_ack')][string]$ExternalActionType,[string]$ExternalActionId,[string]$EvidencePath,
    [string]$PlanPath,[string]$ActionId,[string]$ExecutionId,[int]$LeaseSeconds=300,[string]$ErrorMessage
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'workflow-state.psm1') -Force -DisableNameChecking

switch ($Action) {
    'initialize' { if (-not $WorkflowId) { throw 'WorkflowId is required.' }; Initialize-WorkflowState -ProjectPath $ProjectPath -WorkflowId $WorkflowId -ControllerThreadId $ControllerThreadId -ControllerHostId $ControllerHostId }
    'configure-controller' { if(-not $ControllerThreadId){throw 'ControllerThreadId is required.'};Set-WorkflowController -ProjectPath $ProjectPath -ControllerThreadId $ControllerThreadId -ControllerHostId $ControllerHostId }
    'takeover-controller' { if(-not $ControllerThreadId -or -not $ExpectedControllerThreadId -or -not $TakeoverReason){throw 'ControllerThreadId, ExpectedControllerThreadId, and TakeoverReason are required.'};Set-WorkflowControllerTakeover -ProjectPath $ProjectPath -ExpectedControllerThreadId $ExpectedControllerThreadId -ExpectedControllerHostId $ExpectedControllerHostId -ExpectedControllerEpoch $ExpectedControllerEpoch -ControllerThreadId $ControllerThreadId -ControllerHostId $ControllerHostId -Reason $TakeoverReason }
    'register' {
        if (-not $TaskId -or -not $ThreadId -or -not $Role -or -not $Objective) { throw 'TaskId, ThreadId, Role, and Objective are required.' }
        $dependencyList = @($DependsOn -split ',' | Where-Object { $_ } | ForEach-Object { $_.Trim() })
        $fileList = @($AllowedFiles -split ',' | Where-Object { $_ } | ForEach-Object { $_.Trim() })
        Register-WorkflowTask -ProjectPath $ProjectPath -TaskId $TaskId -ThreadId $ThreadId -HostId $HostId -Role $Role -Objective $Objective -Authorization $Authorization -BaseRevision $BaseRevision -DependsOn $dependencyList -AllowedFiles $fileList -RepairOf $RepairOf
    }
    'transition' { if (-not $TaskId -or -not $ToStatus -or -not $Reason) { throw 'TaskId, ToStatus, and Reason are required.' }; if ($Verified -or $RawResultPath -or $NormalizedResultPath) { throw 'Result evidence cannot be trusted through transition; use verify-result first.' }; Set-WorkflowTaskState -ProjectPath $ProjectPath -TaskId $TaskId -ToStatus $ToStatus -Reason $Reason }
    'prepare-dispatch' { if (-not $TaskId) { throw 'TaskId is required.' }; New-WorkflowDispatch -ProjectPath $ProjectPath -TaskId $TaskId | ConvertTo-Json -Depth 20 }
    'claim-action' { if(-not $PlanPath -or -not $ActionId){throw 'PlanPath and ActionId are required.'};Claim-WorkflowAction -ProjectPath $ProjectPath -PlanPath $PlanPath -ActionId $ActionId -ExpectedControllerEpoch $ExpectedControllerEpoch -LeaseSeconds $LeaseSeconds|ConvertTo-Json -Depth 20 }
    'renew-action' { if(-not $ExecutionId){throw 'ExecutionId is required.'};Renew-WorkflowActionLease -ProjectPath $ProjectPath -ExecutionId $ExecutionId -LeaseSeconds $LeaseSeconds|ConvertTo-Json -Depth 20 }
    'complete-action' { if(-not $ExecutionId -or -not $EvidencePath){throw 'ExecutionId and EvidencePath are required.'};Set-WorkflowActionExecutionResult -ProjectPath $ProjectPath -ExecutionId $ExecutionId -Status completed -EvidencePath $EvidencePath|ConvertTo-Json -Depth 20 }
    'fail-action' { if(-not $ExecutionId -or -not $EvidencePath -or -not $ErrorMessage){throw 'ExecutionId, EvidencePath, and ErrorMessage are required.'};Set-WorkflowActionExecutionResult -ProjectPath $ProjectPath -ExecutionId $ExecutionId -Status failed -EvidencePath $EvidencePath -ErrorMessage $ErrorMessage|ConvertTo-Json -Depth 20 }
    'begin-external-action' { if(-not $TaskId -or -not $ExternalActionType){throw 'TaskId and ExternalActionType are required.'};Start-WorkflowExternalAction -ProjectPath $ProjectPath -TaskId $TaskId -ActionType $ExternalActionType -ExpectedControllerEpoch $ExpectedControllerEpoch|ConvertTo-Json -Depth 20 }
    'complete-external-action' { if(-not $ExternalActionId -or -not $ReceiptPath){throw 'ExternalActionId and ReceiptPath are required.'};Complete-WorkflowExternalAction -ProjectPath $ProjectPath -ActionId $ExternalActionId -ReceiptPath $ReceiptPath -MessageId $MessageId -Cursor $Cursor -EvidencePath $EvidencePath|ConvertTo-Json -Depth 20 }
    'cancel-external-action' { if(-not $ExternalActionId -or -not $EvidencePath){throw 'ExternalActionId and EvidencePath are required.'};Cancel-WorkflowExternalAction -ProjectPath $ProjectPath -ActionId $ExternalActionId -EvidencePath $EvidencePath|ConvertTo-Json -Depth 20 }
    'record-sent' { if (-not $TaskId -or -not $DispatchId -or -not $ReceiptPath -or -not $ExternalActionId) { throw 'TaskId, DispatchId, ReceiptPath, and ExternalActionId are required.' }; Confirm-WorkflowDispatchSent -ProjectPath $ProjectPath -TaskId $TaskId -DispatchId $DispatchId -ReceiptPath $ReceiptPath -MessageId $MessageId -Cursor $Cursor -ExternalActionId $ExternalActionId }
    'record-observation' { if (-not $TaskId -or -not $ThreadId -or -not $HostId -or -not $ObservedProjectPath -or -not $ObservedStatus -or -not $ObservationPath) { throw 'TaskId, ThreadId, HostId, ObservedProjectPath, ObservedStatus, and ObservationPath are required.' }; Record-WorkflowThreadObservation -ProjectPath $ProjectPath -TaskId $TaskId -ThreadId $ThreadId -HostId $HostId -ObservedProjectPath $ObservedProjectPath -ObservedStatus $ObservedStatus -Cursor $Cursor -ObservationPath $ObservationPath }
    'record-wait' { if (-not $TaskId -or -not $SnapshotPath) { throw 'TaskId and SnapshotPath are required.' }; Record-WorkflowWaitSnapshot -ProjectPath $ProjectPath -TaskId $TaskId -SnapshotPath $SnapshotPath }
    'record-ack' { if (-not $TaskId -or -not $DispatchId) { throw 'TaskId and DispatchId are required.' }; Confirm-WorkflowAcknowledged -ProjectPath $ProjectPath -TaskId $TaskId -DispatchId $DispatchId -Cursor $Cursor }
    'record-callback' { if(-not $TaskId -or -not $CallbackEventId -or -not $ReceiptPath){throw 'TaskId, CallbackEventId, and ReceiptPath are required.'};Receive-WorkflowCallback -ProjectPath $ProjectPath -TaskId $TaskId -CallbackEventId $CallbackEventId -ReceiptPath $ReceiptPath }
    'record-callback-ack' { if(-not $TaskId -or -not $CallbackEventId -or -not $ReceiptPath -or -not $ExternalActionId){throw 'TaskId, CallbackEventId, ReceiptPath, and ExternalActionId are required.'};Confirm-WorkflowCallbackAcknowledged -ProjectPath $ProjectPath -TaskId $TaskId -CallbackEventId $CallbackEventId -ReceiptPath $ReceiptPath -ExternalActionId $ExternalActionId }
    'record-result' { if (-not $TaskId -or -not $DispatchId -or -not $ThreadId -or -not $ResultMessageId -or -not $RawResultPath) { throw 'TaskId, DispatchId, ThreadId, ResultMessageId, and RawResultPath are required.' }; Receive-WorkflowResult -ProjectPath $ProjectPath -TaskId $TaskId -DispatchId $DispatchId -ThreadId $ThreadId -ResultMessageId $ResultMessageId -Cursor $Cursor -RawResultPath $RawResultPath }
    'verify-result' { if (-not $TaskId -or -not $NormalizedResultPath) { throw 'TaskId and NormalizedResultPath are required.' }; Confirm-WorkflowResultVerified -ProjectPath $ProjectPath -TaskId $TaskId -NormalizedResultPath $NormalizedResultPath | ConvertTo-Json -Depth 20 }
    'reconcile' { if (-not $TaskId) { throw 'TaskId is required.' }; Get-WorkflowReconciliation -ProjectPath $ProjectPath -TaskId $TaskId | ConvertTo-Json -Depth 20 }
    'show' { Get-WorkflowState -ProjectPath $ProjectPath | ConvertTo-Json -Depth 20 }
    'audit' { if (-not (Test-WorkflowStateIntegrity -ProjectPath $ProjectPath)) { throw 'Integrity audit failed.' } }
}

Write-Output "OK: $Action"
