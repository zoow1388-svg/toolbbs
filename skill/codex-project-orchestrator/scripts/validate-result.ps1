[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ResultPath,
    [string]$ProjectPath,
    [string]$ExpectedTaskId,
    [string]$ExpectedDispatchId,
    [string]$ExpectedThreadId,
    [ValidateSet('analyst','developer','tester','reviewer')][string]$ExpectedRole,
    [string]$AllowedFiles=''
)

$ErrorActionPreference = 'Stop'
$errors = [System.Collections.Generic.List[string]]::new()

function Add-ResultError([string]$Path,[string]$Message) { $errors.Add("$Path`: $Message") }
function Has-Property($Object,[string]$Name) { return $null -ne $Object -and $Object.PSObject.Properties.Match($Name).Count -gt 0 }

try { $result = Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Write-Output "INVALID: `$ - JSON 解析失败: $($_.Exception.Message)"; exit 1 }

$required = @('task_id','dispatch_id','thread_id','host_id','project_path','base_revision','end_revision','summary','preexisting_changes','changed_files','commands','checks','artifacts','unexecuted','blockers','risks','required_authorization','created_at','stage_evidence','normalization')
foreach ($name in $required) { if (-not (Has-Property $result $name)) { Add-ResultError "`$.$name" '缺少必填字段' } }
$allowedTopLevel = @($required)
foreach ($property in $result.PSObject.Properties.Name) { if ($property -notin $allowedTopLevel) { Add-ResultError "`$.$property" '不允许额外字段' } }
foreach ($name in @('task_id','dispatch_id','thread_id','host_id','project_path','base_revision','end_revision','summary','created_at')) {
    if ((Has-Property $result $name) -and ($result.$name -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$result.$name))) { Add-ResultError "`$.$name" '必须是非空字符串' }
}
if ($ExpectedTaskId -and $result.task_id -ne $ExpectedTaskId) { Add-ResultError '$.task_id' '与预期任务不一致' }
if ($ExpectedDispatchId -and $result.dispatch_id -ne $ExpectedDispatchId) { Add-ResultError '$.dispatch_id' '与预期派发不一致，结果可能来自旧轮次' }
if ($ExpectedThreadId -and $result.thread_id -ne $ExpectedThreadId) { Add-ResultError '$.thread_id' '与预期任务窗口不一致' }

foreach ($name in @('preexisting_changes','changed_files','artifacts','unexecuted','blockers','risks')) {
    if (Has-Property $result $name) {
        if ($result.$name -isnot [System.Array]) { Add-ResultError "`$.$name" '必须是数组' }
        $index = 0
        foreach ($item in @($result.$name)) {
            if ($item -isnot [string]) { Add-ResultError "`$.$name[$index]" '必须是字符串，不能是对象或数组' }
            $index++
        }
    }
}

if (Has-Property $result 'commands') {
    if ($result.commands -isnot [System.Array]) { Add-ResultError '$.commands' '必须是数组' }
    $index = 0
    foreach ($command in @($result.commands)) {
        foreach ($name in @('command','exit_code','result')) { if (-not (Has-Property $command $name)) { Add-ResultError "`$.commands[$index].$name" '缺少必填字段' } }
        foreach ($property in $command.PSObject.Properties.Name) { if ($property -notin @('command','exit_code','result')) { Add-ResultError "`$.commands[$index].$property" '不允许额外字段' } }
        foreach ($name in @('command','result')) { if ((Has-Property $command $name) -and $command.$name -isnot [string]) { Add-ResultError "`$.commands[$index].$name" '必须是字符串' } }
        if ((Has-Property $command 'exit_code') -and $command.exit_code -isnot [int] -and $command.exit_code -isnot [long]) { Add-ResultError "`$.commands[$index].exit_code" '必须是整数' }
        $index++
    }
}

if (Has-Property $result 'checks') {
    if ($result.checks -isnot [System.Array]) { Add-ResultError '$.checks' '必须是数组' }
    $index = 0
    foreach ($check in @($result.checks)) {
        foreach ($name in @('name','status')) { if (-not (Has-Property $check $name)) { Add-ResultError "`$.checks[$index].$name" '缺少必填字段' } }
        foreach ($property in $check.PSObject.Properties.Name) { if ($property -notin @('name','status')) { Add-ResultError "`$.checks[$index].$property" '不允许额外字段' } }
        if ((Has-Property $check 'name') -and $check.name -isnot [string]) { Add-ResultError "`$.checks[$index].name" '必须是字符串' }
        if ((Has-Property $check 'status') -and $check.status -notin @('passed','failed','not-run')) { Add-ResultError "`$.checks[$index].status" '只允许 passed、failed 或 not-run' }
        $index++
    }
}

