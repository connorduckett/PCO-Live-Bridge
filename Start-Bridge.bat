@echo off
title PCO Live Bridge
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PcoLiveBridge.ps1" %*
pause
