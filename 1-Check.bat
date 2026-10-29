@echo off
chcp 65001 >nul
title 360 Cleanup - CHECK (read only)
echo Running read-only scan. Nothing will be changed.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Clean-360.ps1"
echo.
pause
