[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkflowPath,
    [Parameter(Mandatory = $true)][string]$TasksPath
)

$ErrorActionPreference = 'Stop'
$validStates = @('draft','awaiting_approval','approved','dispatched','running','verifying','completed','blocked','failed','cancelled','stale')
$validRoles = @('analyst','developer','tester','reviewer')
$validAuthorizations = @('read-only','plan-approved','implementation-approved','test-approved','git-approved','deployment-approved')
$errors = [System.Collections.Generic.List[string]]::new()

function Add-ValidationError([string]$Message) { $errors.Add($Message) }
function Require-Property($Object, [string]$Name, [string]$Context) {
    if ($Object.PSObject.Properties.Match($Name).Count -eq 0) { Add-ValidationError "$Context missing field: $Name"; return $false }
    return $true
}

$workflow = Get-Content -LiteralPath $WorkflowPath -Raw -Encoding UTF8 | ConvertFrom-Json
$parsedTasks = Get-Content -LiteralPath $TasksPath -Raw -Encoding UTF8 | ConvertFrom-Json
$tasks = @($parsedTasks | ForEach-Object { $_ })

foreach ($name in @('workflow_id','project_path','status','authorization','created_at','updated_at')) { [void](Require-Property $workflow $name 'workflow') }
if ($workflow.status -notin $validStates) { Add-ValidationError "workflow invalid status: $($workflow.status)" }
if ($workflow.authorization -notin $validAuthorizations) { Add-ValidationError "workflow invalid authorization: $($workflow.authorization)" }
if (-not [System.IO.Path]::IsPathRooted([string]$workflow.project_path)) { Add-ValidationError 'workflow.project_path must be absolute' }

$taskIds = @{}
$threadIds = @{}
foreach ($task in $tasks) {
    $context = "task[$($task.task_id)]"
    foreach ($name in @('task_id','thread_id','host_id','role','status','depends_on','project_path','base_revision','allowed_files','objective','authorization','repair_count','updated_at')) { [void](Require-Property $task $name $context) }
    if ([string]::IsNullOrWhiteSpace($task.task_id)) { Add-ValidationError "$context task_id is empty" }
    elseif ($taskIds.ContainsKey($task.task_id)) { Add-ValidationError "duplicate task_id: $($task.task_id)" }
    else { $taskIds[$task.task_id] = $task }
    if ([string]::IsNullOrWhiteSpace($task.thread_id)) { Add-ValidationError "$context thread_id is empty" }
    elseif ($threadIds.ContainsKey($task.thread_id)) { Add-ValidationError "duplicate thread_id: $($task.thread_id)" }
    else { $threadIds[$task.thread_id] = $true }
    if ($task.role -notin $validRoles) { Add-ValidationError "$context invalid role: $($task.role)" }
    if ($task.status -notin $validStates) { Add-ValidationError "$context invalid status: $($task.status)" }
    if ($task.authorization -notin $validAuthorizations) { Add-ValidationError "$context invalid authorization: $($task.authorization)" }
    if ($task.project_path -ne $workflow.project_path) { Add-ValidationError "$context project_path differs from workflow" }
    if ([int]$task.repair_count -lt 0 -or [int]$task.repair_count -gt 1) { Add-ValidationError "$context repair_count must be 0 or 1" }
    if ($task.role -eq 'developer' -and $task.authorization -notin @('implementation-approved','git-approved','deployment-approved')) { Add-ValidationError "$context developer lacks implementation approval" }
    if ($task.PSObject.Properties.Match('delivery_status').Count -gt 0) {
        if ($task.delivery_status -notin @('not-prepared','prepared','sent','acknowledged','result_received')) { Add-ValidationError "$context invalid delivery_status: $($task.delivery_status)" }
        if ($task.delivery_status -ne 'not-prepared' -and [string]::IsNullOrWhiteSpace($task.dispatch_id)) { Add-ValidationError "$context delivery requires dispatch_id" }
        if ($task.delivery_status -in @('sent','acknowledged','result_received') -and [string]::IsNullOrWhiteSpace($task.sent_message_id)) { Add-ValidationError "$context delivery requires sent_message_id" }
        if ($task.delivery_status -eq 'result_received' -and [string]::IsNullOrWhiteSpace($task.result_message_id)) { Add-ValidationError "$context result_received requires result_message_id" }
    }
}

foreach ($task in $tasks) {
    foreach ($dependency in @($task.depends_on | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        if (-not $taskIds.ContainsKey([string]$dependency)) { Add-ValidationError "task[$($task.task_id)] dependency not found: $dependency" }
        elseif ($dependency -eq $task.task_id) { Add-ValidationError "task[$($task.task_id)] cannot depend on itself" }
    }
    if ($task.status -in @('dispatched','running','verifying','completed')) {
        foreach ($dependency in @($task.depends_on | Where-Object { $_ })) {
            if ($taskIds.ContainsKey([string]$dependency) -and ($taskIds[[string]$dependency].status -ne 'completed' -or ($taskIds[[string]$dependency].PSObject.Properties.Match('verified').Count -gt 0 -and -not $taskIds[[string]$dependency].verified))) { Add-ValidationError "task[$($task.task_id)] dependency is not verified complete: $dependency" }
        }
    }
    if ($task.status -eq 'completed' -and $task.PSObject.Properties.Match('verified').Count -gt 0) {
        if (-not $task.verified -or [string]::IsNullOrWhiteSpace($task.raw_result_path) -or [string]::IsNullOrWhiteSpace($task.normalized_result_path)) { Add-ValidationError "task[$($task.task_id)] completed without verified evidence" }
    }
}

function Test-DependencyCycle([string]$TaskId, [hashtable]$Visiting, [hashtable]$Visited) {
    if ($Visiting.ContainsKey($TaskId)) { return $true }
    if ($Visited.ContainsKey($TaskId)) { return $false }
    $Visiting[$TaskId] = $true
    foreach ($dependency in @($taskIds[$TaskId].depends_on | Where-Object { $taskIds.ContainsKey([string]$_) })) {
        if (Test-DependencyCycle ([string]$dependency) $Visiting $Visited) { return $true }
    }
    $Visiting.Remove($TaskId)
    $Visited[$TaskId] = $true
    return $false
}

$visited = @{}
foreach ($taskId in @($taskIds.Keys)) {
    if (Test-DependencyCycle ([string]$taskId) @{} $visited) {
        Add-ValidationError "dependency cycle detected at: $taskId"
        break
    }
}

for ($i = 0; $i -lt $tasks.Count; $i++) {
    if ($tasks[$i].role -ne 'developer' -or $tasks[$i].status -in @('completed','failed','blocked','cancelled','stale')) { continue }
    for ($j = $i + 1; $j -lt $tasks.Count; $j++) {
        if ($tasks[$j].role -ne 'developer' -or $tasks[$j].status -in @('completed','failed','blocked','cancelled','stale')) { continue }
        $overlap = @($tasks[$i].allowed_files | Where-Object { $_ -in $tasks[$j].allowed_files })
        if ($overlap.Count -gt 0) { Add-ValidationError "developer file conflict: $($tasks[$i].task_id) and $($tasks[$j].task_id) -> $($overlap -join ', ')" }
    }
}

if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Output "INVALID: $_" }; exit 1 }
Write-Output "VALID: workflow=$($workflow.workflow_id); tasks=$($tasks.Count)"
exit 0
