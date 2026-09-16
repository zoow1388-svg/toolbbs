$script = Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\controlled-git.ps1'

function Invoke-TestGit([string]$Path,[string[]]$Arguments) {
    $output=@(& git -C $Path @Arguments 2>&1)
    if($LASTEXITCODE -ne 0){throw "git failed: $($output -join ' ')"}
    $output
}
function New-TestRepository([string]$Path) {
    [void](New-Item -ItemType Directory -Path $Path)
    & git -C $Path init -b main | Out-Null
    & git -C $Path config user.name 'toolbbs test'
    & git -C $Path config user.email 'toolbbs@example.invalid'
    [IO.File]::WriteAllText((Join-Path $Path 'README.md'),"baseline`n",[Text.UTF8Encoding]::new($false))
    & git -C $Path add README.md
    & git -C $Path commit -m 'test: baseline' | Out-Null
    ([string]@(Invoke-TestGit $Path @('rev-parse','HEAD'))[-1]).Trim()
}
function Write-JsonFile([string]$Path,$Value) {
    [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
}
function New-Request([string]$Id,[string]$Operation,[string]$Repository,[string]$Worktree,[string]$Base,[string]$Branch,[string[]]$Allowed=@(),[string]$Message=$null,[string]$Target=$null,$TestEvidence=$null,$ReviewEvidence=$null) {
    [ordered]@{operation_id=$Id;operation=$Operation;authorization='git-approved';repository_root=$Repository;worktree_path=$Worktree;base_revision=$Base;branch_name=$Branch;allowed_files=@($Allowed);commit_message=$Message;target_branch=$Target;test_evidence=$TestEvidence;review_evidence=$ReviewEvidence;created_at=[DateTime]::UtcNow.ToString('o')}
}
function Invoke-Request([string]$Directory,$Request,[string]$Name) {
    $requestPath=Join-Path $Directory "$Name-request.json";$receiptPath=Join-Path $Directory "$Name-receipt.json"
    Write-JsonFile $requestPath $Request
    & $script -RequestPath $requestPath -ReceiptPath $receiptPath | Out-Null
    [pscustomobject]@{request=$requestPath;receipt=$receiptPath;data=$(if(Test-Path $receiptPath){Get-Content $receiptPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null})}
}
function New-GateEvidence([string]$Directory,[string]$Role,[string]$Revision) {
    $path=Join-Path $Directory "$Role-evidence.json"
    Write-JsonFile $path ([ordered]@{role=$Role;inspected_revision=$Revision;outcome='passed'})
    [pscustomobject]@{task_id="$($Role.ToUpperInvariant())-001";role=$Role;inspected_revision=$Revision;verification_status='trusted';outcome='passed';receipt_path=$path;receipt_sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}

Describe 'controlled Git automation' {
    BeforeEach {
        $root=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $repo=Join-Path $root 'repo';$worktree=Join-Path $root 'worktree';[void](New-Item -ItemType Directory -Path $root)
        $base=New-TestRepository $repo
    }
    It 'creates, stages, commits, and merges only after trusted gates' {
        (Invoke-Request $root (New-Request 'GIT-001' create_worktree $repo $worktree $base 'codex/feature') 'create').data.push_performed | Should Be $false
        [IO.File]::WriteAllText((Join-Path $worktree 'feature.txt'),"ok`n",[Text.UTF8Encoding]::new($false))
        @((Invoke-Request $root (New-Request 'GIT-002' stage $repo $worktree $base 'codex/feature' @('feature.txt')) 'stage').data.changed_files) -join ',' | Should Be 'feature.txt'
        $commit=(Invoke-Request $root (New-Request 'GIT-003' commit $repo $worktree $base 'codex/feature' @('feature.txt') 'feat: 添加测试功能') 'commit').data.end_revision
        $tester=New-GateEvidence $root tester $commit;$reviewer=New-GateEvidence $root reviewer $commit
        $merged=(Invoke-Request $root (New-Request 'GIT-004' merge $repo $repo $base 'codex/feature' @('feature.txt') $null main $tester $reviewer) 'merge').data
        $merged.end_revision | Should Not Be $base
        $merged.push_performed | Should Be $false
        $merged.force_performed | Should Be $false
        (Invoke-TestGit $repo @('rev-list','--parents','-n','1','HEAD')).Split(' ').Count | Should Be 3
    }
    It 'rejects staging an unauthorized file' {
        Invoke-Request $root (New-Request 'GIT-011' create_worktree $repo $worktree $base 'codex/scope') 'create' | Out-Null
        Set-Content -LiteralPath (Join-Path $worktree 'blocked.txt') -Value 'no'
        {Invoke-Request $root (New-Request 'GIT-012' stage $repo $worktree $base 'codex/scope' @('allowed.txt')) 'stage'} | Should Throw
    }
    It 'stops worktree creation when the repository is dirty' {
        Add-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'dirty'
        {Invoke-Request $root (New-Request 'GIT-021' create_worktree $repo $worktree $base 'codex/dirty') 'create'} | Should Throw
    }
    It 'stops staging when the baseline has changed' {
        Invoke-Request $root (New-Request 'GIT-031' create_worktree $repo $worktree $base 'codex/drift') 'create' | Out-Null
        Set-Content -LiteralPath (Join-Path $worktree 'first.txt') -Value 'first';& git -C $worktree add first.txt;& git -C $worktree commit -m 'test: drift' | Out-Null
        Set-Content -LiteralPath (Join-Path $worktree 'second.txt') -Value 'second'
        {Invoke-Request $root (New-Request 'GIT-032' stage $repo $worktree $base 'codex/drift' @('second.txt')) 'stage'} | Should Throw
    }
    It 'blocks merge when evidence is missing or tampered' {
        Invoke-Request $root (New-Request 'GIT-041' create_worktree $repo $worktree $base 'codex/evidence') 'create' | Out-Null
        Set-Content (Join-Path $worktree 'feature.txt') 'ok';& git -C $worktree add feature.txt;& git -C $worktree commit -m 'feat: evidence' | Out-Null
        $commit=([string]@(Invoke-TestGit $worktree @('rev-parse','HEAD'))[-1]).Trim();$tester=New-GateEvidence $root tester $commit;$reviewer=New-GateEvidence $root reviewer $commit
        Add-Content -LiteralPath $tester.receipt_path -Value 'tampered'
        {Invoke-Request $root (New-Request 'GIT-042' merge $repo $repo $base 'codex/evidence' @('feature.txt') $null main $tester $reviewer) 'merge'} | Should Throw
        ([string]@(Invoke-TestGit $repo @('rev-parse','HEAD'))[-1]).Trim() | Should Be $base
    }
    It 'detects a merge conflict before changing the target branch' {
        Invoke-Request $root (New-Request 'GIT-045' create_worktree $repo $worktree $base 'codex/conflict') 'create' | Out-Null
        Set-Content (Join-Path $worktree 'README.md') 'feature';& git -C $worktree add README.md;& git -C $worktree commit -m 'feat: conflicting change' | Out-Null
        $source=([string]@(Invoke-TestGit $worktree @('rev-parse','HEAD'))[-1]).Trim()
        Set-Content (Join-Path $repo 'README.md') 'main';& git -C $repo add README.md;& git -C $repo commit -m 'test: target drift' | Out-Null
        $target=([string]@(Invoke-TestGit $repo @('rev-parse','HEAD'))[-1]).Trim();$tester=New-GateEvidence $root tester $source;$reviewer=New-GateEvidence $root reviewer $source
        {Invoke-Request $root (New-Request 'GIT-046' merge $repo $repo $target 'codex/conflict' @('README.md') $null main $tester $reviewer) 'merge'} | Should Throw
        ([string]@(Invoke-TestGit $repo @('rev-parse','HEAD'))[-1]).Trim() | Should Be $target
        @(Invoke-TestGit $repo @('status','--porcelain')).Count | Should Be 0
    }
    It 'refuses to overwrite an existing receipt' {
        $request=New-Request 'GIT-051' create_worktree $repo $worktree $base 'codex/replay';$first=Invoke-Request $root $request 'replay'
        {& $script -RequestPath $first.request -ReceiptPath $first.receipt} | Should Throw
    }
}
