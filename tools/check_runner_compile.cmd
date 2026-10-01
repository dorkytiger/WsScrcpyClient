@echo off
rem One-off compile check for the Windows runner sources under the project's flags
rem (/W4 /WX /utf-8), used because the DSH sandbox blocks the flutter tool's child
rem process pipes. Produces .obj only (no link).
setlocal
cd /d "%~dp0.."
if not exist ".tmp\compilecheck" mkdir ".tmp\compilecheck"
set "TEMP=%CD%\.tmp\compilecheck"
set "TMP=%CD%\.tmp\compilecheck"
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1

set "SRC=windows\runner\flutter_window.cpp windows\runner\decoder_log.cpp windows\runner\d3d11_video_presenter.cpp windows\runner\scrcpy_pixel_store.cpp windows\runner\scrcpy_video_decoder.cpp windows\runner\yuv_to_rgba.cpp windows\runner\utils.cpp windows\runner\win32_window.cpp"
set "INC=/Iwindows\runner /Iwindows\flutter\ephemeral /Iwindows\flutter\ephemeral\cpp_client_wrapper\include /Iwindows"
set "DEF=/DNOMINMAX /DUNICODE /D_UNICODE /DFLUTTER_VERSION=\"1.0.0\" /DFLUTTER_VERSION_MAJOR=1 /DFLUTTER_VERSION_MINOR=0 /DFLUTTER_VERSION_PATCH=0 /DFLUTTER_VERSION_BUILD=0"

del /q ".tmp\compilecheck\*.obj" 2>nul
cl /nologo /c /EHsc /std:c++17 /W4 /WX /utf-8 /Od /MDd %DEF% %INC% %SRC% /Fo:.tmp\compilecheck\
if errorlevel 1 (
  echo COMPILE_CHECK: FAIL
  exit /b 1
)
echo COMPILE_CHECK: PASS
exit /b 0
