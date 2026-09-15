$validator = Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\validate-result.ps1'
$renderer = Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\render-result.ps1'

function New-ResultFile([string]$Path,[string]$Project,[string]$Base,[string]$End) {
    $value = [ordered]@{
        task_id='TEST-001'; dispatch_id='TEST-001-dispatch'; thread_id='thread-1'; host_id='local'; project_path=$Project
        base_revision=$Base; end_revision=$End; summary='Readable validation result'
        preexisting_changes=@(); changed_files=@('README.md'); commands=@()
        checks=@([ordered]@{name='automated tests';status='passed'}); artifacts=@(); unexecuted=@()
        blockers=@(); risks=@(); required_authorization=$null; created_at=(Get-Date).ToUniversalTime().ToString('o')
        stage_evidence=[ordered]@{role='analyst';outcome='passed';inspected_revision=$End;criteria=@('plan_ready');findings=@()}
        normalization=[ordered]@{normalized_by='controller';source_thread_id='thread-1';source_message_id='message-1';source_format='json';decisions=@()}
    }
    [System.IO.File]::WriteAllText($Path,($value | ConvertTo-Json -Depth 10),[System.Text.UTF8Encoding]::new($false))
}

function Invoke-Script([string]$Script,[string[]]$Arguments) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>$null | Out-Null
    return $LASTEXITCODE
}

Describe 'result validation and rendering' {
    BeforeEach {
        $project = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $project | Out-Null
        & git -C $project init | Out-Null
        & git -C $project config user.name test
        & git -C $project config user.email test@example.invalid
        Set-Content (Join-Path $project 'README.md') 'baseline'
        & git -C $project add README.md
        & git -C $project commit -m baseline | Out-Null
        $head = (& git -C $project rev-parse HEAD).Trim()
        $resultPath = Join-Path $project 'result.json'
    }

    It 'validates a current result and renders readable UTF-8 Markdown' {
        New-ResultFile $resultPath $project $head $head
        Invoke-Script $validator @('-ResultPath',$resultPath,'-ProjectPath',$project) | Should Be 0
        $output = Join-Path $project 'result.md'
        Invoke-Script $renderer @('-ResultPath',$resultPath,'-OutputPath',$output,'-ProjectPath',$project) | Should Be 0
        (Get-Content $output -Raw -Encoding UTF8) | Should Match 'Readable validation result'
        (Get-Content $output -Raw -Encoding UTF8) | Should Match 'TEST-001'
    }

    It 'rejects object entries in changed_files with an actionable path' {
        New-ResultFile $resultPath $project $head $head
        $value = Get-Content $resultPath -Raw | ConvertFrom-Json
        $value.changed_files = @([pscustomobject]@{scope='this-task';files=@()})
        [System.IO.File]::WriteAllText($resultPath,($value | ConvertTo-Json -Depth 10),[System.Text.UTF8Encoding]::new($false))
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validator -ResultPath $resultPath -ProjectPath $project 2>&1
        $LASTEXITCODE | Should Be 1
        ($output -join "`n") | Should Match '\$\.changed_files\[0\]'
    }

    It 'rejects stale unavailable revisions after the repository has a HEAD' {
        New-ResultFile $resultPath $project 'unavailable' 'unavailable'
        Invoke-Script $validator @('-ResultPath',$resultPath,'-ProjectPath',$project) | Should Be 1
        $output = Join-Path $project 'result.md'
        Invoke-Script $renderer @('-ResultPath',$resultPath,'-OutputPath',$output,'-ProjectPath',$project) | Should Be 1
        Test-Path $output | Should Be $false
    }

    It 'rejects a normalized result from another dispatch round' {
        New-ResultFile $resultPath $project $head $head
        Invoke-Script $validator @('-ResultPath',$resultPath,'-ProjectPath',$project,'-ExpectedTaskId','TEST-001','-ExpectedDispatchId','another-dispatch','-ExpectedThreadId','thread-1') | Should Be 1
    }

    It 'accepts exact unborn markers for a repository without HEAD' {
        $emptyProject = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $emptyProject | Out-Null
        & git -C $emptyProject init | Out-Null
        $emptyResult = Join-Path $emptyProject 'result.json'
        New-ResultFile $emptyResult $emptyProject 'unborn' 'unborn'
        Invoke-Script $validator @('-ResultPath',$emptyResult,'-ProjectPath',$emptyProject) | Should Be 0
    }

    It 'rejects failed stage evidence and failed checks' {
        New-ResultFile $resultPath $project $head $head
        $value = Get-Content $resultPath -Raw | ConvertFrom-Json
        $value.stage_evidence.outcome = 'failed'
        $value.checks = @([pscustomobject]@{name='tests';status='failed'})
        [IO.File]::WriteAllText($resultPath,($value | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        Invoke-Script $validator @('-ResultPath',$resultPath,'-ProjectPath',$project,'-ExpectedRole','analyst') | Should Be 1
    }

    It 'rejects developer changes outside the assigned files' {
        New-ResultFile $resultPath $project $head $head
        $value = Get-Content $resultPath -Raw | ConvertFrom-Json
        $value.stage_evidence.role = 'developer'
        $value.stage_evidence.criteria = @('implementation_complete')
        $value.changed_files = @('src/outside.ps1')
        [IO.File]::WriteAllText($resultPath,($value | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        Invoke-Script $validator @('-ResultPath',$resultPath,'-ProjectPath',$project,'-ExpectedRole','developer','-AllowedFiles','src/app.ps1') | Should Be 1
    }

    It 'requires a passed check from the tester role' {
        New-ResultFile $resultPath $project $head $head
        $value = Get-Content $resultPath -Raw | ConvertFrom-Json
        $value.stage_evidence.role = 'tester'
        $value.stage_evidence.criteria = @('tests_executed')
        $value.changed_files = @()
        $value.checks = @()
        [IO.File]::WriteAllText($resultPath,($value | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        Invoke-Script $validator @('-ResultPath',$resultPath,'-ProjectPath',$project,'-ExpectedRole','tester') | Should Be 1
    }
}