if (Has-Property $result 'normalization') {
    foreach ($name in @('normalized_by','source_thread_id','source_message_id','source_format','decisions')) { if (-not (Has-Property $result.normalization $name)) { Add-ResultError "`$.normalization.$name" '缺少必填字段' } }
    foreach ($property in $result.normalization.PSObject.Properties.Name) { if ($property -notin @('normalized_by','source_thread_id','source_message_id','source_format','decisions')) { Add-ResultError "`$.normalization.$property" '不允许额外字段' } }
    if ((Has-Property $result.normalization 'normalized_by') -and $result.normalization.normalized_by -ne 'controller') { Add-ResultError '$.normalization.normalized_by' '必须为 controller' }
    if ((Has-Property $result.normalization 'source_format') -and $result.normalization.source_format -notin @('markdown','text','json')) { Add-ResultError '$.normalization.source_format' '格式不受支持' }
    if ((Has-Property $result.normalization 'decisions') -and $result.normalization.decisions -isnot [System.Array]) { Add-ResultError '$.normalization.decisions' '必须是数组' }
    $decisionIndex=0
    foreach($decision in @($result.normalization.decisions)){if($decision -isnot [string]){Add-ResultError "`$.normalization.decisions[$decisionIndex]" '必须是字符串'};$decisionIndex++}
}

if(Has-Property $result 'stage_evidence'){
    $stage=$result.stage_evidence
    foreach($name in @('role','outcome','inspected_revision','criteria','findings')){if(-not(Has-Property $stage $name)){Add-ResultError "`$.stage_evidence.$name" '缺少必填字段'}}
    foreach($property in $stage.PSObject.Properties.Name){if($property -notin @('role','outcome','inspected_revision','criteria','findings')){Add-ResultError "`$.stage_evidence.$property" '不允许额外字段'}}
    if($ExpectedRole -and $stage.role -ne $ExpectedRole){Add-ResultError '$.stage_evidence.role' '与登记任务角色不一致'}
    if($stage.outcome -ne 'passed'){Add-ResultError '$.stage_evidence.outcome' '阶段结论不是 passed，不能放行'}
    if($stage.inspected_revision -ne $result.end_revision){Add-ResultError '$.stage_evidence.inspected_revision' '必须与结果 end_revision 一致'}
    $criterionByRole=@{analyst='plan_ready';developer='implementation_complete';tester='tests_executed';reviewer='code_review_complete'}
    if($ExpectedRole -and $criterionByRole[$ExpectedRole] -notin @($stage.criteria)){Add-ResultError '$.stage_evidence.criteria' "缺少角色门槛 $($criterionByRole[$ExpectedRole])"}
    if($ExpectedRole -eq 'reviewer' -and @($stage.findings).Count -gt 0){Add-ResultError '$.stage_evidence.findings' '审查仍有未解决问题'}
}
if(@($result.blockers).Count -gt 0){Add-ResultError '$.blockers' '存在阻塞项，不能放行'}
if(@($result.checks|Where-Object{$_.status -eq 'failed'}).Count -gt 0){Add-ResultError '$.checks' '存在失败检查，不能放行'}
if($ExpectedRole -eq 'developer'){
    if(@($result.changed_files).Count -eq 0){Add-ResultError '$.changed_files' '开发任务必须报告实际修改文件'}
    $allowed=@($AllowedFiles -split ','|Where-Object{$_}|ForEach-Object{$_.Trim()})
    foreach($file in @($result.changed_files)){if($file -notin $allowed){Add-ResultError '$.changed_files' "文件超出授权范围: $file"}}
}
if($ExpectedRole -in @('tester','reviewer') -and @($result.changed_files).Count -gt 0){Add-ResultError '$.changed_files' '测试或审查任务不得修改产品文件'}
if($ExpectedRole -eq 'tester' -and @($result.checks|Where-Object{$_.status -eq 'passed'}).Count -eq 0){Add-ResultError '$.checks' '测试任务至少需要一个通过的实际检查'}

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
