[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ResultPath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [string]$ProjectPath,
    [string]$ExpectedTaskId,
    [string]$ExpectedDispatchId,
    [string]$ExpectedThreadId
)

$ErrorActionPreference = 'Stop'
$validator = Join-Path $PSScriptRoot 'validate-result.ps1'
$validation = & $validator -ResultPath $ResultPath -ProjectPath $ProjectPath -ExpectedTaskId $ExpectedTaskId -ExpectedDispatchId $ExpectedDispatchId -ExpectedThreadId $ExpectedThreadId
if ($LASTEXITCODE -ne 0) { $validation | ForEach-Object { Write-Error $_ }; exit 1 }
$result = Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Add-List([System.Collections.Generic.List[string]]$Lines,[string]$Title,$Values) {
    $Lines.Add("## $Title"); $Lines.Add('')
    $items = @($Values)
    if ($items.Count -eq 0) { $Lines.Add('- 无') } else { foreach ($item in $items) { $Lines.Add("- $item") } }
    $Lines.Add('')
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# 任务结果：$($result.task_id)"); $lines.Add('')
$lines.Add("- 状态：已规范化并通过格式与基线校验")
$lines.Add("- 项目：$($result.project_path)")
$lines.Add("- 任务窗口：$($result.thread_id)")
$lines.Add("- 派发编号：$($result.dispatch_id)")
$lines.Add("- 开始修订：$($result.base_revision)")
$lines.Add("- 结束修订：$($result.end_revision)")
$lines.Add("- 生成时间：$($result.created_at)"); $lines.Add('')
$lines.Add('## 完成摘要'); $lines.Add(''); $lines.Add([string]$result.summary); $lines.Add('')
Add-List $lines '本任务修改文件' $result.changed_files
Add-List $lines '任务开始前已有变更' $result.preexisting_changes
$lines.Add('## 检查结果'); $lines.Add('')
if (@($result.checks).Count -eq 0) { $lines.Add('- 无') } else { foreach ($check in @($result.checks)) { $label = @{ passed='通过'; failed='失败'; 'not-run'='未执行' }[[string]$check.status]; $lines.Add("- $($check.name)：$label") } }; $lines.Add('')
Add-List $lines '未执行项目' $result.unexecuted
Add-List $lines '阻塞原因' $result.blockers
Add-List $lines '剩余风险' $result.risks
$lines.Add('## 后续授权'); $lines.Add(''); $lines.Add($(if ($null -eq $result.required_authorization) { '无需新增授权。' } else { [string]$result.required_authorization })); $lines.Add('')
$directory = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))
if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory) }
[System.IO.File]::WriteAllLines([System.IO.Path]::GetFullPath($OutputPath),$lines,[System.Text.UTF8Encoding]::new($false))
Write-Output "RENDERED: $([System.IO.Path]::GetFullPath($OutputPath))"
