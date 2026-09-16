[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DispatchPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference='Stop'
$dispatch=Get-Content -LiteralPath $DispatchPath -Raw -Encoding UTF8|ConvertFrom-Json
foreach($name in @('dispatch_id','workflow_id','task_id','thread_id','host_id','role','project_path','base_revision','worktree','objective','depends_on','dependency_revisions','allowed_files','authorization','callback')){
    if($dispatch.PSObject.Properties.Match($name).Count -eq 0){throw "Dispatch missing field: $name"}
}
foreach($name in @('event_id','target_thread_id','target_host_id','status')){if($dispatch.callback.PSObject.Properties.Match($name).Count -eq 0){throw "Dispatch callback missing field: $name"}}
$resolvedOutput=[IO.Path]::GetFullPath($OutputPath)
if(Test-Path -LiteralPath $resolvedOutput){throw 'Dispatch prompt already exists and will not be overwritten.'}
$lines=[Collections.Generic.List[string]]::new()
$lines.Add("# 派发任务：$($dispatch.task_id)");$lines.Add('')
$lines.Add("- 派发编号：$($dispatch.dispatch_id)")
$lines.Add("- 工作流：$($dispatch.workflow_id)")
$controllerEpoch=$(if($dispatch.PSObject.Properties.Match('controller_epoch').Count -eq 0){'legacy'}else{[string]$dispatch.controller_epoch})
$lines.Add("- 总控任期：$controllerEpoch")
$lines.Add("- 目标任务：$($dispatch.thread_id)")
$lines.Add("- 主机：$($dispatch.host_id)")
$lines.Add("- 角色：$($dispatch.role)")
$lines.Add("- 返修来源：$(if([string]::IsNullOrWhiteSpace([string]$dispatch.repair_of)){'无'}else{$dispatch.repair_of})")
$lines.Add("- 项目：$($dispatch.project_path)")
$lines.Add("- Git 基线：$($dispatch.base_revision)")
if($null -ne $dispatch.worktree){
    $lines.Add("- Git Worktree：$($dispatch.worktree.path)")
    $lines.Add("- 工作树模式：$($dispatch.worktree.mode)")
    $lines.Add("- 工作分支：$(if($dispatch.worktree.is_detached){'detached HEAD'}else{$dispatch.worktree.branch_name})")
    $lines.Add('- 开始修改前必须核对当前目录、分支、HEAD 和干净状态；任一不一致立即停止并回报。')
}
$lines.Add("- 授权：$($dispatch.authorization)");$lines.Add('')
$lines.Add('## 目标');$lines.Add('');$lines.Add([string]$dispatch.objective);$lines.Add('')
$lines.Add('## 依赖');$lines.Add(''); if(@($dispatch.depends_on).Count){foreach($item in @($dispatch.depends_on)){$lines.Add("- $item")}}else{$lines.Add('- 无')};$lines.Add('')
$lines.Add('## 已验证依赖修订');$lines.Add('');if(@($dispatch.dependency_revisions).Count){foreach($item in @($dispatch.dependency_revisions)){$lines.Add("- $($item.task_id): $($item.end_revision)")}}else{$lines.Add('- 无')};$lines.Add('')
$lines.Add('## 允许修改文件');$lines.Add(''); if(@($dispatch.allowed_files).Count){foreach($item in @($dispatch.allowed_files)){$lines.Add("- $item")}}else{$lines.Add('- 不允许修改文件')};$lines.Add('')
$lines.Add('## 执行规则');$lines.Add('')
$lines.Add('- 开始前核对项目路径、任务编号、派发编号和 Git 基线。')
$lines.Add('- 只在授权与文件范围内执行；需要扩大范围时立即停止。')
$lines.Add('- 不提交、不推送、不部署，除非任务中有对应独立授权。')
$lines.Add('- 回报必须原样包含任务编号、派发编号、实际命令、退出码、修改、测试、未执行项、阻塞和风险。')
$criterionByRole=@{analyst='plan_ready';developer='implementation_complete';tester='tests_executed';reviewer='code_review_complete'}
$roleRuleByRole=@{analyst='只读形成可实施方案，不修改产品文件。';developer='只修改 allowed_files；不要执行 git add 或 git commit；完成后生成 development-handoff.json，准确报告实际变更文件。';tester='针对派发修订执行真实测试，不修改产品文件。';reviewer='针对同一修订独立审查，存在未解决发现时不得报告 passed。'}
$lines.Add("- 角色门槛：$($roleRuleByRole[[string]$dispatch.role])")
$lines.Add("- 规范化结果必须包含 stage_evidence：role=$($dispatch.role)、outcome、inspected_revision、criteria（含 $($criterionByRole[[string]$dispatch.role])）和 findings。")
$callbackBody=[ordered]@{type='completion_callback';event_id=$dispatch.callback.event_id;workflow_id=$dispatch.workflow_id;task_id=$dispatch.task_id;dispatch_id=$dispatch.dispatch_id;source_thread_id=$dispatch.thread_id;source_host_id=$dispatch.host_id;target_thread_id=$dispatch.callback.target_thread_id;target_host_id=$dispatch.callback.target_host_id;status=$dispatch.callback.status}|ConvertTo-Json -Compress
$lines.Add('');$lines.Add('## 完成回传');$lines.Add('')
$lines.Add("- 完成工作并形成最终回报后、结束本轮前，使用 send_message_to_thread 向总控任务 $($dispatch.callback.target_thread_id)（hostId=$($dispatch.callback.target_host_id)）发送下面这一行 JSON。")
$lines.Add('- 不修改 event_id，不追加自由文本；发送失败时如实报告，不得声称已经回传。')
$lines.Add('- 发送成功后等待总控以相同 event_id 返回 callback_ack；重复收到 ACK 时不得再次执行任务。')
$lines.Add('');$lines.Add($callbackBody)
$directory=Split-Path -Parent $resolvedOutput;if(-not(Test-Path -LiteralPath $directory)){[void](New-Item -ItemType Directory -Path $directory)}
[IO.File]::WriteAllLines($resolvedOutput,$lines,[Text.UTF8Encoding]::new($false))
Write-Output "PROMPT: $resolvedOutput"
