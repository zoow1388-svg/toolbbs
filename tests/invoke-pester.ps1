[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$TestPath,
    [Parameter(Mandatory=$true)][string]$ResultPath
)

$result=Invoke-Pester $TestPath -PassThru -OutputFile $ResultPath -OutputFormat NUnitXml
if($result.FailedCount-ne0){exit 1}
Write-Output "PESTER VALID: $($result.PassedCount)/$($result.TotalCount) passed"
