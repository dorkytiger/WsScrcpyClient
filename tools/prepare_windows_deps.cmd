@echo off
rem Wrapper so users do not have to fight the PowerShell execution policy.
rem Usage: tools\prepare_windows_deps.cmd
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0prepare_windows_deps.ps1" %*
exit /b %errorlevel%
