@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CodexApprovalNotifier.ps1" -DisableUserInputAlert -EnableTurnCompletionAlert -CatchUpSeconds 30
pause
