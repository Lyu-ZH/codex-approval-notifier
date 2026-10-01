Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$taskName = "Codex Approval Notifier"
$scriptPath = Join-Path $PSScriptRoot "CodexApprovalNotifier.ps1"
$startupDir = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "Codex Approval Notifier.lnk"
$legacyShortcutPath = $shortcutPath

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Notifier script not found: $scriptPath"
}

if (Test-Path -LiteralPath $legacyShortcutPath) {
    Remove-Item -LiteralPath $legacyShortcutPath -Force
    Write-Host "Removed legacy startup shortcut:"
    Write-Host $legacyShortcutPath
}

$currentPid = $PID
$existingProcesses = Get-CimInstance Win32_Process | Where-Object {
    $commandLine = [string]$_.CommandLine
    $_.CommandLine -and
    $commandLine -match '(?i)-File\s+(?:"[^"]*CodexApprovalNotifier\.ps1"|[^\s]*CodexApprovalNotifier\.ps1)' -and
    $_.ProcessId -ne $currentPid
}
foreach ($process in $existingProcesses) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Host ("Stopped existing notifier process: {0}" -f $process.ProcessId)
}

$arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -DisableUserInputAlert -EnableTurnCompletionAlert -Quiet' -f $scriptPath
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments -WorkingDirectory $PSScriptRoot
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$watchdogTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger @($logonTrigger, $watchdogTrigger) `
    -Settings $settings `
    -Principal $principal `
    -Description "Notify on every completed Codex turn, Goal completion, interruptions, and failures. Request alerts are disabled." `
    -Force | Out-Null

Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2

$task = Get-ScheduledTask -TaskName $taskName
$taskInfo = Get-ScheduledTaskInfo -TaskName $taskName

Write-Host "Installed scheduled task:"
Write-Host $taskName
Write-Host ("State: {0}" -f $task.State)
Write-Host ("Last run result: {0}" -f $taskInfo.LastTaskResult)
Write-Host "The notifier will start when you sign in, restart automatically if it exits unexpectedly, and get checked once per minute."
