[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$EvidencePath)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$evidence=Get-Content -LiteralPath ([IO.Path]::GetFullPath($EvidencePath)) -Raw -Encoding UTF8|ConvertFrom-Json
$required=@('workflow_id','repository_root','controller_thread_id','tasks','development','test','review','created_at')
foreach($name in $required){if($evidence.PSObject.Properties.Match($name).Count -eq 0){throw "E2E evidence missing field: $name"}}
$tasks=@($evidence.tasks|ForEach-Object{$_})
if($tasks.Count -ne 4){throw 'E2E requires exactly four worker tasks.'}
$roles=@('analyst','developer','tester','reviewer')
foreach($role in $roles){if(@($tasks|Where-Object{$_.role -eq $role}).Count -ne 1){throw "E2E requires exactly one $role task."}}
if(@($tasks|Group-Object task_id|Where-Object Count -gt 1).Count -or @($tasks|Group-Object thread_id|Where-Object Count -gt 1).Count){throw 'E2E task and thread identities must be unique.'}
if(@($tasks|Where-Object{$_.thread_id -eq $evidence.controller_thread_id}).Count){throw 'Controller cannot also be a worker.'}
if(@($tasks|Where-Object{$_.callback_status -ne 'acknowledged' -or $_.verification_status -ne 'trusted'}).Count){throw 'Every worker requires acknowledged callback and trusted verification.'}
$workspaces=@($tasks|Where-Object{$_.role -ne 'analyst'}|ForEach-Object{$_.worktree_path})
if(@($workspaces|Group-Object|Where-Object Count -gt 1).Count){throw 'Developer, tester, and reviewer worktrees must be distinct.'}
$developer=@($tasks|Where-Object role -eq 'developer')[0]
$tester=@($tasks|Where-Object role -eq 'tester')[0]
$reviewer=@($tasks|Where-Object role -eq 'reviewer')[0]
$commit=[string]$evidence.development.commit
if(@($evidence.development.changed_files).Count -lt 1 -or $developer.end_revision -ne $commit -or $developer.base_revision -eq $commit){throw 'Development must produce a new commit with changed files.'}
if($tester.base_revision -ne $commit -or $tester.end_revision -ne $commit -or $evidence.test.inspected_revision -ne $commit){throw 'Tester evidence is not bound to the development commit.'}
if(@($evidence.test.checks).Count -lt 1 -or @($evidence.test.checks|Where-Object{$_.status -ne 'passed' -or [int]$_.exit_code -ne 0}).Count){throw 'Tester must provide at least one passing command with exit code 0.'}
if($reviewer.base_revision -ne $commit -or $reviewer.end_revision -ne $commit -or $evidence.review.inspected_revision -ne $commit -or $evidence.review.outcome -ne 'passed' -or @($evidence.review.findings).Count){throw 'Reviewer must pass the exact development commit without unresolved findings.'}
[pscustomobject][ordered]@{valid=$true;workflow_id=$evidence.workflow_id;controller_thread_id=$evidence.controller_thread_id;worker_count=4;development_commit=$commit;verified_at=(Get-Date).ToUniversalTime().ToString('o')}|ConvertTo-Json
