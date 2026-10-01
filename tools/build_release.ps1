<#
.SYNOPSIS
    本机打包发行产物到 dist\：Windows 桌面 zip 与/或 Android APK。

.DESCRIPTION
    与 .forgejo/workflows/build.yml 走**同一套步骤**，用途是：
      * 你还没有 Windows runner 时，Windows 包在这里出（Flutter 的 Windows 产物**只能**在 Windows 上构建）；
      * CI 出问题时的本地对照——同样命令、同样产物命名，方便"CI 挂了但本机能过"的快速定位。

    产物（dist\ 目录，已被 .gitignore 忽略）：
      ws_scrcpy_client-<版本>-windows-x64.zip
      ws_scrcpy_client-<版本>.apk

.EXAMPLE
    tools\build_release.cmd -Platform both
    tools\build_release.cmd -Platform windows -Version 1.2.3 -BuildNumber 7
    tools\build_release.cmd -Platform android -SkipTests
#>
[CmdletBinding()]
param(
    [ValidateSet('windows', 'android', 'both')]
    [string]$Platform = 'both',

    # 版本名（形如 1.2.3）。不给就取 pubspec.yaml 的 version 前缀。
    [string]$Version,

    # 版本号（Android versionCode / Windows 文件版本）。不给就用 pubspec 的 +N。
    [int]$BuildNumber = -1,

    # 跳过 analyze / test（只想赶紧出包时用）
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $scriptDir
Set-Location $repo

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

function Get-FlutterExe {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($env:FLUTTER_ROOT) {
        $candidate = Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat'
        if (Test-Path $candidate) { return $candidate }
    }
    throw '找不到 flutter：请把 Flutter 的 bin 目录加进 PATH，或设置 FLUTTER_ROOT'
}

# pubspec.yaml 里的 version: 1.0.0+1
$pubspec = Get-Content (Join-Path $repo 'pubspec.yaml') -Encoding UTF8
$versionLine = $pubspec | Where-Object { $_ -match '^version:\s*(.+)$' } | Select-Object -First 1
$pubVersion = '1.0.0'
$pubBuild = 0
if ($versionLine -match '^version:\s*([0-9][^+\s]*)(?:\+(\d+))?') {
    $pubVersion = $Matches[1]
    if ($Matches[2]) { $pubBuild = [int]$Matches[2] }
}
if (-not $Version) { $Version = $pubVersion }
if ($BuildNumber -lt 0) { $BuildNumber = $pubBuild }

$flutter = Get-FlutterExe
$dist = Join-Path $repo 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

Write-Step "仓库：$repo"
Write-Step "Flutter：$flutter"
Write-Step "版本：$Version+$BuildNumber   目标：$Platform"

Write-Step '拉依赖'
& $flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'flutter pub get 失败' }

if (-not $SkipTests) {
    Write-Step '静态检查'
    & $flutter analyze lib test tools
    if ($LASTEXITCODE -ne 0) { throw 'dart analyze 未通过' }
    Write-Step '单测'
    & $flutter test
    if ($LASTEXITCODE -ne 0) { throw 'flutter test 未通过' }
} else {
    Write-Step '（跳过 analyze / test）'
}

$built = @()

if ($Platform -in @('windows', 'both')) {
    Write-Step 'Windows：准备原生依赖（WebView2 / WIL）'
    # -Online：允许从 nuget.org 取包（干净机器/新克隆的仓库没有本机 NuGet 缓存）。
    # 已经取过就直接复用，脚本是幂等的。
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'prepare_windows_deps.ps1') -Online
    if ($LASTEXITCODE -ne 0) { throw '原生依赖准备失败' }

    Write-Step 'Windows：构建 Release'
    & $flutter build windows --release "--build-name=$Version" "--build-number=$BuildNumber"
    if ($LASTEXITCODE -ne 0) { throw 'flutter build windows 失败' }

    Write-Step 'Windows：打包 zip'
    $src = Join-Path $repo 'build\windows\x64\runner\Release'
    if (-not (Test-Path $src)) { throw "没找到构建产物：$src" }
    $zip = Join-Path $dist "ws_scrcpy_client-$Version-windows-x64.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path "$src\*" -DestinationPath $zip -CompressionLevel Optimal
    $built += [pscustomobject]@{ 产物 = (Split-Path $zip -Leaf); MB = [math]::Round((Get-Item $zip).Length / 1MB, 1) }
}

if ($Platform -in @('android', 'both')) {
    Write-Step 'Android：构建 Release APK'
    & $flutter build apk --release "--build-name=$Version" "--build-number=$BuildNumber"
    if ($LASTEXITCODE -ne 0) { throw 'flutter build apk 失败' }

    Write-Step 'Android：整理产物'
    $apkDir = Join-Path $repo 'build\app\outputs\flutter-apk'
    $apks = Get-ChildItem $apkDir -Filter *.apk -ErrorAction SilentlyContinue
    if (-not $apks) { throw "没找到 APK：$apkDir" }
    foreach ($apk in $apks) {
        $abi = $apk.BaseName -replace '^app-', ''
        $suffix = if ($abi -eq 'release') { '' } else { "-$abi" }
        $target = Join-Path $dist "ws_scrcpy_client-$Version$suffix.apk"
        Copy-Item $apk.FullName $target -Force
        $built += [pscustomobject]@{ 产物 = (Split-Path $target -Leaf); MB = [math]::Round($apk.Length / 1MB, 1) }
    }
}

Write-Host ''
Write-Step "完成，产物在 $dist"
$built | Format-Table -AutoSize
Write-Host '提示：Android 目前是 debug 签名（见 docs/ci.md §6），要上架/正式分发得换成自己的 keystore。'
