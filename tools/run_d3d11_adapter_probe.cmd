@echo off
rem Adapter probe: can a legacy DXGI shared handle be opened across adapters?
rem (tools\d3d11_adapter_probe.cpp). Pure measurement, no Flutter, no device.
rem
rem NOTE: keep this file ASCII-only (cmd.exe parses .cmd with the OEM code page).
setlocal

cd /d "%~dp0.."
if not exist ".tmp\adapterprobe" mkdir ".tmp\adapterprobe"
set "TEMP=%CD%\.tmp\adapterprobe"
set "TMP=%CD%\.tmp\adapterprobe"

call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
  echo [ERROR] vcvars64.bat not found. Adjust the path in this script.
  exit /b 1
)

cl /nologo /EHsc /std:c++17 /W4 /utf-8 /Od /MD tools\d3d11_adapter_probe.cpp /Fo:.tmp\adapterprobe\ /Fe:.tmp\adapterprobe\d3d11_adapter_probe.exe /link d3d11.lib dxgi.lib ole32.lib
if errorlevel 1 (
  echo [ERROR] build failed.
  exit /b 1
)

.tmp\adapterprobe\d3d11_adapter_probe.exe
exit /b %errorlevel%
