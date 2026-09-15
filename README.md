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
