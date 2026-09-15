$importer=Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\import-callback-receipt.ps1'
$fixture=Join-Path $PSScriptRoot '..\examples\native-task-responses\callback-delegation.xml'

function Invoke-Importer([string[]]$Arguments){
    $output=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $importer @Arguments 2>$null)
    [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=$output}
}

Describe 'completion callback ingestion' {
    It 'extracts one exact callback from a Codex delegation wrapper' {
        $output=Join-Path $TestDrive 'callback.json'
        $arguments=@('-RawMessagePath',$fixture,'-ExpectedEventId','ANALYSIS-001-exampledispatch:completion','-ExpectedWorkflowId','WF-EXAMPLE-001','-ExpectedTaskId','ANALYSIS-001','-ExpectedDispatchId','ANALYSIS-001-exampledispatch','-ExpectedSourceThreadId','worker-thread','-ExpectedSourceHostId','local','-ExpectedTargetThreadId','controller-thread','-ExpectedTargetHostId','local','-OutputPath',$output)
        (Invoke-Importer $arguments).ExitCode|Should Be 0
        $receipt=Get-Content $output -Raw -Encoding UTF8|ConvertFrom-Json;$receipt.status|Should Be 'completed';$receipt.event_id|Should Be 'ANALYSIS-001-exampledispatch:completion'
        (Invoke-Importer $arguments).ExitCode|Should Be 1
    }

    It 'rejects a callback addressed to another controller' {
        $output=Join-Path $TestDrive 'wrong.json'
        $arguments=@('-RawMessagePath',$fixture,'-ExpectedEventId','ANALYSIS-001-exampledispatch:completion','-ExpectedWorkflowId','WF-EXAMPLE-001','-ExpectedTaskId','ANALYSIS-001','-ExpectedDispatchId','ANALYSIS-001-exampledispatch','-ExpectedSourceThreadId','worker-thread','-ExpectedSourceHostId','local','-ExpectedTargetThreadId','other-controller','-ExpectedTargetHostId','local','-OutputPath',$output)
        (Invoke-Importer $arguments).ExitCode|Should Be 1
        Test-Path $output|Should Be $false
    }
}
