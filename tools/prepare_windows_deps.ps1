<#
.SYNOPSIS
    Prepare native dependencies (WebView2 + WIL) required by webview_all_windows builds.

.DESCRIPTION
    背景：插件自带的 CMake 依赖步骤每次构建都会执行
        nuget.exe install Microsoft.Web.WebView2 / Microsoft.Windows.ImplementationLibrary
    它有两个坑（本项目已实测踩到）：
      1) find_program(nuget) 找不到 nuget 时会联网下载 nuget.exe 并联网装包；
      2) nuget 默认把包缓存写到 %USERPROFILE%\.nuget，受限环境（沙箱 / 受限令牌）写失败，
         报错形如 MSB3073 ... "nuget.exe install ... 已退出，代码为 1"。

    本脚本把这条链改成"离线 + 只写工作区"：
      - 从本机 NuGet 全局缓存收拢两个 .nupkg 到 .tmp\nuget-source\；
      - 在仓库根生成 NuGet.Config（已在 .gitignore 中忽略），把包源指向该目录，
        并把 globalPackagesFolder 重定向到 .tmp\nuget-packages（都在工作区内）；
      - 把 nuget.exe 复制到 build\windows\x64\nuget.exe，省掉 CMake 的联网下载；
      - 预先把两个包装到 build\windows\x64\packages\。

    幂等，可反复执行；不修改 PATH，也不写工作区以外的任何位置。
    flutter clean 会删掉 build\windows\x64\packages，删掉后重新执行本脚本即可。

.EXAMPLE
    tools\prepare_windows_deps.cmd
#>
[CmdletBinding()]
param(
    # 仓库根目录，默认取本脚本所在目录的上一级。
    [string]$RepoRoot,

    # nuget.exe 的完整路径或所在目录；默认自动查找。
    [string]$NuGetPath
)

$ErrorActionPreference = 'Stop'

# 注意：$PSScriptRoot 在 param 默认值里可能为空（Windows PowerShell 5.1 行为），
# 因此在脚本体里解析；本脚本位于 <repo>\tools\ 下，仓库根是它的上一级。
if (-not $RepoRoot) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RepoRoot = Split-Path -Parent $scriptDir
}

$packageList = @(
    @{ Id = 'Microsoft.Windows.ImplementationLibrary'; Version = '1.0.220914.1' },
    @{ Id = 'Microsoft.Web.WebView2'; Version = '1.0.1418.22' }
)

function Write-Step([string]$Message) {
    Write-Host "==> $Message"
}

# 在候选位置里找 nuget.exe；找不到返回 $null（调用方给出可执行的修复提示）。
function Resolve-NuGetExe {
    param([string]$Explicit, [string]$Root)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Explicit) {
        $candidates.Add($Explicit)
        $candidates.Add((Join-Path $Explicit 'nuget.exe'))
    }
    $candidates.Add((Join-Path $Root 'build\windows\x64\nuget.exe'))
    $candidates.Add((Join-Path $env:USERPROFILE '.nuget\packages\nuget.commandline\5.10.0\tools\nuget.exe'))
    $candidates.Add('C:\Users\Warren\Dev\nuget\nuget.exe')
    $command = Get-Command nuget.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates.Add($command.Source) }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

# 本机 NuGet 全局缓存里的 .nupkg 路径。
function Get-CachedPackagePath {
    param([string]$Id, [string]$Version)
    $lower = $Id.ToLowerInvariant()
    return (Join-Path $env:USERPROFILE ".nuget\packages\$lower\$Version\$Id.$Version.nupkg")
}

$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$sourceDir = Join-Path $repo '.tmp\nuget-source'
$globalPackages = Join-Path $repo '.tmp\nuget-packages'
$targetPackages = Join-Path $repo 'build\windows\x64\packages'
$configPath = Join-Path $repo 'NuGet.Config'

# nuget 默认把临时锁文件放在 %TEMP%\NuGetScratch；受限环境里 %TEMP% 不可写会导致
# "Unable to obtain lock file access ..." 而装不上包，这里重定向到工作区内。
$scratchDir = Join-Path $repo '.tmp\nuget-scratch'
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null
$env:NUGET_SCRATCH = $scratchDir

Write-Step "仓库根：$repo"
New-Item -ItemType Directory -Force -Path $sourceDir, $globalPackages, $targetPackages | Out-Null

