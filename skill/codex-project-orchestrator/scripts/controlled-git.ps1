[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RequestPath,
    [Parameter(Mandatory=$true)][string]$ReceiptPath,
    [string]$ExpectedRequestSha256
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param([string]$WorkingDirectory,[string[]]$Arguments,[switch]$AllowFailure)
    $oldPreference=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';$output=@(& git -C $WorkingDirectory @Arguments 2>&1);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$oldPreference}
    if (-not $AllowFailure -and $code -ne 0) { throw "git $($Arguments -join ' ') failed ($code): $($output -join ' ')" }
    [pscustomobject]@{ exit_code=$code; output=@($output) }
}

function Get-Head([string]$Path) { ([string]@((Invoke-Git $Path @('rev-parse','HEAD')).output)[-1]).Trim() }
function Get-Branch([string]$Path) {
    $result=Invoke-Git $Path @('symbolic-ref','--quiet','--short','HEAD') -AllowFailure
    if($result.exit_code -ne 0){return $null};([string]@($result.output)[-1]).Trim()
}
function Get-ChangedFiles([string]$Path) {
    $lines=@((Invoke-Git $Path @('status','--porcelain=v1','--untracked-files=all')).output)
    @($lines|Where-Object{$_}|ForEach-Object{([string]$_).Substring(3).Trim()}|ForEach-Object{if($_ -match ' -> '){($_ -split ' -> ')[-1]}else{$_}}|Sort-Object -Unique)
}
function Assert-Allowed([string[]]$Files,[string[]]$Allowed) {
    $invalid=@($Files|Where-Object{$_ -notin $Allowed})
    if($invalid.Count){throw "Changed files exceed authorization: $($invalid -join ', ')"}
}
function Assert-Evidence($Evidence,[string]$Role,[string]$Revision) {
    if($null -eq $Evidence -or $Evidence.role -ne $Role -or $Evidence.verification_status -ne 'trusted' -or $Evidence.outcome -ne 'passed' -or $Evidence.inspected_revision -ne $Revision){throw "$Role evidence does not trust the source revision."}
    $path=[IO.Path]::GetFullPath([string]$Evidence.receipt_path)
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "$Role evidence receipt not found."}
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if($hash -ne $Evidence.receipt_sha256){throw "$Role evidence receipt hash mismatch."}
    $hash
}

