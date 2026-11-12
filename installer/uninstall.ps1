#Requires -Version 5.1
<#
  parallel-network-toolkit 卸载程序
  ================================================================
  依次撤销：
    1. Steam 社区反代（停 Caddy / 清 hosts / 删自启任务 / 移出根证书）
    2. 双链路分流器（结束 split-proxy 进程）
    3. 桌面与开始菜单快捷方式
    4. 安装目录本身（-KeepFiles 可保留）
  ================================================================
#>
[CmdletBinding()]
param(
    [string]$Dest = '',
    [switch]$KeepFiles,
    [switch]$Yes
)

$ErrorActionPreference = 'Continue'

# ==================== 自提权 ====================
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    if ($Dest) { $argLine += ' -Dest "' + $Dest + '"' }
    if ($KeepFiles) { $argLine += ' -KeepFiles' }
    if ($Yes) { $argLine += ' -Yes' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = $argLine
    $psi.Verb = 'runas'
    $psi.UseShellExecute = $true
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null } catch { }
    exit
}

if (-not $Dest) { $Dest = Join-Path $env:LOCALAPPDATA 'ParallelNetworkToolkit' }

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

Say ''
Say '===========================================' 'Cyan'
Say '  并行网络工具箱 卸载程序' 'Cyan'
Say '===========================================' 'Cyan'
Say ''
Say ("安装目录：" + $Dest)
Say ''

if (-not $Yes) {
    $r = Read-Host '确认卸载？会撤销 hosts 改动、删本地根证书、停所有相关进程 (y/N)'
    if ($r -notmatch '^[Yy]') { Say '已取消'; exit 0 }
}

# ==================== 1. Steam 反代 ====================
$steamPs = Join-Path $Dest 'steam-community\SteamProxy.ps1'
if (Test-Path $steamPs) {
    Say '正在关闭 Steam 社区反代 ...' 'Cyan'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $steamPs -DisableQuiet 2>&1 | ForEach-Object { Say $_ }
    Say 'Steam 反代已关闭' 'Green'
} else {
    Say '未找到 SteamProxy.ps1，跳过（若曾装过，请手动检查 hosts 与根证书）' 'Yellow'
}

# ==================== 2. 分流器 ====================
Say '正在结束分流器进程 ...' 'Cyan'
$hit = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*split-proxy.ps1*' } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        $hit++
    }
Say ('已结束 ' + $hit + ' 个分流器进程') 'Green'

# ==================== 3. 快捷方式 ====================
$desktop  = [Environment]::GetFolderPath('Desktop')
$startDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
foreach ($lnk in @(
    (Join-Path $desktop  '并行网络工具箱.lnk'),
    (Join-Path $desktop  'Steam 社区直连.lnk'),
    (Join-Path $startDir '并行网络工具箱.lnk'),
    (Join-Path $startDir 'Steam 社区直连.lnk')
)) {
    if (Test-Path $lnk) {
        Remove-Item $lnk -Force -ErrorAction SilentlyContinue
        Say ('已删除快捷方式：' + (Split-Path -Leaf $lnk))
    }
}

# ==================== 4. 目录 ====================
if ($KeepFiles) {
    Say ('保留安装目录（-KeepFiles）：' + $Dest) 'Yellow'
} elseif (Test-Path $Dest) {
    # 先结束仍占用该目录的 powershell 进程，再删
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $Dest + '*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
    try {
        Remove-Item $Dest -Recurse -Force -ErrorAction Stop
        Say ('已删除安装目录：' + $Dest) 'Green'
    } catch {
        Say ('删除目录失败：' + $_.Exception.Message) 'Red'
        Say '可能有文件被占用，重启后再删，或手动删除该目录' 'Yellow'
    }
}

Say ''
Say '===========================================' 'Green'
Say '  卸载完成' 'Green'
Say '===========================================' 'Green'
Say ''
Say '已还原：hosts / 本地根证书 / 自启任务 / 快捷方式' 'Gray'
Say '未动：Clash 或其它代理软件的配置（本工具从未修改它们）' 'Gray'
Say ''
Read-Host '按回车退出'
