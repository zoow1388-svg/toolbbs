[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ProjectPath,
    [string]$TargetBranch='main'
)

$ErrorActionPreference='Stop'
$requested=[IO.Path]::GetFullPath($ProjectPath).TrimEnd('\')
$findings=New-Object System.Collections.ArrayList
function Add-Finding([string]$Code,[string]$Severity,[string]$Message){[void]$findings.Add([pscustomobject][ordered]@{code=$Code;severity=$Severity;message=$Message})}
function Invoke-GitRead([string[]]$Arguments,[switch]$AllowFailure){
    $previousPreference=$ErrorActionPreference
    try{
        $ErrorActionPreference='Continue'
        $output=@(& git -C $requested @Arguments 2>&1);$exitCode=$LASTEXITCODE
    }finally{$ErrorActionPreference=$previousPreference}
    if($exitCode-ne0-and-not$AllowFailure){throw "Git read failed: $($output-join' ')"}
    [pscustomobject]@{exit_code=$exitCode;output=@($output|ForEach-Object{[string]$_})}
}

$gitVersion=$null;$isRepository=$false;$repositoryRoot=$null;$hasCommits=$false;$head=$null;$branch=$null;$detached=$false
$statusLines=@();$worktreeCount=0;$stateExists=$false;$stateTracked=$false;$stateIgnored=$false
$identityName=$null;$identityEmail=$null;$ongoing=@();$special=@();$targetExists=$false;$requestedIsRoot=$false;$defaultWorktreeRoot=$null

if(-not(Test-Path -LiteralPath $requested -PathType Container)){Add-Finding 'project-not-found' blocker 'The project directory does not exist.'}
elseif($null-eq(Get-Command git -ErrorAction SilentlyContinue)){Add-Finding 'git-not-found' blocker 'Git is not available.'}
else{
    $versionResult=Invoke-GitRead @('--version') -AllowFailure;if($versionResult.exit_code-eq0){$gitVersion=([string]$versionResult.output[-1]).Trim()}
    $inside=Invoke-GitRead @('rev-parse','--is-inside-work-tree') -AllowFailure
    if($inside.exit_code-ne0-or([string]$inside.output[-1]).Trim()-ne'true'){Add-Finding 'not-git-repository' blocker 'The project directory is not inside a Git worktree.'}
    else{
        $isRepository=$true
        $rootResult=Invoke-GitRead @('rev-parse','--show-toplevel')
        $repositoryRoot=[IO.Path]::GetFullPath(([string]$rootResult.output[-1]).Trim()).TrimEnd('\')
        $requestedIsRoot=$requested-eq$repositoryRoot;if(-not$requestedIsRoot){Add-Finding 'project-not-repository-root' blocker 'The selected project is not the Git repository root; choose a monorepo onboarding strategy first.'}
        $headResult=Invoke-GitRead @('rev-parse','--verify','HEAD') -AllowFailure
        if($headResult.exit_code-eq0){$hasCommits=$true;$head=([string]$headResult.output[-1]).Trim().ToLowerInvariant()}else{Add-Finding 'unborn-head' blocker 'The repository has no usable initial commit.'}
        $branchResult=Invoke-GitRead @('symbolic-ref','--quiet','--short','HEAD') -AllowFailure
        if($branchResult.exit_code-eq0){$branch=([string]$branchResult.output[-1]).Trim()}else{$detached=$true;Add-Finding 'detached-head' blocker 'The repository is currently on a detached HEAD.'}
        $targetResult=Invoke-GitRead @('show-ref','--verify','--quiet',"refs/heads/$TargetBranch") -AllowFailure
        $targetExists=$targetResult.exit_code -eq 0
        if(-not$targetExists){Add-Finding 'target-branch-missing' warning "Target branch $TargetBranch does not exist; confirm the integration branch."}elseif($branch-ne$TargetBranch){Add-Finding 'target-branch-not-checked-out' warning "The current branch is not target branch $TargetBranch; recheck before integration."}
        $statusLines=@((Invoke-GitRead @('-c','core.quotepath=false','status','--porcelain=v1','--untracked-files=all')).output|Where-Object{$_})
        if($statusLines.Count){Add-Finding 'working-tree-dirty' warning 'The original project has staged, modified, or untracked content; direct integration is unsafe.'}
        $gitDirResult=Invoke-GitRead @('rev-parse','--absolute-git-dir')
        $gitDir=[IO.Path]::GetFullPath(([string]$gitDirResult.output[-1]).Trim())
        foreach($operation in @(@{name='merge';path='MERGE_HEAD'},@{name='rebase';path='rebase-merge'},@{name='rebase';path='rebase-apply'},@{name='cherry-pick';path='CHERRY_PICK_HEAD'},@{name='revert';path='REVERT_HEAD'},@{name='bisect';path='BISECT_LOG'})){if(Test-Path -LiteralPath (Join-Path $gitDir $operation.path)){$ongoing+=@($operation.name)}}
        $ongoing=@($ongoing|Sort-Object -Unique);if($ongoing.Count){Add-Finding 'git-operation-in-progress' blocker "Unfinished Git operation detected: $($ongoing-join', ')."}
        if(Test-Path -LiteralPath (Join-Path $gitDir 'index.lock')){Add-Finding 'git-index-locked' blocker 'Git index.lock exists and must not be deleted automatically.'}
        $conflictResult=Invoke-GitRead @('diff','--quiet','--diff-filter=U') -AllowFailure
        if($conflictResult.exit_code -eq 1){Add-Finding 'unresolved-conflicts' blocker 'The repository contains unresolved conflicts.'}
        $nameResult=Invoke-GitRead @('config','--get','user.name') -AllowFailure;$emailResult=Invoke-GitRead @('config','--get','user.email') -AllowFailure
        if($nameResult.exit_code-eq0){$identityName=([string]$nameResult.output[-1]).Trim()};if($emailResult.exit_code-eq0){$identityEmail=([string]$emailResult.output[-1]).Trim()}
        if([string]::IsNullOrWhiteSpace($identityName)-or[string]::IsNullOrWhiteSpace($identityEmail)){Add-Finding 'git-identity-missing' warning 'Git user.name or user.email is missing; controlled commits will fail.'}
        $worktreeCount=@((Invoke-GitRead @('worktree','list','--porcelain') -AllowFailure).output|Where-Object{$_-like'worktree *'}).Count
        $statePath=Join-Path $requested '.codex-orchestrator';$stateExists=Test-Path -LiteralPath $statePath
        $trackedResult=Invoke-GitRead @('ls-files','--error-unmatch','--','.codex-orchestrator') -AllowFailure
        $ignoredResult=Invoke-GitRead @('check-ignore','-q','--','.codex-orchestrator/') -AllowFailure
        $stateTracked=$trackedResult.exit_code -eq 0;$stateIgnored=$ignoredResult.exit_code -eq 0
        if($stateTracked){Add-Finding 'state-directory-tracked' blocker '.codex-orchestrator is tracked by Git; choose a retention or migration strategy manually.'}elseif(-not$stateIgnored){Add-Finding 'state-directory-not-ignored' warning '.codex-orchestrator is not ignored and initialization would dirty the project.'}
        if(Test-Path -LiteralPath (Join-Path $requested '.gitmodules')){$special+='submodules';Add-Finding 'submodules-detected' warning 'Git submodules require an explicit initialization and test strategy.'}
        $sparse=Invoke-GitRead @('config','--bool','core.sparseCheckout') -AllowFailure;if($sparse.exit_code-eq0-and([string]$sparse.output[-1]).Trim()-eq'true'){$special+='sparse-checkout';Add-Finding 'sparse-checkout-detected' warning 'Sparse checkout may omit files required by task worktrees.'}
        $lfs=Invoke-GitRead @('lfs','ls-files','--name-only') -AllowFailure
        $lfsFiles=@($lfs.output|Where-Object{$_})
        if($lfs.exit_code -eq 0 -and $lfsFiles.Count){$special+='git-lfs';Add-Finding 'git-lfs-detected' warning 'Git LFS requires object-integrity and download-policy checks.'}
        $defaultWorktreeRoot=[IO.Path]::GetFullPath((Join-Path (Join-Path (Split-Path -Parent $requested) '.codex-worktrees') (Split-Path -Leaf $requested)))
        if(Test-Path -LiteralPath $defaultWorktreeRoot){Add-Finding 'worktree-root-exists' warning 'The default worktree root already exists and its ownership must be verified.'}
    }
}

$observedAt=[DateTime]::UtcNow
$blockers=@($findings|Where-Object{$_.severity -eq 'blocker'}).Count
$warnings=@($findings|Where-Object{$_.severity -eq 'warning'}).Count
$classification=if($blockers){'blocked'}elseif($warnings){if($statusLines.Count-or-not$stateIgnored-or-not$targetExists-or[string]::IsNullOrWhiteSpace($identityName)-or[string]::IsNullOrWhiteSpace($identityEmail)){'isolated-only'}else{'read-only'}}else{'compatible'}
$recommendedMode=switch($classification){'compatible'{'full-integration'}'isolated-only'{'isolated-development'}'read-only'{'read-only'}default{'blocked'}}
[ordered]@{
    schema_version=1;project_path=$requested;observed_at=$observedAt.ToString('o');expires_at=$observedAt.AddMinutes(15).ToString('o');classification=$classification;recommended_mode=$recommendedMode
    repository=[ordered]@{is_git_repository=$isRepository;repository_root=$repositoryRoot;requested_path_is_root=$requestedIsRoot;git_version=$gitVersion;has_commits=$hasCommits;head_revision=$head;current_branch=$branch;is_detached=$detached;target_branch=$TargetBranch;target_branch_exists=$targetExists;status_lines=@($statusLines);ongoing_operations=@($ongoing);worktree_count=$worktreeCount;git_user_name_configured=(-not[string]::IsNullOrWhiteSpace($identityName));git_user_email_configured=(-not[string]::IsNullOrWhiteSpace($identityEmail));special_features=@($special)}
    state=[ordered]@{path=$(if($isRepository){Join-Path $requested '.codex-orchestrator'}else{$null});exists=$stateExists;tracked=$stateTracked;ignored=$stateIgnored}
    worktree=[ordered]@{default_root=$defaultWorktreeRoot;exists=$(if($defaultWorktreeRoot){Test-Path -LiteralPath $defaultWorktreeRoot}else{$false})}
    findings=@($findings);summary=[ordered]@{blockers=$blockers;warnings=$warnings}
}|ConvertTo-Json -Depth 10
