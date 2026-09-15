[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ProjectPath,
    [string]$OutputPath
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'workflow-action-planner.psm1') -Force -DisableNameChecking
$plan=New-WorkflowActionPlan -ProjectPath $ProjectPath
$json=$plan|ConvertTo-Json -Depth 30
if([string]::IsNullOrWhiteSpace($OutputPath)){Write-Output $json;exit 0}
$resolved=[IO.Path]::GetFullPath($OutputPath)
if(Test-Path -LiteralPath $resolved){throw 'Action plan already exists and will not be overwritten.'}
$directory=Split-Path -Parent $resolved;if(-not(Test-Path -LiteralPath $directory)){[void](New-Item -ItemType Directory -Path $directory)}
[IO.File]::WriteAllText($resolved,$json,[Text.UTF8Encoding]::new($false))
Write-Output "PLAN: $resolved"
