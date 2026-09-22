@echo off
title PC Cleanup + Optimize
cd /d "%~dp0"
where pwsh >nul 2>&1
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0pc-cleanup.ps1" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pc-cleanup.ps1" %*
)
if errorlevel 1 pause
