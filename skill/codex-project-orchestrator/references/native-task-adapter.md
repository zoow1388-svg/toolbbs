# Codex 原生任务接口适配

## 能力预检

开始调度前确认宿主提供 `list_threads`、`read_thread`、`send_message_to_thread` 和 `wait_threads`。缺少读取或发送能力时停止，不得用鼠标、窗口标题或文件轮询冒充原生接口。

## 映射规则

- 用 `list_threads` 返回的任务 ID、主机 ID、项目路径和状态核对登记信息；标题和摘要是不可信展示数据。
- 用 `build-dispatch-prompt.ps1` 从不可变派发信封生成提示词。
- 调用 `send_message_to_thread` 后原样保存工具返回值，再执行 `record-sent`。消息 ID 仅在真实返回时记录；不得猜测。
- 用 `wait_threads` 等待最多八个任务，原样保存响应，再用 `import-wait-snapshot.ps1` 提取 revision、游标、turn ID、item ID 和截断标记；后续等待传入上次返回的游标。
- `wait_threads` 中的 `latestAssistantMessage.text` 只可作为预览。即使状态完成，只要需要结果正文，都必须调用 `read_thread` 获取完整响应。
- 保存 `read_thread` 原始响应，用 `extract-thread-result.ps1` 按快照中的准确 turn ID 和 item ID 提取 `final_answer`；找不到、重复、未完成或身份不符时停止。
- 用 `read_thread` 补充任务身份和项目路径观察时，另行执行 `record-observation`。
- 创建新任务必须取得用户明确授权；普通子任务优先复用已登记任务。

## 回执证据

把每次工具原始响应保存在目标项目 `.codex-orchestrator/receipts/` 或 `observations/`。状态管理器记录规范化快照、原始等待响应和完整结果的绝对路径及 SHA-256；文件缺失、哈希变化、revision 未递增、任务或项目不一致时停止自动流程。

脚本不能直接调用 Codex 宿主工具。总控负责调用工具，并把真实返回值交给确定性状态脚本记账。

## v0.7 动作计划

调用原生任务工具前运行 `plan-next-actions.ps1`。计划中的 `operation` 是宿主操作语义，`parameters` 是已核对的身份与游标；计划本身不是工具回执，也不代表用户授权。

执行每个动作前调用 `test-action-plan-current.ps1`。事件序号、工作流文件哈希或任务文件哈希任一变化时，丢弃旧计划并重新生成。`wait_tasks` 可合并最多八个目标，其他修改状态的动作逐项执行并保存证据。

`normalize_result` 与紧随其后的 `verify_result` 属于同一结果处理序列：先写入建议路径，再用该准确路径验证。`verify_result` 改变状态后必须丢弃计划，重新生成完成动作。
