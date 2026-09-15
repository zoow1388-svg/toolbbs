[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RawWaitPath,
    [Parameter(Mandatory=$true)][string]$ExpectedThreadId,
    [Parameter(Mandatory=$true)][string]$ExpectedHostId,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference='Stop'
function Read-ToolJson([string]$Path){
    $value=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json
    if($value -is [string]){$value=$value|ConvertFrom-Json}
    return $value
}
$raw=Read-ToolJson $RawWaitPath
$poll=@($raw.polls|Where-Object{$_.thread.id -eq $ExpectedThreadId -and $_.thread.hostId -eq $ExpectedHostId})
if($poll.Count -ne 1){throw 'Expected exactly one matching wait poll.'}
$poll=$poll[0]
if([string]::IsNullOrWhiteSpace([string]$poll.cursor)){throw 'Wait poll cursor is missing.'}
if($null -eq $poll.revision){throw 'Wait poll revision is missing.'}
$latest=$poll.latestAssistantMessage
$snapshot=[ordered]@{
    thread_id=$poll.thread.id;host_id=$poll.thread.hostId;status=$poll.thread.status.type
    cursor=$poll.cursor;revision=[int64]$poll.revision;changed=[bool]$poll.changed
    latest_turn_id=$(if($null -eq $poll.latestTurn){$null}else{$poll.latestTurn.id})
    latest_turn_status=$(if($null -eq $poll.latestTurn){$null}else{$poll.latestTurn.status})
    latest_item_id=$(if($null -eq $latest){$null}else{$latest.id})
    latest_item_phase=$(if($null -eq $latest){$null}else{$latest.phase})
    result_truncated=$(if($null -eq $latest){$false}else{[bool]$latest.truncated})
    original_chars=$(if($null -eq $latest -or $null -eq $latest.originalChars){$null}else{[int64]$latest.originalChars})
    raw_response_path=[IO.Path]::GetFullPath($RawWaitPath)
    raw_response_sha256=(Get-FileHash -LiteralPath $RawWaitPath -Algorithm SHA256).Hash.ToLowerInvariant()
    observed_at=(Get-Date).ToUniversalTime().ToString('o')
}
$resolved=[IO.Path]::GetFullPath($OutputPath);if(Test-Path -LiteralPath $resolved){throw 'Wait snapshot already exists and will not be overwritten.'}
$directory=Split-Path -Parent $resolved;if(-not(Test-Path -LiteralPath $directory)){[void](New-Item -ItemType Directory -Path $directory)}
[IO.File]::WriteAllText($resolved,($snapshot|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
Write-Output "SNAPSHOT: $resolved"
