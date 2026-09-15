# Codex Project Orchestrator

这是一个面向 Codex 桌面版的多任务总控 Skill。项目当前只在 D 盘开发，不会自动安装到全局 Skill 目录。

## 本地验证

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\validate-workflow.ps1' -WorkflowPath '.\examples\read-only-analysis\workflow.json' -TasksPath '.\examples\read-only-analysis\tasks.json'
```

运行测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester '.\tests\validate-workflow.Tests.ps1'"
```

`tests/validate_schemas.py` 用于开发期 JSON Schema 正反例验证，需要 `jsonschema`。该测试依赖不属于 Skill 运行依赖。

安装、跨任务真实派发、Git 提交和部署均不属于上述命令的行为，需要独立授权。

## v0.2 状态管理

获得状态文件创建授权后初始化：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\manage-workflow.ps1' -Action initialize -ProjectPath 'D:\目标项目' -WorkflowId 'WF-001'
```

登记任务时，`DependsOn` 和 `AllowedFiles` 使用逗号分隔。运行 `-Action audit` 可检查事件序号、状态一致性和中断写入残留。运行状态保存在目标项目的 `.codex-orchestrator` 中并默认由 Git 忽略。

## v0.2.1 结果双输出

验证机器 JSON 并生成 UTF-8 中文报告：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\render-result.ps1' -ResultPath 'D:\目标项目\.codex-orchestrator\results\TEST-001.json' -OutputPath 'D:\目标项目\.codex-orchestrator\results\TEST-001.md' -ProjectPath 'D:\目标项目'
```

机器 JSON 不直接展示给用户；字段错误或 Git 基线过期时，渲染会失败并指出字段路径。

## v0.3 派发与恢复

先准备不可变派发信封，再在任务工具实际发送成功后记录消息 ID：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\manage-workflow.ps1' -Action prepare-dispatch -ProjectPath 'D:\目标项目' -TaskId 'ANALYSIS-001'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\manage-workflow.ps1' -Action record-sent -ProjectPath 'D:\目标项目' -TaskId 'ANALYSIS-001' -DispatchId '返回的派发编号' -ReceiptPath 'D:\目标项目\.codex-orchestrator\receipts\发送回执.json' -Cursor '任务工具返回的游标'
```

中断恢复时运行 `-Action reconcile`。它只输出下一步决策，不会自行发送消息；真正的跨窗口读取和发送仍由 Codex 桌面版受支持的任务工具完成。

## v0.4 Codex 原生任务适配

从派发信封生成不可覆盖的标准提示词：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\build-dispatch-prompt.ps1' -DispatchPath 'D:\目标项目\.codex-orchestrator\dispatches\派发编号.json' -OutputPath 'D:\目标项目\.codex-orchestrator\dispatches\派发编号.md'
```

总控使用 Codex 原生任务工具发送提示词，并把原始返回值保存到 `receipts` 后调用 `record-sent`。消息 ID 仅在工具真实返回时传入；任务观察使用 `record-observation` 保存状态和增量游标。
