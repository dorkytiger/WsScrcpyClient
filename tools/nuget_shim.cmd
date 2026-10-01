@echo off
rem ---------------------------------------------------------------------------
rem webview_all_windows build-time dependency guard.
rem
rem Why this file exists:
rem   The plugin's CMakeLists runs, on EVERY build,
rem       nuget.exe install Microsoft.Web.WebView2 / Microsoft.Windows.ImplementationLibrary
rem   That step needs a writable %TEMP% (nuget creates %TEMP%\NuGetScratch\lock) and network
rem   access. Inside sandboxed / restricted shells both can fail, breaking the build with an
rem   unhelpful "MSB3073 ... exited with code 1".
rem
rem   windows\CMakeLists.txt presets the CMake NUGET cache variable to this shim, so
rem   find_program() in the plugin keeps it and never downloads or runs nuget.
rem
rem What it does:
rem   1. If the two packages are already expanded under build\windows\x64\packages, exit 0.
rem   2. Otherwise expand them from the offline copies in .tmp\nuget-source (created once by
rem      tools\prepare_windows_deps.cmd). flutter clean deletes build\ but not .tmp\, so
rem      a plain rebuild after clean keeps working with no manual step.
rem   3. If the offline copies are missing too, print an actionable message and fail.
rem
rem All arguments passed by the plugin (install ... -Version ...) are intentionally ignored.
rem ---------------------------------------------------------------------------
setlocal EnableExtensions

set "REPO=%~dp0.."
set "PKG=%REPO%\build\windows\x64\packages"
set "SRC=%REPO%\.tmp\nuget-source"

set "WIL_TARGETS=%PKG%\Microsoft.Windows.ImplementationLibrary\build\native\Microsoft.Windows.ImplementationLibrary.targets"
set "WEBVIEW_TARGETS=%PKG%\Microsoft.Web.WebView2\build\native\Microsoft.Web.WebView2.targets"

if exist "%WIL_TARGETS%" if exist "%WEBVIEW_TARGETS%" exit /b 0

set "WIL_PKG=%SRC%\Microsoft.Windows.ImplementationLibrary.1.0.220914.1.nupkg"
set "WEBVIEW_PKG=%SRC%\Microsoft.Web.WebView2.1.0.1418.22.nupkg"

if not exist "%WIL_PKG%" goto :missing
if not exist "%WEBVIEW_PKG%" goto :missing

echo [nuget_shim] Expanding WebView2 / WIL packages from .tmp\nuget-source ...
if not exist "%PKG%\Microsoft.Windows.ImplementationLibrary" mkdir "%PKG%\Microsoft.Windows.ImplementationLibrary"
if not exist "%PKG%\Microsoft.Web.WebView2" mkdir "%PKG%\Microsoft.Web.WebView2"

where tar.exe >nul 2>nul
if errorlevel 1 goto :expand_powershell

tar.exe -xf "%WIL_PKG%" -C "%PKG%\Microsoft.Windows.ImplementationLibrary"
if errorlevel 1 goto :failed
tar.exe -xf "%WEBVIEW_PKG%" -C "%PKG%\Microsoft.Web.WebView2"
if errorlevel 1 goto :failed
goto :verify

:expand_powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Expand-Archive -LiteralPath '%WIL_PKG%' -DestinationPath '%PKG%\Microsoft.Windows.ImplementationLibrary' -Force; Expand-Archive -LiteralPath '%WEBVIEW_PKG%' -DestinationPath '%PKG%\Microsoft.Web.WebView2' -Force"
if errorlevel 1 goto :failed

:verify
if not exist "%WIL_TARGETS%" goto :failed
if not exist "%WEBVIEW_TARGETS%" goto :failed
echo [nuget_shim] Dependencies ready.
exit /b 0

:missing
echo [nuget_shim] ERROR: WebView2 / WIL packages are missing.
echo [nuget_shim] Run this once (it only writes inside the project):
echo [nuget_shim]     tools\prepare_windows_deps.cmd
exit /b 1

:failed
echo [nuget_shim] ERROR: could not expand the offline packages under %PKG%
exit /b 1
