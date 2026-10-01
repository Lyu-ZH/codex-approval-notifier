@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CodexApprovalNotifier.ps1" -TestAlert -AutoCloseSeconds 30
