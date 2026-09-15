[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ResultPath,
    [string]$ProjectPath
)

$ErrorActionPreference = 'Stop'
$errors = [System.Collections.Generic.List[string]]::new()

function Add-ResultError([string]$Path,[string]$Message) { $errors.Add("$Path`: $Message") }
function Has-Property($Object,[string]$Name) { return $null -ne $Object -and $Object.PSObject.Properties.Match($Name).Count -gt 0 }

try { $result = Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Write-Output "INVALID: `$ - JSON 解析失败: $($_.Exception.Message)"; exit 1 }

$required = @('task_id','thread_id','host_id','project_path','base_revision','end_revision','summary','preexisting_changes','changed_files','commands','checks','artifacts','unexecuted','blockers','risks','required_authorization','created_at','normalization')
foreach ($name in $required) { if (-not (Has-Property $result $name)) { Add-ResultError "`$.$name" '缺少必填字段' } }

foreach ($name in @('preexisting_changes','changed_files','artifacts','unexecuted','blockers','risks')) {
    if (Has-Property $result $name) {
        $index = 0
        foreach ($item in @($result.$name)) {
            if ($item -isnot [string]) { Add-ResultError "`$.$name[$index]" '必须是字符串，不能是对象或数组' }
            $index++
        }
    }
}

if (Has-Property $result 'commands') {
    $index = 0
    foreach ($command in @($result.commands)) {
        foreach ($name in @('command','exit_code','result')) { if (-not (Has-Property $command $name)) { Add-ResultError "`$.commands[$index].$name" '缺少必填字段' } }
        if ((Has-Property $command 'exit_code') -and $command.exit_code -isnot [int] -and $command.exit_code -isnot [long]) { Add-ResultError "`$.commands[$index].exit_code" '必须是整数' }
        $index++
    }
}

if (Has-Property $result 'checks') {
    $index = 0
    foreach ($check in @($result.checks)) {
        foreach ($name in @('name','status')) { if (-not (Has-Property $check $name)) { Add-ResultError "`$.checks[$index].$name" '缺少必填字段' } }
        if ((Has-Property $check 'status') -and $check.status -notin @('passed','failed','not-run')) { Add-ResultError "`$.checks[$index].status" '只允许 passed、failed 或 not-run' }
        $index++
    }
}

if (Has-Property $result 'normalization') {
    foreach ($name in @('normalized_by','source_thread_id','source_message_id','source_format','decisions')) { if (-not (Has-Property $result.normalization $name)) { Add-ResultError "`$.normalization.$name" '缺少必填字段' } }
    if ((Has-Property $result.normalization 'normalized_by') -and $result.normalization.normalized_by -ne 'controller') { Add-ResultError '$.normalization.normalized_by' '必须为 controller' }
}

$effectiveProject = if ([string]::IsNullOrWhiteSpace($ProjectPath)) { [string]$result.project_path } else { [System.IO.Path]::GetFullPath($ProjectPath) }
if (-not [string]::IsNullOrWhiteSpace($effectiveProject) -and (Test-Path -LiteralPath $effectiveProject)) {
    if ([System.IO.Path]::GetFullPath([string]$result.project_path) -ne [System.IO.Path]::GetFullPath($effectiveProject)) { Add-ResultError '$.project_path' '与待验证项目不一致' }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $head = & git -C $effectiveProject rev-parse --verify HEAD 2>$null
        $headExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($headExitCode -eq 0) {
        foreach ($field in @('base_revision','end_revision')) {
            $value = [string]$result.$field
            if ($value -match '^(unborn|unknown|unavailable)' -or $value -match '[（(]') { Add-ResultError "`$.$field" '仓库已有 HEAD，结果仍使用无提交占位值，报告已经过期' }
        }
        if ([string]$result.end_revision -ne [string]$head) { Add-ResultError '$.end_revision' "与当前 HEAD 不一致（当前为 $head）" }
        if ([string]$result.base_revision -notmatch '^(unborn|unknown|unavailable)') {
            try {
                $ErrorActionPreference = 'Continue'
                & git -C $effectiveProject cat-file -e "$($result.base_revision)^{commit}" 2>$null
                $baseExitCode = $LASTEXITCODE
            } finally { $ErrorActionPreference = $previousPreference }
            if ($baseExitCode -ne 0) { Add-ResultError '$.base_revision' '不是当前仓库可解析的提交' }
        }
    } else {
        if ([string]$result.base_revision -ne 'unborn' -or [string]$result.end_revision -ne 'unborn') { Add-ResultError '$.base_revision' '无 HEAD 仓库必须统一使用精确值 unborn' }
    }
}

if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Output "INVALID: $_" }; exit 1 }
Write-Output "VALID: task=$($result.task_id); revision=$($result.end_revision)"
exit 0
