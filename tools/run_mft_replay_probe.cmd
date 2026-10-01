@echo off
rem Build and run the offline frame-replay probe (tools\mft_replay_probe.cpp).
rem
rem Usage: tools\run_mft_replay_probe.cmd [capture.bin]
rem   default capture path: .probe\capture.bin
rem
rem The capture comes from either:
rem   set WS_CAPTURE_FRAMES=<path>   (app: frames fed to the decoder)
rem   set WS_PROBE_CAPTURE=<path>    (dart run tools/probe.dart)
rem
rem NOTE: keep this file ASCII-only (cmd.exe parses .cmd with the OEM code page).
setlocal

cd /d "%~dp0.."
if not exist ".tmp\mftreplay" mkdir ".tmp\mftreplay"
set "TEMP=%CD%\.tmp\mftreplay"
set "TMP=%CD%\.tmp\mftreplay"

call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
  echo [ERROR] vcvars64.bat not found. Adjust the path in this script.
  exit /b 1
)

del /q ".tmp\mftreplay\*.obj" 2>nul
del /q ".tmp\mftreplay\*.exe" 2>nul

cl /nologo /EHsc /std:c++17 /W4 /utf-8 /Od /MDd tools\mft_replay_probe.cpp /Fo:.tmp\mftreplay\ /Fe:.tmp\mftreplay\mft_replay_probe.exe /link mfplat.lib mfuuid.lib wmcodecdspuuid.lib strmiids.lib oleaut32.lib ole32.lib
if errorlevel 1 (
  echo [ERROR] build failed.
  exit /b 1
)

if "%~1"=="" (
  .tmp\mftreplay\mft_replay_probe.exe
) else (
  .tmp\mftreplay\mft_replay_probe.exe "%~1"
)
exit /b %errorlevel%
