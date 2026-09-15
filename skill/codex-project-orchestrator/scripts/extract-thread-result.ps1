[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RawThreadPath,
    [Parameter(Mandatory=$true)][string]$ExpectedThreadId,
    [Parameter(Mandatory=$true)][string]$ExpectedTurnId,
    [Parameter(Mandatory=$true)][string]$ExpectedItemId,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference='Stop'
$response=Get-Content -LiteralPath $RawThreadPath -Raw -Encoding UTF8|ConvertFrom-Json
if($response -is [string]){$response=$response|ConvertFrom-Json}
if($response.thread.id -ne $ExpectedThreadId){throw 'Thread response does not match the expected thread.'}
$turn=@($response.turns|Where-Object{$_.id -eq $ExpectedTurnId});if($turn.Count -ne 1){throw 'Expected turn was not found exactly once.'};$turn=$turn[0]
if($turn.status -ne 'completed'){throw 'Expected turn is not completed.'}
$item=@($turn.items|Where-Object{$_.id -eq $ExpectedItemId});if($item.Count -ne 1){throw 'Expected result item was not found exactly once.'};$item=$item[0]
if($item.type -ne 'agentMessage' -or $item.phase -ne 'final_answer'){throw 'Expected item is not a final assistant message.'}
if([string]::IsNullOrWhiteSpace([string]$item.text)){throw 'Final assistant message is empty.'}
$resolved=[IO.Path]::GetFullPath($OutputPath);if(Test-Path -LiteralPath $resolved){throw 'Raw result already exists and will not be overwritten.'}
$directory=Split-Path -Parent $resolved;if(-not(Test-Path -LiteralPath $directory)){[void](New-Item -ItemType Directory -Path $directory)}
[IO.File]::WriteAllText($resolved,[string]$item.text,[Text.UTF8Encoding]::new($false))
[ordered]@{thread_id=$ExpectedThreadId;turn_id=$ExpectedTurnId;item_id=$ExpectedItemId;raw_result_path=$resolved;raw_result_sha256=(Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant();extracted_at=(Get-Date).ToUniversalTime().ToString('o')}|ConvertTo-Json -Compress
