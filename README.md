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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\manage-workflow.ps1' -Action initialize -ProjectPath 'D:\目标项目' -WorkflowId 'WF-001' -ControllerThreadId '总控任务ID' -ControllerHostId 'local'
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

## v0.5 完整结果采集

保存 `wait_threads` 的原始响应后，先生成不含消息正文的快照并记账：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\import-wait-snapshot.ps1' -RawWaitPath 'D:\目标项目\.codex-orchestrator\observations\wait-001.json' -ExpectedThreadId '任务ID' -ExpectedHostId 'local' -OutputPath 'D:\目标项目\.codex-orchestrator\observations\wait-001.snapshot.json'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\manage-workflow.ps1' -Action record-wait -ProjectPath 'D:\目标项目' -TaskId 'ANALYSIS-001' -SnapshotPath 'D:\目标项目\.codex-orchestrator\observations\wait-001.snapshot.json'
```

等待响应中的消息可能被截断。收到完成 turn 和最终 item 身份后，必须保存 `read_thread` 完整响应，再精确提取：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\extract-thread-result.ps1' -RawThreadPath 'D:\目标项目\.codex-orchestrator\observations\read-001.json' -ExpectedThreadId '任务ID' -ExpectedTurnId '返回的turn ID' -ExpectedItemId '返回的item ID' -OutputPath 'D:\目标项目\.codex-orchestrator\results\ANALYSIS-001.raw.md'
```

随后用 `record-result` 登记该完整原文。快照 revision 重复、身份不符、证据哈希变化或完整 item 缺失都会关闭门禁。

## v0.6 可信结果验证

规范化结果完成后，通过状态管理器执行真实验证并生成不可变回执：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\manage-workflow.ps1' -Action verify-result -ProjectPath 'D:\目标项目' -TaskId 'ANALYSIS-001' -NormalizedResultPath 'D:\目标项目\.codex-orchestrator\results\ANALYSIS-001.json'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\manage-workflow.ps1' -Action transition -ProjectPath 'D:\目标项目' -TaskId 'ANALYSIS-001' -ToStatus completed -Reason '可信验证通过'
```

旧的 `transition -Verified` 已被拒绝，不能由调用者直接声明验证成功。`audit` 会检查原始结果、规范化结果和验证回执，验证后修改任一证据都会失败。

升级时，没有新回执的旧版完成任务会保留历史状态，但标记为 `legacy-unverified`，不能作为后续任务的可信依赖。

## v0.7 统一下一动作

为整个工作流生成不可覆盖的下一动作计划：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\plan-next-actions.ps1' -ProjectPath 'D:\目标项目' -OutputPath 'D:\目标项目\.codex-orchestrator\plans\next-actions.json'
```

执行计划中的任何动作前，检查它仍对应当前状态：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\test-action-plan-current.ps1' -ProjectPath 'D:\目标项目' -PlanPath 'D:\目标项目\.codex-orchestrator\plans\next-actions.json'
```

计划器不会发送消息或修改任务状态。状态事件序号或状态文件发生变化后，旧计划检查失败，必须生成新文件；不要手工修改旧计划。

## v0.8 真实双窗口验证

已在同一 D 盘项目中使用两个真实 Codex 任务跑通完整只读流程。v0.8 根据现场结果修复两项问题：宿主没有游标时不再传空 `afterCursor`；活动 commentary 不再被误判为最终结果。

结果读取现在必须同时满足 `latest_turn_status=completed` 和 `latest_item_phase=final_answer`。真实验证范围和未覆盖场景见 [`docs/v0.8-real-e2e.md`](docs/v0.8-real-e2e.md)。

## v0.9 主动回传与唤醒

派发信封现在包含不可变总控身份和唯一 `callback_event_id`。执行任务完成后主动向总控发送固定 JSON，从而唤醒等待或 idle 的总控任务。总控保存收到的原始消息后先生成可信回执：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\import-callback-receipt.ps1' -RawMessagePath 'D:\目标项目\.codex-orchestrator\callbacks\原始消息.txt' -ExpectedEventId '回传事件ID' -ExpectedWorkflowId 'WF-001' -ExpectedTaskId 'ANALYSIS-001' -ExpectedDispatchId '派发编号' -ExpectedSourceThreadId '执行任务ID' -ExpectedSourceHostId 'local' -ExpectedTargetThreadId '总控任务ID' -ExpectedTargetHostId 'local' -OutputPath 'D:\目标项目\.codex-orchestrator\callbacks\回传事件ID.json'
```

随后使用 `record-callback` 记账，按动作计划向执行任务发送 `callback_ack`，并用 `record-callback-ack` 保存真实发送回执。任务只有同时满足可信结果验证和回传 ACK 才能完成；重复事件不会重复记账或再次派发。
