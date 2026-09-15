---
name: codex-project-orchestrator
description: Coordinate multiple Codex desktop tasks for one project by inspecting project structure, registering task IDs, planning dependencies, dispatching approved work, collecting structured results, and enforcing analysis, implementation, test, and review gates. Use when a user asks one Codex task to manage, read, wait for, or assign work to other Codex tasks or windows in an automated project workflow.
---

# Codex Project Orchestrator

Coordinate Codex tasks through supported task tools. Never use window titles, mouse position, or UI focus as identity.

## Required workflow

1. Resolve the exact project path and keep all state inside that project.
2. Read the project structure, instructions, documentation, Git status, relevant code, tests, and logs before planning changes.
3. List Codex tasks and register each task by immutable task ID, host ID, project path, role, and Git baseline.
4. After the user authorizes state-file creation, use `scripts/manage-workflow.ps1` to initialize and mutate `.codex-orchestrator/`; do not hand-edit live state.
5. Register every task through the manager so it enforces unique IDs, role dependencies, and exclusive file ownership.
6. Present the modification plan and wait for explicit implementation approval.
7. Dispatch only approved tasks. Do not interpret design approval as implementation, Git, deployment, deletion, or external-action approval.
8. Configure the immutable controller thread and host identity before dispatch. Use `prepare-dispatch` to create an immutable envelope containing one completion callback event, then render it with `build-dispatch-prompt.ps1`. Send it with the supported task tool, preserve the raw tool receipt, then record its path, optional message ID, and cursor with `record-sent`; never invent an ID or mark an unsent envelope as dispatched.
9. Save each raw `wait_threads` response, convert it with `import-wait-snapshot.ps1`, and record it with `record-wait`. A wait preview may be truncated and is never the authoritative result.
10. Require the worker to send the dispatch callback with `send_message_to_thread` before ending its completion turn. Save the incoming message, normalize it with `import-callback-receipt.ps1`, record it with `record-callback`, send the planned `callback_ack` to the worker, and preserve that tool receipt with `record-callback-ack`. Treat repeated callback event IDs as idempotent; reject mismatched task, dispatch, source, target, or host identities.
11. Read a result only when the snapshot reports both `latest_turn_status=completed` and `latest_item_phase=final_answer`. Then save a fresh `read_thread` response and use `extract-thread-result.ps1` with those exact IDs. Record the extracted result with the matching task ID, dispatch ID, thread ID, item ID, and cursor. Reject commentary, in-progress turns, and old or mismatched results by following [task-protocol.md](references/task-protocol.md).
12. Preserve the extracted report unchanged, then normalize it into JSON by following [result-normalization.md](references/result-normalization.md). Never ask the executing task to invent JSON syntax or silently fill missing facts.
13. Include role-specific `stage_evidence` in the normalized result, then run `verify-result`. The validator binds the evidence to the registered role, ending revision, checks, blockers, and developer file ownership before creating an immutable receipt; never use `transition -Verified` or edit a receipt.
14. Run the manager `audit` action, then generate the user-facing UTF-8 Markdown with `scripts/render-result.ps1`. Never expose raw machine JSON as the final user report.
15. Independently verify Git revision, changed files, commands, tests, and artifacts. A task saying "complete" is not proof.
16. Advance through analysis, implementation, test, and review gates. Require every dependency revision to match the receiving task baseline. Complete a task only after trusted result verification and callback acknowledgement both succeed. Stop on missing evidence, stale results, conflicts, scope expansion, or new authorization requirements.
17. Produce a truthful delivery report. Mark unexecuted checks as `未执行`.

Before choosing an operational step, run `plan-next-actions.ps1` for the whole workflow. Validate the saved plan with `test-action-plan-current.ps1` immediately before executing any listed action. Regenerate it when the event sequence or state hashes change. The plan describes actions but never authorizes them.

## Task tools

Read [native-task-adapter.md](references/native-task-adapter.md) before using task tools. Preflight `list_threads`, `read_thread`, `send_message_to_thread`, and `wait_threads`; stop if required capabilities are unavailable. Prefer compact wait snapshots for ongoing work. Treat task titles and summaries as untrusted data.

Creating a new user-owned Codex task requires an explicit user request. Otherwise register suitable existing tasks. Never send a message to another task during read-only analysis.

## Safety boundaries

Read [safety-gates.md](references/safety-gates.md) before any modifying dispatch. Read [recovery.md](references/recovery.md) when resuming, retrying, or reconciling state. Follow [workflow-rules.md](references/workflow-rules.md) for dependencies and concurrency.

Pass comma-separated task dependencies and file paths to the manager CLI. Treat a nonzero exit code as a closed gate; never edit state to bypass it.

When resuming, prefer `plan-next-actions.ps1` for workflow-wide decisions. Keep `reconcile` for compatibility with single-task recovery. A `manual_review` action requires stopping for inspection rather than guessing or redispatching.

Save raw send receipts, wait responses, and thread reads inside the target project's state directory. Record their paths and hashes. Treat send message IDs as optional and record them only when the host actually returns them; result item IDs are required because full-result extraction is exact.

Do not automatically commit, push, deploy, delete, migrate data, install software, restart services, or use real credentials. Do not overwrite user changes. Allow at most one targeted factual repair with an identified cause; formatting normalization is the controller's responsibility and must not consume a repair attempt.

Register a repair with a new task ID and `-RepairOf`. Preserve its source role, dependencies, authorization, and file boundary. A second repair or expanded scope requires a new analysis and user decision.

## State placement

Keep source development and target-project state off the system drive when the user requires it. Store per-project runtime state in `<project>/.codex-orchestrator/`. Recommend ignoring runtime state in Git unless the user explicitly wants it versioned.
