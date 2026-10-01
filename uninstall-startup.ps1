Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$taskName = "Codex Approval Notifier"
$startupDir = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "Codex Approval Notifier.lnk"
$legacyShortcutPath = $shortcutPath

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed scheduled task:"
    Write-Host $taskName
} else {
    Write-Host "Scheduled task was not installed:"
    Write-Host $taskName
}

if (Test-Path -LiteralPath $legacyShortcutPath) {
    Remove-Item -LiteralPath $legacyShortcutPath -Force
    Write-Host "Removed legacy startup shortcut:"
    Write-Host $legacyShortcutPath
}