$requestFile=[IO.Path]::GetFullPath($RequestPath)
$receiptFile=[IO.Path]::GetFullPath($ReceiptPath)
if(-not(Test-Path -LiteralPath $requestFile -PathType Leaf)){throw 'Git operation request not found.'}
if(Test-Path -LiteralPath $receiptFile){throw 'Git operation receipt already exists; refusing replay.'}
if(-not[string]::IsNullOrWhiteSpace($ExpectedRequestSha256) -and (Get-FileHash -LiteralPath $requestFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExpectedRequestSha256){throw 'Git operation request hash changed after journaling.'}
$request=Get-Content -LiteralPath $requestFile -Raw -Encoding UTF8|ConvertFrom-Json
foreach($name in @('operation_id','operation','authorization','repository_root','worktree_path','base_revision','branch_name','allowed_files','commit_message','target_branch','test_evidence','review_evidence','created_at')){if($request.PSObject.Properties.Match($name).Count -eq 0){throw "Git operation request missing field: $name"}}
if($request.authorization -ne 'git-approved'){throw 'Explicit git-approved authorization is required.'}
if($request.operation -notin @('create_worktree','stage','commit','merge')){throw 'Unsupported controlled Git operation.'}
$repository=[IO.Path]::GetFullPath([string]$request.repository_root)
$worktree=[IO.Path]::GetFullPath([string]$request.worktree_path)
if(-not(Test-Path -LiteralPath $repository -PathType Container)){throw 'Repository root not found.'}
$repoTop=([string]@((Invoke-Git $repository @('rev-parse','--show-toplevel')).output)[-1]).Trim().Replace('/','\')
if([IO.Path]::GetFullPath($repoTop) -ne $repository){throw 'repository_root is not the Git top level.'}
$resolvedBase=([string]@((Invoke-Git $repository @('rev-parse',"$($request.base_revision)^{commit}")).output)[-1]).Trim()
if($resolvedBase -ne $request.base_revision){throw 'Base revision is not immutable or does not resolve exactly.'}
$allowed=@($request.allowed_files|ForEach-Object{([string]$_).Replace('\','/').TrimStart('/')})
$testHash=$null;$reviewHash=$null;$changed=@();$endRevision=$request.base_revision

switch([string]$request.operation){
    'create_worktree' {
        if(-not([string]$request.branch_name).StartsWith('codex/')){throw 'Controlled branches must use the codex/ prefix.'}
        if($worktree-eq$repository-or$worktree.StartsWith("$repository\",[StringComparison]::OrdinalIgnoreCase)){throw 'Worktree path cannot be the repository root or a directory inside it.'}
        if(Test-Path -LiteralPath $worktree){throw 'Worktree path already exists.'}
        if((Invoke-Git $repository @('show-ref','--verify','--quiet',"refs/heads/$($request.branch_name)") -AllowFailure).exit_code -eq 0){throw 'Branch already exists.'}
        if(Get-ChangedFiles $repository){throw 'Repository root is dirty; refusing worktree creation.'}
        $worktreeParent=Split-Path -Parent $worktree;if(-not(Test-Path -LiteralPath $worktreeParent)){[void](New-Item -ItemType Directory -Path $worktreeParent -Force)}
        [void](Invoke-Git $repository @('worktree','add','-b',[string]$request.branch_name,$worktree,[string]$request.base_revision))
        if((Get-Head $worktree) -ne $request.base_revision -or (Get-Branch $worktree) -ne $request.branch_name -or (Get-ChangedFiles $worktree)){throw 'Created worktree identity verification failed.'}
    }
    'stage' {
        if(-not(Test-Path -LiteralPath $worktree -PathType Container)){throw 'Worktree not found.'}
        if((Get-Head $worktree) -ne $request.base_revision){throw 'Worktree baseline changed before staging.'}
        if((Get-Branch $worktree) -ne $request.branch_name){throw 'Worktree branch changed before staging.'}
        $changed=@(Get-ChangedFiles $worktree);if(-not $changed.Count){throw 'No changes to stage.'};Assert-Allowed $changed $allowed
        [void](Invoke-Git $worktree (@('add','--')+$changed))
        $staged=@((Invoke-Git $worktree @('diff','--cached','--name-only')).output|Where-Object{$_}|ForEach-Object{([string]$_).Replace('\','/')});Assert-Allowed $staged $allowed
        $unstaged=@((Invoke-Git $worktree @('diff','--name-only')).output|Where-Object{$_})
        if($unstaged.Count){throw 'Unstaged changes remain after controlled staging.'}
        $changed=$staged
    }
    'commit' {
        if([string]::IsNullOrWhiteSpace([string]$request.commit_message)){throw 'Commit message is required.'}
        if((Get-Head $worktree) -ne $request.base_revision){throw 'Worktree baseline changed before commit.'}
        if((Get-Branch $worktree) -ne $request.branch_name){throw 'Worktree branch changed before commit.'}
        $all=@(Get-ChangedFiles $worktree);Assert-Allowed $all $allowed
        $staged=@((Invoke-Git $worktree @('diff','--cached','--name-only')).output|Where-Object{$_}|ForEach-Object{([string]$_).Replace('\','/')});if(-not $staged.Count){throw 'No staged changes to commit.'};Assert-Allowed $staged $allowed
        $unstaged=@((Invoke-Git $worktree @('diff','--name-only')).output|Where-Object{$_})
        if($unstaged.Count){throw 'Unstaged changes block controlled commit.'}
        [void](Invoke-Git $worktree @('commit','-m',[string]$request.commit_message));$endRevision=Get-Head $worktree;$changed=$staged
        if($endRevision -eq $request.base_revision -or (Get-ChangedFiles $worktree)){throw 'Controlled commit verification failed.'}
    }
    'merge' {
        if([string]::IsNullOrWhiteSpace([string]$request.target_branch)){throw 'Target branch is required for merge.'}
        if((Get-Branch $repository) -ne $request.target_branch){throw 'Repository root is not on the requested target branch.'}
        if((Get-Head $repository) -ne $request.base_revision){throw 'Target branch baseline changed before merge.'}
        if(Get-ChangedFiles $repository){throw 'Target worktree is dirty; refusing merge.'}
        $source=([string]@((Invoke-Git $repository @('rev-parse',"$($request.branch_name)^{commit}")).output)[-1]).Trim()
        $sourceChanges=@((Invoke-Git $repository @('diff','--name-only',"$($request.base_revision)..$source")).output|Where-Object{$_}|ForEach-Object{([string]$_).Replace('\','/')})
        if(-not $sourceChanges.Count){throw 'Source branch has no changes to merge.'};Assert-Allowed $sourceChanges $allowed
        $testHash=Assert-Evidence $request.test_evidence 'tester' $source;$reviewHash=Assert-Evidence $request.review_evidence 'reviewer' $source
        $preflight=Invoke-Git $repository @('merge-tree','--write-tree',$request.base_revision,$source) -AllowFailure
        if($preflight.exit_code -ne 0){throw "Merge conflict detected; no merge attempted: $($preflight.output -join ' ')"}
        [void](Invoke-Git $repository @('merge','--no-ff','--no-edit',$source));$endRevision=Get-Head $repository
        $changed=@((Invoke-Git $repository @('diff','--name-only',"$($request.base_revision)..$endRevision")).output|Where-Object{$_}|ForEach-Object{([string]$_).Replace('\','/')})
        if((Get-ChangedFiles $repository)){throw 'Target worktree is dirty after merge.'}
    }
}

$receipt=[ordered]@{operation_id=$request.operation_id;operation=$request.operation;request_path=$requestFile;request_sha256=(Get-FileHash -LiteralPath $requestFile -Algorithm SHA256).Hash.ToLowerInvariant();repository_root=$repository;worktree_path=$worktree;branch_name=$request.branch_name;base_revision=$request.base_revision;end_revision=$endRevision;changed_files=@($changed);test_evidence_sha256=$testHash;review_evidence_sha256=$reviewHash;push_performed=$false;force_performed=$false;status='completed';completed_at=[DateTime]::UtcNow.ToString('o')}
$parent=Split-Path -Parent $receiptFile;if(-not(Test-Path -LiteralPath $parent)){[void](New-Item -ItemType Directory -Path $parent)}
[IO.File]::WriteAllText($receiptFile,($receipt|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
[pscustomobject]$receipt|ConvertTo-Json -Depth 10
