# 自动化多窗口项目总控：安装、升级与卸载

## 系统要求

- Windows 10 或 Windows 11。
- Codex 桌面版。
- Windows PowerShell 5.1 或 PowerShell 7。
- 安装过程不需要 Python、`jsonschema` 或 PyYAML。

## 安装

1. 从 GitHub Release 下载 `codex-project-orchestrator-v1.6.0.zip` 和对应的 `.sha256` 文件。
2. 在文件所在目录验证 SHA-256：

```powershell
Get-FileHash -Algorithm SHA256 '.\codex-project-orchestrator-v1.6.0.zip'
```

3. 确认输出与 `.sha256` 文件中的值一致，然后解压 ZIP。
4. 在解压目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\install.ps1'
```

5. 完全关闭并重新打开 Codex 桌面版，然后在新任务中输入：

```text
使用 $codex-project-orchestrator，让当前任务作为总控，自动协调多个 Codex 任务完成项目分析、开发、测试与审查。
```

默认安装到 `$CODEX_HOME\skills`；未设置 `CODEX_HOME` 时安装到 `%USERPROFILE%\.codex\skills`。如需安装到测试目录，使用 `-DestinationRoot 'D:\指定目录\skills'`。

## 升级

升级不会直接覆盖旧目录。安装器先校验新包，把旧版本移动到 `.toolbbs-backups`，再启用新版本。确认升级时运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\install.ps1' -AllowUpgrade
```

如果安装失败，安装器会自动把旧目录移回原位置。同版本且内容完全一致时，重复运行不会修改任何文件。

## 卸载

先预览将要执行的操作：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\uninstall.ps1' -WhatIf
```

确认后卸载：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\uninstall.ps1' -Confirm:$false
```

卸载采用可恢复移动，不会永久删除 Skill。使用 `-RestoreLatestBackup` 可在卸载当前版本后恢复最近的旧版本。

## 常见问题

- **提示已有版本且内容不同**：先确认没有需要保留的手工修改，再使用 `-AllowUpgrade`。
- **Codex 没有识别 Skill**：检查最终路径是否为 `skills\codex-project-orchestrator\SKILL.md`，然后完全重启 Codex。
- **脚本被执行策略阻止**：使用文档中的 `-ExecutionPolicy Bypass`，它只影响本次 PowerShell 进程。
- **安装失败**：保留完整错误信息和 `.toolbbs-backups`，不要手工删除备份目录。
