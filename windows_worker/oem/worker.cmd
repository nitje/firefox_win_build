@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "ROOT=C:\firefox_worker"
set "SHARE=\\host.lan\Data"
set "VERSION=0.0.26"
set "LOCAL_STATUS=%ROOT%\worker_local_status.json"
if not exist "%ROOT%\jobs" mkdir "%ROOT%\jobs"
if not exist "%ROOT%\processing" mkdir "%ROOT%\processing"
if not exist "%ROOT%\failed" mkdir "%ROOT%\failed"
if not exist "%ROOT%\home" mkdir "%ROOT%\home"

:ensure_devdrive
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\ensure_devdrive.ps1" >nul 2>&1
set "DEV_RC=!ERRORLEVEL!"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\update_worker_ready.ps1" -Version "%VERSION%" >nul 2>&1
if "!DEV_RC!"=="0" goto ensure_prereqs
>"%LOCAL_STATUS%.tmp" echo {"ready":false,"state":"WAITING_DEV_DRIVE","detail":"Persistenter Dev Drive D: wird erkannt/eingerichtet","worker_version":"%VERSION%"}
move /Y "%LOCAL_STATUS%.tmp" "%LOCAL_STATUS%" >nul
ping.exe -n 16 127.0.0.1 >nul
goto ensure_devdrive

:ensure_prereqs
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\ensure_defender_exclusions.ps1" -Quiet >nul 2>&1
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\ensure_vcredist.ps1" -Quiet >nul 2>&1
set "VC_RC=!ERRORLEVEL!"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\update_worker_ready.ps1" -Version "%VERSION%" >nul 2>&1
if not "!VC_RC!"=="0" goto vc_wait
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\ensure_build_memory.ps1" >nul 2>&1
set "MEM_RC=!ERRORLEVEL!"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\update_worker_ready.ps1" -Version "%VERSION%" >nul 2>&1
if "!MEM_RC!"=="0" goto loop
goto pagefile_wait

:vc_wait
>"%LOCAL_STATUS%.tmp" echo {"ready":false,"state":"WAITING_VC_RUNTIME","detail":"Microsoft Visual C++ Runtime x86/x64 wird geprüft/installiert","worker_version":"%VERSION%"}
move /Y "%LOCAL_STATUS%.tmp" "%LOCAL_STATUS%" >nul
ping.exe -n 31 127.0.0.1 >nul
goto ensure_prereqs

:pagefile_wait
>"%LOCAL_STATUS%.tmp" echo {"ready":false,"state":"WAITING_PAGEFILE","detail":"Windows Commit-Limit / Pagefile - ggf. VM-Neustart erforderlich","worker_version":"%VERSION%"}
move /Y "%LOCAL_STATUS%.tmp" "%LOCAL_STATUS%" >nul
ping.exe -n 31 127.0.0.1 >nul
goto ensure_prereqs

:loop
if not exist "%SHARE%\" goto share_missing
for %%D in (status logs artifacts) do if not exist "%SHARE%\%%D" mkdir "%SHARE%\%%D" >nul 2>&1
set "JOB="
set /a COUNT=0
for %%F in ("%ROOT%\jobs\*.json") do if exist "%%~fF" (set /a COUNT+=1& if not defined JOB set "JOB=%%~nxF")
>"%LOCAL_STATUS%.tmp" echo {"ready":true,"state":"IDLE","detail":"Firefox Build Worker wartet auf SFTP-Jobs","worker_version":"%VERSION%","queue_visible":!COUNT!}
move /Y "%LOCAL_STATUS%.tmp" "%LOCAL_STATUS%" >nul
>"%SHARE%\worker_status.tmp" echo {"ready":true,"state":"IDLE","detail":"Firefox Build Worker wartet auf SFTP-Jobs","worker_version":"%VERSION%","queue_visible":!COUNT!}
move /Y "%SHARE%\worker_status.tmp" "%SHARE%\worker_status.json" >nul
if not defined JOB goto sleep

rem Re-check the persistent Dev Drive and required x86/x64 runtime before claiming a build.
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\ensure_devdrive.ps1" >nul 2>&1
if errorlevel 1 goto ensure_devdrive
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\ensure_vcredist.ps1" -Quiet >nul 2>&1
if errorlevel 1 goto ensure_prereqs
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\ensure_build_memory.ps1" >nul 2>&1
if errorlevel 1 goto ensure_prereqs
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\update_worker_ready.ps1" -Version "%VERSION%" >nul 2>&1

set "JOBID=!JOB:.json=!"
move /Y "%ROOT%\jobs\!JOB!" "%ROOT%\processing\!JOB!" >nul || goto sleep
>"%SHARE%\status\!JOBID!.tmp" echo {"id":"!JOBID!","status":"CLAIMED"}
move /Y "%SHARE%\status\!JOBID!.tmp" "%SHARE%\status\!JOBID!.json" >nul
>"%LOCAL_STATUS%.tmp" echo {"ready":true,"state":"BUILDING","detail":"Firefox Build !JOBID!","job_id":"!JOBID!","worker_version":"%VERSION%"}
move /Y "%LOCAL_STATUS%.tmp" "%LOCAL_STATUS%" >nul
>"%SHARE%\worker_status.tmp" echo {"ready":true,"state":"BUILDING","detail":"Firefox Build !JOBID!","job_id":"!JOBID!","worker_version":"%VERSION%"}
move /Y "%SHARE%\worker_status.tmp" "%SHARE%\worker_status.json" >nul
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\dispatch_build.ps1" -JobFile "%ROOT%\processing\!JOB!" -ShareRoot "%SHARE%"
set "BUILD_RC=!ERRORLEVEL!"
if not "!BUILD_RC!"=="0" powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%ROOT%\mark_job_failed.ps1" -JobId "!JOBID!" -ShareRoot "%SHARE%" -ExitCode !BUILD_RC! >nul 2>&1
if "!BUILD_RC!"=="0" (del /Q "%ROOT%\processing\!JOB!" >nul 2>&1) else (move /Y "%ROOT%\processing\!JOB!" "%ROOT%\failed\!JOB!" >nul 2>&1)
goto loop

:share_missing
>"%LOCAL_STATUS%.tmp" echo {"ready":false,"state":"WAITING_SHARE","detail":"\\\\host.lan\\Data nicht erreichbar","worker_version":"%VERSION%"}
move /Y "%LOCAL_STATUS%.tmp" "%LOCAL_STATUS%" >nul
:sleep
ping.exe -n 6 127.0.0.1 >nul
goto loop
