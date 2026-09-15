# 结果规范化

## 输入与输出

输入是 Codex 任务的原始最终回报及其任务元数据。输出是符合 `result.schema.json` 的 JSON，同时保留原始回报用于审计。

## 规则

1. 从任务工具返回值取得 `dispatch_id`、`thread_id`、`host_id`、消息 ID 和完成时间，不要求执行任务自行发现这些值。
2. 原样保存原始回报；不得覆盖、重新措辞或删除。
3. 只把原文明确陈述的事实写入规范化字段。
4. 缺失信息写入 `unexecuted`、`blockers` 或 `risks`，不得猜测默认成功。
5. 命令、退出码和结果必须保持对应关系；无法确认退出码时不得填 `0`。
6. 将任务开始前的变更与本任务产生的变更分别记录在 `preexisting_changes` 和 `changed_files`。
7. 在 `normalization` 中记录来源任务、来源消息、规范化者、原始格式和所有解释性决定。
8. 使用 `result.schema.json` 和 `scripts/validate-result.ps1` 校验，并传入预期任务、派发和窗口 ID。失败时停止门禁并报告字段路径。
9. 关键结论仍需总控用 Git、文件或命令输出独立复核；Schema 通过不等于任务通过。
10. 校验通过后使用 `scripts/render-result.ps1` 生成面向用户的 UTF-8 Markdown；不要把机器 JSON 直接粘贴给用户。

规范化是总控职责，不计入任务返修次数。只有事实缺失、相互矛盾或证据不足时，才允许一次定向返修。
