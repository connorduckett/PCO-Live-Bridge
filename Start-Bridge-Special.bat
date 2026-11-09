@echo off
title PCO Live Bridge - Special Services
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PcoLiveBridge.ps1" -ConfigPath "%~dp0config-special.json" %*
pause
