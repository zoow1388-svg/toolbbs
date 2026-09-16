[CmdletBinding()]
param(
    [string]$PythonCommand='python'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
$resultsDirectory=Join-Path $projectRoot 'TestResults'
$pesterResult=Join-Path $resultsDirectory 'pester-results.xml'
$summaryPath=Join-Path $resultsDirectory 'validation-summary.json'
[void](New-Item -ItemType Directory -Path $resultsDirectory -Force)
foreach($path in @($pesterResult,$summaryPath)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}}

$powershellFiles=@(
    Get-ChildItem -LiteralPath (Join-Path $projectRoot 'skill') -Recurse -File | Where-Object {$_.Extension -in @('.ps1','.psm1')}
    Get-ChildItem -LiteralPath (Join-Path $projectRoot 'installer') -Recurse -File -Filter '*.ps1'
    Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.ps1'
)
foreach($file in $powershellFiles){
    $tokens=$null;$errors=$null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)|Out-Null
    if($errors.Count){throw "PowerShell parser failed for $($file.FullName): $($errors.Message -join '; ')"}
}
Write-Output "POWERSHELL PARSER VALID: $($powershellFiles.Count) files"

& $PythonCommand (Join-Path $PSScriptRoot 'validate_schemas.py')
if($LASTEXITCODE-ne0){throw 'Schema validation failed.'}
& $PythonCommand (Join-Path $PSScriptRoot 'validate_skill.py')
if($LASTEXITCODE-ne0){throw 'Skill validation failed.'}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'invoke-pester.ps1') -TestPath $PSScriptRoot -ResultPath $pesterResult
if($LASTEXITCODE-ne0){throw 'Pester validation failed.'}

$pesterXml=[xml](Get-Content -LiteralPath $pesterResult -Raw -Encoding UTF8)
$suite=$pesterXml.'test-results'
$summary=[ordered]@{
    version=(Get-Content -LiteralPath (Join-Path $projectRoot 'skill\codex-project-orchestrator\VERSION') -Raw -Encoding UTF8).Trim()
    powershell_files=$powershellFiles.Count
    schema_positive=19
    schema_negative=2
    skill='passed'
    pester_total=[int]$suite.total
    pester_failures=[int]$suite.failures
    result='passed'
    created_at=(Get-Date).ToUniversalTime().ToString('o')
}
[IO.File]::WriteAllText($summaryPath,($summary|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
Write-Output "VALIDATION SUMMARY: $summaryPath"