Write-Step '收集离线包（.tmp\nuget-source）'
foreach ($package in $packageList) {
    $target = Join-Path $sourceDir "$($package.Id).$($package.Version).nupkg"
    if (Test-Path -LiteralPath $target) {
        Write-Host "    已存在：$($package.Id) $($package.Version)"
        continue
    }
    $cached = Get-CachedPackagePath -Id $package.Id -Version $package.Version
    if (-not (Test-Path -LiteralPath $cached)) {
        throw @"
本机 NuGet 缓存里没有 $($package.Id) $($package.Version)：
    期望路径：$cached
请任选一种方式补齐后重跑本脚本：
    1) nuget install $($package.Id) -Version $($package.Version) -ExcludeVersion -OutputDirectory build\windows\x64\packages
    2) 手动下载 https://www.nuget.org/api/v2/package/$($package.Id)/$($package.Version)
       另存为 $target
"@
    }
    Copy-Item -LiteralPath $cached -Destination $target -Force
    Write-Host "    已从本机缓存复制：$($package.Id) $($package.Version)"
}

Write-Step '生成 NuGet.Config（离线包源 + 工作区内的包缓存目录）'
$config = @'
<?xml version="1.0" encoding="utf-8"?>
<!--
  由 tools\prepare_windows_deps.ps1 生成，请勿手工编辑（已被 .gitignore 忽略）。
  目的：让 webview_all_windows 的 CMake 依赖步骤在离线、且只能写工作区的环境下也能成功。
  重新生成：tools\prepare_windows_deps.cmd
-->
<configuration>
  <config>
    <add key="globalPackagesFolder" value=".tmp\nuget-packages" />
  </config>
  <packageSources>
    <clear />
    <add key="ws_scrcpy_client_offline" value=".tmp\nuget-source" />
  </packageSources>
</configuration>
'@
Set-Content -LiteralPath $configPath -Value $config -Encoding UTF8
Write-Host "    已写入：$configPath"

Write-Step '准备 nuget.exe（复制到 build\windows\x64\，避免 CMake 联网下载）'
$nuget = Resolve-NuGetExe -Explicit $NuGetPath -Root $repo
if (-not $nuget) {
    throw '未找到 nuget.exe：请把它放到 C:\Users\Warren\Dev\nuget\，或用 -NuGetPath 指定'
}
Write-Host "    使用：$nuget"
$buildNuget = Join-Path $repo 'build\windows\x64\nuget.exe'
if (-not (Test-Path -LiteralPath $buildNuget)) {
    Copy-Item -LiteralPath $nuget -Destination $buildNuget -Force
    Write-Host "    已复制到：$buildNuget"
} else {
    Write-Host "    已存在：$buildNuget"
}

Write-Step '安装依赖包到 build\windows\x64\packages'
# nuget.exe 5.10 的临时锁固定落在进程的 %TEMP%\NuGetScratch（NUGET_SCRATCH 对它无效），
# 受限环境里 %TEMP% 不可写会直接失败；这里临时把 TEMP/TMP 指到工作区，退出前还原。
$originalTemp = $env:TEMP
$originalTmp = $env:TMP
$env:TEMP = $scratchDir
$env:TMP = $scratchDir
try {
    foreach ($package in $packageList) {
        $installed = Join-Path $targetPackages $package.Id
        if (Test-Path -LiteralPath $installed) {
            Write-Host "    已安装：$($package.Id) $($package.Version)"
            continue
        }
        Write-Host "    安装 $($package.Id) $($package.Version) …"
        & $nuget install $package.Id -Version $package.Version -ExcludeVersion `
            -OutputDirectory $targetPackages -ConfigFile $configPath -NonInteractive | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "安装失败：$($package.Id) $($package.Version)"
        }
    }
} finally {
    $env:TEMP = $originalTemp
    $env:TMP = $originalTmp
}

Write-Step '校验关键 targets 文件'
$expected = @(
    (Join-Path $targetPackages 'Microsoft.Web.WebView2\build\native\Microsoft.Web.WebView2.targets'),
    (Join-Path $targetPackages 'Microsoft.Windows.ImplementationLibrary\build\native\Microsoft.Windows.ImplementationLibrary.targets')
)
foreach ($file in $expected) {
    if (-not (Test-Path -LiteralPath $file)) {
        throw "缺少文件：$file"
    }
    Write-Host "    OK：$file"
}

Write-Host ''
Write-Host '准备完成，现在可以直接构建（不需要把 nuget 放进 PATH）：'
Write-Host '    flutter build windows --debug'
