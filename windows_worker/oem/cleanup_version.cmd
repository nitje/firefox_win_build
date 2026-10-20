@echo off
setlocal
if "%~1"=="" exit /b 2
set "VERSION=%~1"
rd /S /Q "D:\mozilla-source\firefox-%VERSION%" >nul 2>&1
rd /S /Q "D:\firefox-builds\%VERSION%" >nul 2>&1
exit /b 0
