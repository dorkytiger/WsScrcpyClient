@echo off
rem Build the NV12->RGBA benchmark twice (/Od like Debug, /O2 like Release) and
rem run both. See tools/nv12_convert_bench.cpp.
rem
rem Why /Od vs /O2: `flutter run` uses the Debug build, which has no optimization,
rem and the whole YUV->RGB conversion is scalar CPU work on the decode thread.
rem This measures how bad that actually is at the sizes we see in practice.
rem
rem The benchmark links the REAL conversion (windows/runner/yuv_to_rgba.cpp), so
rem there is no second copy of the logic to keep in sync.
rem
rem NOTE: keep this file ASCII-only AND CRLF-terminated (cmd.exe parses .cmd with
rem the OEM code page; LF-only line endings make it misparse into garbage commands).
setlocal

cd /d "%~dp0.."
if not exist ".tmp\nv12bench" mkdir ".tmp\nv12bench"

set "TEMP=%CD%\.tmp\nv12bench"
set "TMP=%CD%\.tmp\nv12bench"

call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
  echo [ERROR] vcvars64.bat not found. Adjust the path in this script.
  exit /b 1
)

set "SOURCES=..\..\tools\nv12_convert_bench.cpp ..\..\windows\runner\yuv_to_rgba.cpp"

pushd ".tmp\nv12bench"
cl /nologo /EHsc /std:c++17 /W4 /utf-8 /Od /Fe:bench_od.exe %SOURCES% >build_od.log 2>&1
if errorlevel 1 ( echo [ERROR] /Od build failed: & type build_od.log & popd & exit /b 1 )
cl /nologo /EHsc /std:c++17 /W4 /utf-8 /O2 /Fe:bench_o2.exe %SOURCES% >build_o2.log 2>&1
if errorlevel 1 ( echo [ERROR] /O2 build failed: & type build_o2.log & popd & exit /b 1 )
popd

".tmp\nv12bench\bench_od.exe" "Debug(/Od, same as flutter run default)"
echo.
".tmp\nv12bench\bench_o2.exe" "Release(/O2)"
endlocal
