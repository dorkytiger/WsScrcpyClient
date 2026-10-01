@echo off
rem Regression test for the stderr redirection safety fix
rem (tools\stderr_redirect_test.cpp).
rem
rem The probe binary is linked as a GUI subsystem app so that it has NO console,
rem exactly like the app when started from Visual Studio ("Windows (desktop)").
rem Results land in %TEMP%\ws_scrcpy_stderr_probe.txt; file landing is checked
rem with findstr on an ASCII marker (Chinese in .cmd is not encoding-safe).
rem
rem NOTE: keep this file ASCII-only (cmd.exe parses .cmd with the OEM code page).
setlocal enabledelayedexpansion

cd /d "%~dp0.."
if not exist ".tmp\stderrtest" mkdir ".tmp\stderrtest"
set "TEMP=%CD%\.tmp\stderrtest"
set "TMP=%CD%\.tmp\stderrtest"
set "PROBE=%TEMP%\ws_scrcpy_stderr_probe.txt"
set "TARGET=%TEMP%\ws_scrcpy_stderr_target.log"

call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
  echo [ERROR] vcvars64.bat not found. Adjust the path in this script.
  exit /b 1
)

set FAILED=0
set EXE=.tmp\stderrtest\stderr_probe.exe

for %%R in (MDd MD) do (
  echo.
  echo === runtime /%%R ^(GUI subsystem: no console^) ===
  cl /nologo /EHsc /std:c++17 /W4 /utf-8 /Od /%%R tools\stderr_redirect_test.cpp /Fo:.tmp\stderrtest\ /Fe:%EXE% /link /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup user32.lib
  if errorlevel 1 (
    echo [ERROR] build failed for /%%R
    exit /b 1
  )

  rem 1) The guard must never assert.
  del /q "%PROBE%" >nul 2>&1
  %EXE% --probe handle-guard
  if errorlevel 1 (
    echo [FAIL] handle-guard aborted: the guard is not safe
    set FAILED=1
  ) else (
    echo [ok]   handle-guard survived
  )

  rem 2) Root cause reproduction: failed _wfreopen_s(stderr) then write.
  del /q "%PROBE%" >nul 2>&1
  %EXE% --probe freopen-fail-then-write
  if errorlevel 1 (
    if "%%R"=="MDd" (
      echo [ok]   freopen-fail-then-write aborted on the debug CRT ^(this IS the write.cpp:50 assert^)
    ) else (
      echo [FAIL] freopen-fail-then-write aborted on the release CRT ^(unexpected^)
      set FAILED=1
    )
  ) else (
    if "%%R"=="MDd" (
      echo [FAIL] freopen-fail-then-write did NOT abort on the debug CRT: reproduction is not faithful
      set FAILED=1
    ) else (
      echo [ok]   freopen-fail-then-write did not abort on the release CRT ^(expected: assert is debug-only^)
    )
  )

  rem 3) The fix: redirect then write must not abort, and the marker must land.
  del /q "%PROBE%" >nul 2>&1
  del /q "%TARGET%" >nul 2>&1
  %EXE% --probe redirect-then-write
  if errorlevel 1 (
    echo [FAIL] redirect-then-write aborted or refused to redirect
    set FAILED=1
  ) else (
    findstr /c:"STDERR-REDIRECT-OK" "%TARGET%" >nul 2>&1
    if errorlevel 1 (
      echo [FAIL] redirect-then-write did not land the marker in the target file
      set FAILED=1
    ) else (
      echo [ok]   redirect-then-write survived and the marker landed in the file
    )
  )
)

echo.
if "%FAILED%"=="1" (
  echo RESULT: FAIL
  exit /b 1
)
echo RESULT: PASS
exit /b 0
