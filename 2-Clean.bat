@echo off
chcp 65001 >nul
title 360 Cleanup - CLEAN

rem Admin check: avoid "net session" (Server service is off in Safe Mode -> false negative)
set "ADMIN="
fltmc >nul 2>&1 && set "ADMIN=1"
if not defined ADMIN (
    whoami /groups 2>nul | findstr /c:"S-1-16-12288" >nul && set "ADMIN=1"
)

if defined ADMIN goto run

if /i "%~1"=="/e" (
    echo Still not elevated.
    echo Right-click 2-Clean.bat and choose "Run as administrator".
    pause
    exit /b 1
)
echo Requesting administrator privileges...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '/e' -Verb RunAs"
exit /b

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Clean-360.ps1" -Mode Clean
echo.
pause
