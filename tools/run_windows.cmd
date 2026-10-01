@echo off
rem ---------------------------------------------------------------------------
rem 在受限会话（沙箱 / 受限令牌）里启动 Windows 桌面版。
rem
rem 为什么需要它：
rem   1) 经工具链拉起的 App 进程写不了 %TEMP%，flutter run 会在 DevFS 阶段失败：
rem      _createDevFS: PathAccessException ... Temp (errno = 5)
rem      → 这里把 TEMP/TMP 指到工作区 .tmp\。
rem   2) 同一个进程也写不了 %APPDATA%，flutter_secure_storage 会报
rem      读取本地设置失败：PathAccessException ... com.example\ws_scrcpy_client
rem      → 这里用 --dart-define=WS_DATA_DIR 把 drift 数据库与其它应用数据放到 .tmp\appdata\；
rem         密码若仍写不进系统安全存储，会降级为"仅本次会话有效"并在界面提示。
rem
rem 普通终端（非受限环境）里直接 flutter run -d windows 即可，不需要本脚本。
rem 用法：tools\run_windows.cmd [额外的 flutter run 参数]
rem ---------------------------------------------------------------------------
setlocal EnableExtensions

set "REPO=%~dp0.."
if not exist "%REPO%\.tmp" mkdir "%REPO%\.tmp"
if not exist "%REPO%\.tmp\appdata" mkdir "%REPO%\.tmp\appdata"

set "TEMP=%REPO%\.tmp"
set "TMP=%REPO%\.tmp"

cd /d "%REPO%"
echo [run_windows] TEMP=%TEMP%
echo [run_windows] WS_DATA_DIR=%REPO%\.tmp\appdata
flutter run -d windows --dart-define=WS_DATA_DIR=%REPO%\.tmp\appdata %*
exit /b %errorlevel%
