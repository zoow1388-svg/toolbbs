[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('initialize','register','transition','prepare-dispatch','record-sent','record-ack','record-result','reconcile','show','audit')][string]$Action,
    [Parameter(Mandatory=$true)][string]$ProjectPath,
    [string]$WorkflowId,[string]$TaskId,[string]$ThreadId,[string]$HostId='local',
    [ValidateSet('analyst','developer','tester','reviewer')][string]$Role,
    [string]$Objective,[string]$Authorization='read-only',[string]$BaseRevision='unknown',
    [string]$DependsOn='',[string]$AllowedFiles='',
    [string]$ToStatus,[string]$Reason,[string]$RawResultPath,[string]$NormalizedResultPath,[switch]$Verified,
    [string]$DispatchId,[string]$MessageId,[string]$ResultMessageId,[string]$Cursor
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'workflow-state.psm1') -Force

switch ($Action) {
    'initialize' { if (-not $WorkflowId) { throw 'WorkflowId is required.' }; Initialize-WorkflowState -ProjectPath $ProjectPath -WorkflowId $WorkflowId }
    'register' {
        if (-not $TaskId -or -not $ThreadId -or -not $Role -or -not $Objective) { throw 'TaskId, ThreadId, Role, and Objective are required.' }
        $dependencyList = @($DependsOn -split ',' | Where-Object { $_ } | ForEach-Object { $_.Trim() })
        $fileList = @($AllowedFiles -split ',' | Where-Object { $_ } | ForEach-Object { $_.Trim() })
        Register-WorkflowTask -ProjectPath $ProjectPath -TaskId $TaskId -ThreadId $ThreadId -HostId $HostId -Role $Role -Objective $Objective -Authorization $Authorization -BaseRevision $BaseRevision -DependsOn $dependencyList -AllowedFiles $fileList
    }
    'transition' { if (-not $TaskId -or -not $ToStatus -or -not $Reason) { throw 'TaskId, ToStatus, and Reason are required.' }; Set-WorkflowTaskState -ProjectPath $ProjectPath -TaskId $TaskId -ToStatus $ToStatus -Reason $Reason -RawResultPath $RawResultPath -NormalizedResultPath $NormalizedResultPath -Verified:$Verified }
    'prepare-dispatch' { if (-not $TaskId) { throw 'TaskId is required.' }; New-WorkflowDispatch -ProjectPath $ProjectPath -TaskId $TaskId | ConvertTo-Json -Depth 20 }
    'record-sent' { if (-not $TaskId -or -not $DispatchId -or -not $MessageId) { throw 'TaskId, DispatchId, and MessageId are required.' }; Confirm-WorkflowDispatchSent -ProjectPath $ProjectPath -TaskId $TaskId -DispatchId $DispatchId -MessageId $MessageId -Cursor $Cursor }
    'record-ack' { if (-not $TaskId -or -not $DispatchId) { throw 'TaskId and DispatchId are required.' }; Confirm-WorkflowAcknowledged -ProjectPath $ProjectPath -TaskId $TaskId -DispatchId $DispatchId -Cursor $Cursor }
    'record-result' { if (-not $TaskId -or -not $DispatchId -or -not $ThreadId -or -not $ResultMessageId -or -not $RawResultPath) { throw 'TaskId, DispatchId, ThreadId, ResultMessageId, and RawResultPath are required.' }; Receive-WorkflowResult -ProjectPath $ProjectPath -TaskId $TaskId -DispatchId $DispatchId -ThreadId $ThreadId -ResultMessageId $ResultMessageId -Cursor $Cursor -RawResultPath $RawResultPath }
    'reconcile' { if (-not $TaskId) { throw 'TaskId is required.' }; Get-WorkflowReconciliation -ProjectPath $ProjectPath -TaskId $TaskId | ConvertTo-Json -Depth 20 }
    'show' { Get-WorkflowState -ProjectPath $ProjectPath | ConvertTo-Json -Depth 20 }
    'audit' { if (-not (Test-WorkflowStateIntegrity -ProjectPath $ProjectPath)) { throw 'Integrity audit failed.' } }
}

Write-Output "OK: $Action"
