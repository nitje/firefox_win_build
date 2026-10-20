@echo off
setlocal EnableExtensions
set "ROOT=C:\firefox_worker"
set "VERSION=0.0.26"
if not exist "%ROOT%" mkdir "%ROOT%"
if not exist "%ROOT%\jobs" mkdir "%ROOT%\jobs"
if not exist "%ROOT%\processing" mkdir "%ROOT%\processing"
if not exist "%ROOT%\failed" mkdir "%ROOT%\failed"
if not exist "%ROOT%\home" mkdir "%ROOT%\home"
if not exist "C:\mozilla-build\start-shell.bat" goto no_mozilla

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\ensure_devdrive.ps1" >nul 2>&1
set "DEV_RC=%ERRORLEVEL%"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\ensure_defender_exclusions.ps1" -Quiet >nul 2>&1
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\ensure_vcredist.ps1" -Quiet >nul 2>&1
set "VC_RC=%ERRORLEVEL%"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\ensure_build_memory.ps1" >nul 2>&1
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\update_worker_ready.ps1" -Version "%VERSION%" >nul 2>&1

schtasks.exe /End /TN "FirefoxBuildWorker" >nul 2>&1
schtasks.exe /Delete /TN "FirefoxBuildWorker" /F >nul 2>&1
schtasks.exe /Create /TN "FirefoxBuildWorker" /SC ONSTART /RU SYSTEM /RL HIGHEST /TR "cmd.exe /d /c C:\firefox_worker\worker.cmd" /F >nul 2>&1
if errorlevel 1 goto task_error
schtasks.exe /Run /TN "FirefoxBuildWorker" >nul 2>&1
exit /b 0

:no_mozilla
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\update_worker_ready.ps1" -Version "%VERSION%" >nul 2>&1
exit /b 2
:task_error
>"%ROOT%\BOOTSTRAP.json" echo {"state":"error","phase":"ERROR","detail":"FirefoxBuildWorker Task konnte nicht registriert werden","worker_version":"%VERSION%"}
exit /b 3
