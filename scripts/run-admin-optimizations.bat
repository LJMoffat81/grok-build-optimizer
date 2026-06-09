@echo off
title Grok Build - Admin Optimizations
echo Requesting administrator privileges...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"\"%~dp0apply-optimizations.ps1\"\" -SkipDefender:$false'"
pause