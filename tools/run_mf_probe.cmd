@echo off
rem Build and run the Media Foundation output-sample-ownership probe.
rem See tools/mf_output_sample_probe.cpp for why this exists.
rem
rem Intermediate files go under .tmp\ on purpose: in restricted environments
rem %TEMP% is not writable and cl.exe fails there.
rem
rem NOTE: keep this file ASCII-only. cmd.exe parses .cmd scripts using the OEM
rem code page, so non-ASCII comments break the script.
setlocal

cd /d "%~dp0.."
if not exist ".tmp\mfprobe" mkdir ".tmp\mfprobe"

set "TEMP=%CD%\.tmp\mfprobe"
set "TMP=%CD%\.tmp\mfprobe"

call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
  echo [ERROR] vcvars64.bat not found. Adjust the path in this script.
  exit /b 1
)

pushd ".tmp\mfprobe"
cl /nologo /EHsc /std:c++17 /W4 /Fe:mf_probe.exe "..\..\tools\mf_output_sample_probe.cpp" /link mfplat.lib mfuuid.lib wmcodecdspuuid.lib ole32.lib >build.log 2>&1
if errorlevel 1 (
  echo [ERROR] build failed, log:
  type build.log
  popd
  exit /b 1
)
popd

".tmp\mfprobe\mf_probe.exe" "test/fixtures/stream_first_video_frames.txt"
endlocal
