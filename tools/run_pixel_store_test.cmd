@echo off
rem Build and run the native-decoder self-test twice: plain /Od, and with
rem AddressSanitizer. It covers PixelBufferStore ownership (Grant /
rem release_callback) plus the log-file mechanism (created / flushed /
rem truncated), i.e. the two parts of the Windows decode path that do NOT
rem need Media Foundation, a device, or a real server.
rem See tools/pixel_store_test.cpp, windows/runner/scrcpy_pixel_store.{h,cpp},
rem windows/runner/decoder_log.{h,cpp}.
rem
rem NOTE: keep this file ASCII-only (cmd.exe parses .cmd with the OEM code page).
setlocal

cd /d "%~dp0.."
if not exist ".tmp\pixeltest" mkdir ".tmp\pixeltest"
if not exist ".tmp\pixeltest\asan" mkdir ".tmp\pixeltest\asan"

set "TEMP=%CD%\.tmp\pixeltest"
set "TMP=%CD%\.tmp\pixeltest"

call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
  echo [ERROR] vcvars64.bat not found. Adjust the path in this script.
  exit /b 1
)

set "SRC=tools\pixel_store_test.cpp windows\runner\scrcpy_pixel_store.cpp windows\runner\decoder_log.cpp"
rem Needs the flutter C header (flutter_texture_registrar.h, in the ephemeral
rem root) and the C++ wrapper header (flutter/texture_registrar.h).
set "INC=/Iwindows\runner /Iwindows\flutter\ephemeral /Iwindows\flutter\ephemeral\cpp_client_wrapper\include"
set "FAILED="

rem Always build from scratch: MSVC's incremental logic has, in this repo,
rem silently reused stale .obj files (fresh .exe timestamps but old code, which
rem made the self-test report results from a previous revision). The build is
rem a couple of seconds, so correctness beats incremental speed here.
del /q ".tmp\pixeltest\*.obj" 2>nul
del /q ".tmp\pixeltest\*.exe" 2>nul
del /q ".tmp\pixeltest\*.pdb" 2>nul
del /q ".tmp\pixeltest\asan\*.obj" 2>nul
del /q ".tmp\pixeltest\asan\*.exe" 2>nul
del /q ".tmp\pixeltest\asan\*.pdb" 2>nul

echo ==== plain build (/Od + canary bytes) ====
cl /nologo /EHsc /std:c++17 /W4 /utf-8 /Od /MDd %INC% %SRC% /Fo:.tmp\pixeltest\ /Fe:.tmp\pixeltest\pixel_store_test.exe
if errorlevel 1 (
  echo [ERROR] plain build failed.
  exit /b 1
)

rem Run from the repo root: the test writes .tmp\pixeltest\pixel_store_test.log
.tmp\pixeltest\pixel_store_test.exe
if errorlevel 1 set FAILED=1

echo.
echo ==== AddressSanitizer build ====
cl /nologo /EHsc /std:c++17 /W4 /utf-8 /Od /MDd /fsanitize=address %INC% %SRC% /Fo:.tmp\pixeltest\asan\ /Fe:.tmp\pixeltest\pixel_store_test_asan.exe >.tmp\pixeltest\build_asan.log 2>&1
if errorlevel 1 (
  echo ==== AddressSanitizer unavailable, skipped (build log tail) ====
  powershell -NoProfile -Command "Get-Content .tmp\pixeltest\build_asan.log -Tail 5"
) else (
  .tmp\pixeltest\pixel_store_test_asan.exe
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
