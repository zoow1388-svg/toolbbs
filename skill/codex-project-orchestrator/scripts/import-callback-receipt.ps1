[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RawMessagePath,
    [Parameter(Mandatory=$true)][string]$ExpectedEventId,
    [Parameter(Mandatory=$true)][string]$ExpectedWorkflowId,
    [Parameter(Mandatory=$true)][string]$ExpectedTaskId,
    [Parameter(Mandatory=$true)][string]$ExpectedDispatchId,
    [Parameter(Mandatory=$true)][string]$ExpectedSourceThreadId,
    [Parameter(Mandatory=$true)][string]$ExpectedSourceHostId,
    [Parameter(Mandatory=$true)][string]$ExpectedTargetThreadId,
    [Parameter(Mandatory=$true)][string]$ExpectedTargetHostId,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference='Stop'
if(-not(Test-Path -LiteralPath $RawMessagePath)){throw 'Raw callback message file not found.'}
$raw=[IO.File]::ReadAllText([IO.Path]::GetFullPath($RawMessagePath),[Text.Encoding]::UTF8).Trim()
$jsonText=$raw
if($raw -notmatch '^\s*\{'){
    $match=[regex]::Match($raw,'<input>([\s\S]*?)</input>',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if(-not $match.Success){throw 'Callback message is neither JSON nor a codex_delegation input.'}
    $jsonText=[Net.WebUtility]::HtmlDecode($match.Groups[1].Value).Trim()
}
try{$callback=$jsonText|ConvertFrom-Json}catch{throw 'Callback input does not contain valid JSON.'}
$expected=[ordered]@{
    type='completion_callback';event_id=$ExpectedEventId;workflow_id=$ExpectedWorkflowId;task_id=$ExpectedTaskId;dispatch_id=$ExpectedDispatchId
    source_thread_id=$ExpectedSourceThreadId;source_host_id=$ExpectedSourceHostId;target_thread_id=$ExpectedTargetThreadId;target_host_id=$ExpectedTargetHostId;status='completed'
}
foreach($name in $expected.Keys){
    if($callback.PSObject.Properties.Match($name).Count -eq 0 -or [string]$callback.$name -ne [string]$expected[$name]){throw "Callback identity mismatch: $name"}
}
if(@($callback.PSObject.Properties.Name|Where-Object{$_ -notin $expected.Keys}).Count -gt 0){throw 'Callback contains unsupported fields.'}
$resolvedOutput=[IO.Path]::GetFullPath($OutputPath);if(Test-Path -LiteralPath $resolvedOutput){throw 'Callback receipt already exists and will not be overwritten.'}
$directory=Split-Path -Parent $resolvedOutput;if(-not(Test-Path -LiteralPath $directory)){[void](New-Item -ItemType Directory -Path $directory)}
[IO.File]::WriteAllText($resolvedOutput,($expected|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
Write-Output "CALLBACK_RECEIPT: $resolvedOutput"
