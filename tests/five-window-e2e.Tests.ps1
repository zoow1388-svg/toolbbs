$validator=Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\verify-five-window-e2e.ps1'

function New-E2EEvidence([string]$Path){
    $base='a'*40;$commit='b'*40
    $value=[ordered]@{
        workflow_id='WF-E2E-001';repository_root='D:\e2e';controller_thread_id='controller'
        tasks=@(
            [ordered]@{task_id='ANALYSIS-001';thread_id='analysis';role='analyst';worktree_path='D:\e2e';base_revision=$base;end_revision=$base;callback_status='acknowledged';verification_status='trusted'},
            [ordered]@{task_id='DEV-001';thread_id='developer';role='developer';worktree_path='D:\wt-dev';base_revision=$base;end_revision=$commit;callback_status='acknowledged';verification_status='trusted'},
            [ordered]@{task_id='TEST-001';thread_id='tester';role='tester';worktree_path='D:\wt-test';base_revision=$commit;end_revision=$commit;callback_status='acknowledged';verification_status='trusted'},
            [ordered]@{task_id='REVIEW-001';thread_id='reviewer';role='reviewer';worktree_path='D:\wt-review';base_revision=$commit;end_revision=$commit;callback_status='acknowledged';verification_status='trusted'}
        )
        development=[ordered]@{commit=$commit;changed_files=@('src/Greeting.ps1')}
        test=[ordered]@{inspected_revision=$commit;checks=@([ordered]@{name='Pester';status='passed';exit_code=0})}
        review=[ordered]@{inspected_revision=$commit;outcome='passed';findings=@()}
        created_at=(Get-Date).ToUniversalTime().ToString('o')
    }
    [IO.File]::WriteAllText($Path,($value|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false));$value
}

Describe 'five-window E2E evidence gate' {
    BeforeEach{$path=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'.json');$evidence=New-E2EEvidence $path}
    It 'accepts one controller and four independently verified workers' { $result=& $validator -EvidencePath $path|ConvertFrom-Json;$result.valid|Should Be $true;$result.worker_count|Should Be 4 }
    It 'rejects a worker identity reused by another role' {$evidence.tasks[3].thread_id=$evidence.tasks[2].thread_id;[IO.File]::WriteAllText($path,($evidence|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false));{& $validator -EvidencePath $path}|Should Throw}
    It 'rejects tests against a revision other than the development commit' {$evidence.test.inspected_revision='c'*40;[IO.File]::WriteAllText($path,($evidence|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false));{& $validator -EvidencePath $path}|Should Throw}
    It 'rejects missing callback acknowledgement or unresolved review findings' {$evidence.tasks[0].callback_status='received';$evidence.review.findings=@('unresolved');[IO.File]::WriteAllText($path,($evidence|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false));{& $validator -EvidencePath $path}|Should Throw}
}
