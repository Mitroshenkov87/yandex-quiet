@echo off
rem Launcher: same arguments as Yandex-Quiet.ps1. The script self-elevates.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Yandex-Quiet.ps1" %*
