@echo off
rem Wrapper so users do not have to fight the PowerShell execution policy.
rem Usage: tools\build_release.cmd -Platform both [-Version 1.2.3] [-SkipTests]
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_release.ps1" %*
exit /b %errorlevel%
