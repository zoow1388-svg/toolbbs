[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DispatchPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference='Stop'
$dispatch=Get-Content -LiteralPath $DispatchPath -Raw -Encoding UTF8|ConvertFrom-Json
foreach($name in @('dispatch_id','workflow_id','task_id','thread_id','host_id','role','project_path','base_revision','objective','depends_on','allowed_files','authorization','callback')){
    if($dispatch.PSObject.Properties.Match($name).Count -eq 0){throw "Dispatch missing field: $name"}
}
foreach($name in @('event_id','target_thread_id','target_host_id','status')){if($dispatch.callback.PSObject.Properties.Match($name).Count -eq 0){throw "Dispatch callback missing field: $name"}}
$resolvedOutput=[IO.Path]::GetFullPath($OutputPath)
if(Test-Path -LiteralPath $resolvedOutput){throw 'Dispatch prompt already exists and will not be overwritten.'}
$lines=[Collections.Generic.List[string]]::new()
$lines.Add("# 派发任务：$($dispatch.task_id)");$lines.Add('')
$lines.Add("- 派发编号：$($dispatch.dispatch_id)")
$lines.Add("- 工作流：$($dispatch.workflow_id)")
$lines.Add("- 目标任务：$($dispatch.thread_id)")
$lines.Add("- 主机：$($dispatch.host_id)")
$lines.Add("- 角色：$($dispatch.role)")
$lines.Add("- 项目：$($dispatch.project_path)")
$lines.Add("- Git 基线：$($dispatch.base_revision)")
$lines.Add("- 授权：$($dispatch.authorization)");$lines.Add('')
$lines.Add('## 目标');$lines.Add('');$lines.Add([string]$dispatch.objective);$lines.Add('')
$lines.Add('## 依赖');$lines.Add(''); if(@($dispatch.depends_on).Count){foreach($item in @($dispatch.depends_on)){$lines.Add("- $item")}}else{$lines.Add('- 无')};$lines.Add('')
$lines.Add('## 允许修改文件');$lines.Add(''); if(@($dispatch.allowed_files).Count){foreach($item in @($dispatch.allowed_files)){$lines.Add("- $item")}}else{$lines.Add('- 不允许修改文件')};$lines.Add('')
$lines.Add('## 执行规则');$lines.Add('')
$lines.Add('- 开始前核对项目路径、任务编号、派发编号和 Git 基线。')
$lines.Add('- 只在授权与文件范围内执行；需要扩大范围时立即停止。')
$lines.Add('- 不提交、不推送、不部署，除非任务中有对应独立授权。')
$lines.Add('- 回报必须原样包含任务编号、派发编号、实际命令、退出码、修改、测试、未执行项、阻塞和风险。')
$callbackBody=[ordered]@{type='completion_callback';event_id=$dispatch.callback.event_id;workflow_id=$dispatch.workflow_id;task_id=$dispatch.task_id;dispatch_id=$dispatch.dispatch_id;source_thread_id=$dispatch.thread_id;source_host_id=$dispatch.host_id;target_thread_id=$dispatch.callback.target_thread_id;target_host_id=$dispatch.callback.target_host_id;status=$dispatch.callback.status}|ConvertTo-Json -Compress
$lines.Add('');$lines.Add('## 完成回传');$lines.Add('')
$lines.Add("- 完成工作并形成最终回报后、结束本轮前，使用 send_message_to_thread 向总控任务 $($dispatch.callback.target_thread_id)（hostId=$($dispatch.callback.target_host_id)）发送下面这一行 JSON。")
$lines.Add('- 不修改 event_id，不追加自由文本；发送失败时如实报告，不得声称已经回传。')
$lines.Add('- 发送成功后等待总控以相同 event_id 返回 callback_ack；重复收到 ACK 时不得再次执行任务。')
$lines.Add('');$lines.Add($callbackBody)
$directory=Split-Path -Parent $resolvedOutput;if(-not(Test-Path -LiteralPath $directory)){[void](New-Item -ItemType Directory -Path $directory)}
[IO.File]::WriteAllLines($resolvedOutput,$lines,[Text.UTF8Encoding]::new($false))
Write-Output "PROMPT: $resolvedOutput"
