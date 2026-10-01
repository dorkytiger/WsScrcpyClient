@echo off
rem Build and run the D3D11 GPU-present self-test (tools\d3d11_present_test.cpp).
rem
rem It needs no device and no server: it synthesises NV12 frames, pushes them
rem through the real presenter (D3D11 device + shader + shared texture), reads
rem the shared texture back on the CPU and compares pixel by pixel against the
rem CPU reference implementation (yuv_to_rgba.cpp). That is how the GPU path is
rem verified before it ever runs on a phone.
rem
rem Two builds: plain /Od (canary-ish sanity) and AddressSanitizer (catches the
rem NV12 repack reading out of bounds, which is exactly the class of bug that
rem crashed the first real-device run).
rem
rem NOTE: keep this file ASCII-only (cmd.exe parses .cmd with the OEM code page).
setlocal

cd /d "%~dp0.."
if not exist ".tmp\d3d11test" mkdir ".tmp\d3d11test"
if not exist ".tmp\d3d11test\asan" mkdir ".tmp\d3d11test\asan"

set "TEMP=%CD%\.tmp\d3d11test"
set "TMP=%CD%\.tmp\d3d11test"

call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
  echo [ERROR] vcvars64.bat not found. Adjust the path in this script.
  exit /b 1
)

set "SRC=tools\d3d11_present_test.cpp windows\runner\d3d11_video_presenter.cpp windows\runner\decoder_log.cpp windows\runner\yuv_to_rgba.cpp"
set "INC=/Iwindows\runner /Iwindows\flutter\ephemeral"
set "LIBS=d3d11.lib dxgi.lib ole32.lib"
set "FAILED="

rem Always build from scratch: MSVC incremental builds have silently reused
rem stale .obj files in this repo (fresh .exe, old code).
del /q ".tmp\d3d11test\*.obj" 2>nul
del /q ".tmp\d3d11test\*.exe" 2>nul
del /q ".tmp\d3d11test\*.pdb" 2>nul
del /q ".tmp\d3d11test\asan\*.obj" 2>nul
del /q ".tmp\d3d11test\asan\*.exe" 2>nul
del /q ".tmp\d3d11test\asan\*.pdb" 2>nul

echo ==== plain build (/Od) ====
cl /nologo /EHsc /std:c++17 /W4 /utf-8 /Od /MDd %INC% %SRC% /Fo:.tmp\d3d11test\ /Fe:.tmp\d3d11test\d3d11_present_test.exe /link %LIBS%
if errorlevel 1 (
  echo [ERROR] plain build failed.
  exit /b 1
)

.tmp\d3d11test\d3d11_present_test.exe
if errorlevel 1 set FAILED=1

echo.
echo ==== AddressSanitizer build ====
cl /nologo /EHsc /std:c++17 /W4 /utf-8 /Od /MDd /fsanitize=address %INC% %SRC% /Fo:.tmp\d3d11test\asan\ /Fe:.tmp\d3d11test\d3d11_present_test_asan.exe /link %LIBS% >.tmp\d3d11test\build_asan.log 2>&1
if errorlevel 1 (
  echo ==== AddressSanitizer unavailable, skipped (build log tail) ====
  powershell -NoProfile -Command "Get-Content .tmp\d3d11test\build_asan.log -Tail 5"
) else (
  .tmp\d3d11test\d3d11_present_test_asan.exe
  if errorlevel 1 set FAILED=1
)

if defined FAILED (
  echo.
  echo RESULT: FAIL
  exit /b 1
)
echo.
echo RESULT: PASS
endlocal
exit /b 0
