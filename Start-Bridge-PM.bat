@echo off
title PCO Live Bridge - Sunday PM
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PcoLiveBridge.ps1" -ConfigPath "%~dp0config-pm.json" %*
pause
