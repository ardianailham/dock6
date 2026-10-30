@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0dockerize_windows.ps1" %*
exit /b %ERRORLEVEL%
