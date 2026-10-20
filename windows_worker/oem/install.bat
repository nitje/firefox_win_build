@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\OEM\bootstrap.ps1 >> C:\OEM\bootstrap-console.log 2>&1
exit /b %ERRORLEVEL%
