<#
.SYNOPSIS
  离线/受限环境下的 Android 构建前置：把插件 buildscript 里 pin 的 AGP 版本对齐到"本机缓存里有的那个"。

.DESCRIPTION
  现象（2026-10-08 实测）：`flutter build apk` 在离线环境里失败于

      Could not get resource 'https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/8.5.0/gradle-8.5.0.pom'
        > Remote host terminated the handshake
      'kotlin-android' plugin requires one of the Android Gradle plugins.
        Please apply one of the following plugins to ':path_provider_android' project ...

  根因不是我们的工程，而是**插件的 android/build.gradle 自带 buildscript classpath**：

      path_provider_android-2.2.17/android/build.gradle:
        buildscript { dependencies { classpath 'com.android.tools.build:gradle:8.5.0' } }

  这个 classpath 是**子项目自己的**（不继承根工程的 AGP 版本），所以它必须能解析；
  而本机 Gradle 缓存里只有 8.5.1 / 8.11.1 / 8.12.1 / 8.13.1 / 9.1.0，**没有 8.5.0**
  → 只要不能联网，构建就卡在这里，和我们自己的代码无关。

  本脚本做的事（幂等）：扫描 pub 缓存里各插件的 `android/build.gradle`，
  凡是 pin 了"缓存里没有的 AGP 版本"的，就把它改成**缓存里最高的那个版本**；
  已经是可用版本 / 没有 pin 的都不动。改完打印每一处改动，便于复核。

.NOTES
  - 只改 **pub 缓存**（机器本地，不进仓库）；`flutter pub get` 不重新解包就不会被覆盖。
  - 这是环境修复，不是产品代码：换一台能联网的机器就不需要跑它。
  - 与 `tools/prepare_windows_deps.cmd`（Windows 的离线 NuGet 链路）是同一类前置。
#>
[CmdletBinding()]
param(
  [string]$PubCache = "",
  [string]$GradleCache = "",
  [switch]$WhatIfOnly
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($PubCache)) {
  $PubCache = Join-Path $env:LOCALAPPDATA "Pub\Cache\hosted\pub.dev"
}
if ([string]::IsNullOrWhiteSpace($GradleCache)) {
  $GradleCache = Join-Path $env:USERPROFILE ".gradle\caches\modules-2\files-2.1\com.android.tools.build\gradle"
}

if (-not (Test-Path $PubCache)) {
  Write-Host "COMPILE_PREREQ: SKIP - 找不到 pub 缓存：$PubCache"
  exit 0
}
if (-not (Test-Path $GradleCache)) {
  Write-Host "COMPILE_PREREQ: SKIP - 找不到 Gradle 里的 AGP 缓存：$GradleCache"
  exit 0
}

# 本机缓存里可用的 AGP 版本（按版本号排序，取最高）。
$available = Get-ChildItem $GradleCache -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
  ForEach-Object { [version]$_.Name } |
  Sort-Object
if ($available.Count -eq 0) {
  Write-Host "COMPILE_PREREQ: FAIL - Gradle 缓存里没有任何 AGP 版本（需要先联网构建一次）"
  exit 1
}
$fallback = ($available | Select-Object -Last 1).ToString()
$availableText = ($available | ForEach-Object { $_.ToString() }) -join ", "
Write-Host "本机可用的 AGP：$availableText；回退选 $fallback"
$changed = 0
$scanned = 0
Get-ChildItem $PubCache -Directory | ForEach-Object {
  $buildGradle = Join-Path $_.FullName "android\build.gradle"
  if (-not (Test-Path $buildGradle)) { return }
  $scanned++
  $text = Get-Content $buildGradle -Raw
  $matches = [regex]::Matches($text, "com\.android\.tools\.build:gradle:([0-9][0-9.]*)")
  if ($matches.Count -eq 0) { return }
  $pinned = $matches[0].Groups[1].Value
  if ($available | Where-Object { $_.ToString() -eq $pinned }) { return }

  # 选"**不小于** pin 值的最小缓存版本"：跨大版本（比如把 8.0.2 直接抬到 9.1.0）风险更大，
  # 插件的 build.gradle 是按当时的 AGP DSL 写的。只有缓存里全都比 pin 值小，才退到最高版本。
  $pinnedVersion = [version]$pinned
  $notOlder = $available | Where-Object { $_ -ge $pinnedVersion }
  $target = if ($notOlder) { ($notOlder | Select-Object -First 1).ToString() } else { $fallback }

  if ($WhatIfOnly) {
    Write-Host "WOULD FIX  $($_.Name)：AGP $pinned → $target"
    return
  }
  $patched = $text -replace "com\.android\.tools\.build:gradle:$([regex]::Escape($pinned))",
                             "com.android.tools.build:gradle:$target"
  # 显式 UTF-8 **不带 BOM** 写回：Gradle 的构建脚本对 BOM 敏感度不高，但没必要冒这个险
  # （也避免 Windows PowerShell 5.1 的 `-Encoding utf8` 偷偷加 BOM）。
  [System.IO.File]::WriteAllText(
    $buildGradle, $patched, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "FIXED      $($_.Name)：AGP $pinned → $target（缓存里没有 $pinned）"
  $changed++
}

Write-Host "COMPILE_PREREQ: 扫描插件 $scanned 个，修正 $changed 个"
if ($changed -eq 0) {
  Write-Host "COMPILE_PREREQ: PASS（无需改动；插件 pin 的 AGP 版本本机都有）"
} else {
  Write-Host "COMPILE_PREREQ: PASS（已对齐到本机缓存里可用的 AGP 版本）"
}
