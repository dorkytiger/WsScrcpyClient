@echo off
rem Build and run the H.264 decoder MFT negotiation probe
rem (tools\mft_negotiate_probe.cpp). Offline: no device, no server, no Flutter.
rem
rem NOTE: keep this file ASCII-only (cmd.exe parses .cmd with the OEM code page).
setlocal

cd /d "%~dp0.."
if not exist ".tmp\mftprobe" mkdir ".tmp\mftprobe"
set "TEMP=%CD%\.tmp\mftprobe"
set "TMP=%CD%\.tmp\mftprobe"

call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
  echo [ERROR] vcvars64.bat not found. Adjust the path in this script.
  exit /b 1
)

del /q ".tmp\mftprobe\*.obj" 2>nul
del /q ".tmp\mftprobe\*.exe" 2>nul

cl /nologo /EHsc /std:c++17 /W4 /utf-8 /Od /MDd tools\mft_negotiate_probe.cpp /Fo:.tmp\mftprobe\ /Fe:.tmp\mftprobe\mft_negotiate_probe.exe /link mfplat.lib mfuuid.lib wmcodecdspuuid.lib ole32.lib
if errorlevel 1 (
  echo [ERROR] build failed.
  exit /b 1
)

.tmp\mftprobe\mft_negotiate_probe.exe
exit /b %errorlevel%
