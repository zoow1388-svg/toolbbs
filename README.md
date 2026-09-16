# 自动化多窗口项目总控

这是一个面向 Codex 桌面版的自动化多窗口项目总控 Skill：让一个总控任务通过不可变任务 ID 协调多个 Codex 任务，完成分析、开发、测试、审查、结果回传和中断恢复。项目当前只在 D 盘开发，不会自动安装到全局 Skill 目录。

## v1.6 五窗口真实 E2E 准备

v1.6 使用一个总控任务和分析、开发、测试、审查四个独立执行任务。开发任务使用独立分支工作树；测试和审查分别使用绑定到开发提交的独立验证工作树。`verify-five-window-e2e.ps1` 只接受四个不同任务 ID 和线程 ID、完整回传 ACK、可信验证、真实代码提交、通过的测试以及无遗留问题的独立审查。

仓库中的自动测试和 `examples/five-window-e2e` 只验证协议与隔离测试场景，不能代替真实 Codex 五窗口验收。真实验收必须另行授权创建四个 Codex 任务和隔离测试仓库。

## v1.5 Git Worktree 隔离

开发任务使用真实 Git 提交作为基线时，必须绑定独立、干净且处于分支上的 Git Worktree。总控先生成检查证据，再登记到任务状态：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\inspect-worktree.ps1' -WorktreePath 'D:\工作树\DEV-001' -OutputPath 'D:\目标项目\worktree-DEV-001.json'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\manage-workflow.ps1' -Action bind-worktree -ProjectPath 'D:\目标项目' -TaskId 'DEV-001' -BindingPath 'D:\目标项目\worktree-DEV-001.json'
```

绑定会核对仓库根目录、工作树路径、分支、HEAD、基线提交和干净状态。两个活动开发任务不得共用工作树或分支。本版本不会自动创建、删除、提交、合并或推送 Git 内容。

## v1.6.0 安装与升级

正式安装包包含 Skill、安装器、可恢复卸载器、文件清单和 SHA-256 校验值。普通用户请按照 [`docs/INSTALL.md`](docs/INSTALL.md) 操作。安装不需要 Python、`jsonschema` 或 PyYAML。

开发环境生成安装包：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\installer\build-release.ps1'
```

构建产物写入 D 盘项目的 `dist/` 并由 Git 忽略，不会自动安装、提交或上传。

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

## v1.0 四角色交付链

分析、开发、测试、审查现在使用角色专属证据门禁。规范化结果必须声明 `stage_evidence`，且角色、检查的代码修订和完成标准必须与登记任务一致；失败检查、阻塞项、审查遗留问题或开发越出 `allowed_files` 都会拒绝完成。

每个后续派发信封保存依赖任务的 `end_revision`。多个依赖必须指向同一修订，且该修订必须等于新任务的 `base_revision`，防止测试或审查检查错误版本。

失败或阻塞任务可登记一次 `repair_of` 返修任务。返修必须保持相同角色、依赖和授权，文件范围只能缩小不能扩大；第二次返修会关闭门禁并要求重新分析。

## v1.1 总控接管与断点恢复

工作流使用 `controller_epoch` 标识唯一总控任期。原总控不可恢复时，新总控必须带上自己最后读取到的旧身份、旧任期和接管原因执行比较并交换：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\manage-workflow.ps1' -Action takeover-controller -ProjectPath 'D:\目标项目' -ExpectedControllerThreadId '旧总控任务ID' -ExpectedControllerHostId 'local' -ExpectedControllerEpoch 1 -ControllerThreadId '新总控任务ID' -ControllerHostId 'local' -TakeoverReason '旧总控任务不可恢复'
```

只有与当前状态完全匹配的第一个接管请求能成功。接管会递增任期、保留历史并使旧动作计划失效。已派发任务继续使用派发时固化的旧回传目标和事件，不修改信封、不重复派发；新派发使用新总控和新任期。

## v1.2 外部动作事务日志

向任务发送派发或回传 ACK 前，必须先持久化外部动作意图：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\manage-workflow.ps1' -Action begin-external-action -ProjectPath 'D:\目标项目' -TaskId 'ANALYSIS-001' -ExternalActionType dispatch_send -ExpectedControllerEpoch 1
```

使用返回的不可变 `payload` 调用 Codex 任务工具。只有工具真实成功后，保存原始响应并执行 `complete-external-action`；随后按动作计划用同一 `ExternalActionId` 调用 `record-sent` 或 `record-callback-ack`。状态管理器拒绝没有已完成事务支撑的发送回执。

若总控在工具调用前后断开，事务保持 `prepared`，计划器只生成 `inspect_external_action`，不会自动重发。确认未送达后用证据文件执行 `cancel-external-action` 才能产生下一次尝试；确认已送达则用原始回执完成事务。接管后的新总控处理旧任期动作时必须额外提供独立投递证据。

## v1.3 动作执行租约与检查点

执行动作计划中的任一动作前，先认领它：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\skill\codex-project-orchestrator\scripts\manage-workflow.ps1' -Action claim-action -ProjectPath 'D:\目标项目' -PlanPath 'D:\目标项目\.codex-orchestrator\plans\next-actions.json' -ActionId '计划中的动作ID' -ExpectedControllerEpoch 1
```

认领结果写入 `action-executions.json`，包含不可变动作哈希和最长一小时的租约。长动作可以在租约到期前使用 `renew-action` 续期；完成或失败分别使用 `complete-action`、`fail-action` 并提供真实证据文件。重复唤醒、租约过期或控制器接管时，未解决动作只进入 `inspect_action_execution`，不会自动执行第二次。

## v1.4 证据化恢复与安全重试

过期或旧总控任期的动作先核查实际效果，再用 `resolve-action` 记录 `abandoned` 或 `reconciled`。活动租约不能解除，没有证据不能恢复。失败动作必须通过 `authorize-action-retry` 单独保存用户授权和原因消除证据，之后计划器才允许生成递增尝试号的新认领。

外部发送仍以 `external-actions.json` 为最终依据：外部事务尚未取消时，不能通过通用动作恢复声称“没有发送”。动作计划升级为 Schema v5，旧计划会被拒绝。
