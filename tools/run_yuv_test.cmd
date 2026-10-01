@echo off
rem Build and run the YUV->RGBA boundary self-test twice: plain, and with
rem AddressSanitizer (catches out-of-bounds even without the canary bytes).
rem See tools/yuv_to_rgba_test.cpp and windows/runner/yuv_to_rgba.h.
rem
rem NOTE: keep this file ASCII-only (cmd.exe parses .cmd with the OEM code page).
setlocal

cd /d "%~dp0.."
if not exist ".tmp\yuvtest" mkdir ".tmp\yuvtest"

set "TEMP=%CD%\.tmp\yuvtest"
set "TMP=%CD%\.tmp\yuvtest"

call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
  echo [ERROR] vcvars64.bat not found. Adjust the path in this script.
  exit /b 1
)

set "SRC=..\..\tools\yuv_to_rgba_test.cpp ..\..\windows\runner\yuv_to_rgba.cpp"
set "INC=/I..\..\windows\runner"
set "FAILED="

pushd ".tmp\yuvtest"

cl /nologo /EHsc /std:c++17 /W4 /utf-8 /Od %INC% %SRC% /Fe:yuv_test.exe >build.log 2>&1
if errorlevel 1 (
  echo [ERROR] plain build failed:
  type build.log
  popd
  exit /b 1
)
echo ==== plain build (/Od + canary bytes) ====
yuv_test.exe
if errorlevel 1 set FAILED=1

echo.
cl /nologo /EHsc /std:c++17 /W4 /utf-8 /Od /fsanitize=address %INC% %SRC% /Fe:yuv_test_asan.exe >build_asan.log 2>&1
if errorlevel 1 (
  echo ==== AddressSanitizer unavailable, skipped (build log tail) ====
  powershell -NoProfile -Command "Get-Content build_asan.log -Tail 5"
) else (
  echo ==== AddressSanitizer build ====
  yuv_test_asan.exe
  if errorlevel 1 set FAILED=1

  echo.
  echo ==== Root-cause proof: run the OLD logic and expect ASan to catch it ====
  yuv_test_asan.exe --reproduce-old-bug
  if errorlevel 1 (
    echo    ^(expected: ASan reported heap-buffer-overflow, which is the proof^)
  ) else (
    echo    [FAIL] the old logic did NOT trip ASan - the reproduction is not faithful
    set FAILED=1
  )
)

popd

if defined FAILED (
  echo.
  echo RESULT: FAIL
  exit /b 1
)
echo.
echo RESULT: PASS
rem The ASan proof run above intentionally exits non-zero; make sure the script
rem itself reports success (otherwise CI/users see a failure for a passing run).
endlocal
exit /b 0
