#Requires -Version 5.1
<#
  parallel-network-toolkit 安装程序
  ================================================================
  做三件事：
    1. 把整个工具箱复制到 %LOCALAPPDATA%\ParallelNetworkToolkit
    2. 准备 caddy.exe（优先从仓库复制，缺则从 caddyserver.com 下载）
    3. 在桌面和开始菜单建「并行网络工具箱」快捷方式
  可选 -StartNow：装完立即开启 Steam 社区反代
  ================================================================
#>
[CmdletBinding()]
param(
    [string]$Dest = '',
    [switch]$StartNow,
    [switch]$SkipCaddy
)

$ErrorActionPreference = 'Stop'

# ==================== 自提权 ====================
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    if ($Dest) { $argLine += ' -Dest "' + $Dest + '"' }
    if ($StartNow) { $argLine += ' -StartNow' }
    if ($SkipCaddy) { $argLine += ' -SkipCaddy' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = $argLine
    $psi.Verb = 'runas'
    $psi.UseShellExecute = $true
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null } catch { }
    exit
}

$Source = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $Dest) { $Dest = Join-Path $env:LOCALAPPDATA 'ParallelNetworkToolkit' }

function Say([string]$m, [string]$c = 'Gray') {
    Write-Host $m -ForegroundColor $c
}
function Fail([string]$m) {
    Say ''
    Say ('✗ ' + $m) 'Red'
    Say ''
    Read-Host '按回车退出'
    exit 1
}

Say ''
Say '===========================================' 'Cyan'
Say '  并行网络工具箱 安装程序' 'Cyan'
Say '===========================================' 'Cyan'
Say ''
Say ("源目录  : " + $Source)
Say ("安装到  : " + $Dest)
Say ''

if (-not (Test-Path (Join-Path $Source 'gui\Launcher.ps1'))) {
    Fail ('源目录不完整，缺少 gui\Launcher.ps1。请从仓库根目录的 installer 子目录运行本脚本。')
}

# ==================== 1. 建目录 ====================
if (Test-Path $Dest) {
    Say '目标目录已存在，将覆盖同名文件（保留 caddy.exe 与 access.log）' 'Yellow'
}
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
foreach ($d in @('gui', 'steam-community', 'mac')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Dest $d) | Out-Null
}
Say '目录已就绪' 'Green'

# ==================== 2. 复制文件 ====================
$files = @(
    'split-proxy.ps1',
    'multi-fetch.ps1',
    'dl.ps1',
    'app-split.ps1',
    'app-split.bat',
    'LICENSE',
    'README.md'
)
$script:copied = 0
foreach ($f in $files) {
    $s = Join-Path $Source $f
    if (Test-Path $s) {
        Copy-Item $s (Join-Path $Dest $f) -Force
        $copied++
    }
}
foreach ($sub in @('gui', 'steam-community', 'mac')) {
    $sd = Join-Path $Source $sub
    if (-not (Test-Path $sd)) { continue }
    Get-ChildItem $sd -File | ForEach-Object {
        # 跳过二进制与日志，caddy.exe 单独处理
        if ($_.Name -eq 'caddy.exe') { return }
        if ($_.Extension -eq '.log') { return }
        Copy-Item $_.FullName (Join-Path $Dest "$sub\$($_.Name)") -Force
        $script:copied++
    }
}
Say ('已复制 ' + $script:copied + ' 个文件') 'Green'



# 卸载脚本一并放入安装目录
$instDir = Join-Path $Dest 'installer'
New-Item -ItemType Directory -Force -Path $instDir | Out-Null
$srcUn = Join-Path $Source 'installer\uninstall.ps1'
if (Test-Path $srcUn) {
    Copy-Item $srcUn (Join-Path $instDir 'uninstall.ps1') -Force
    Say '卸载脚本已放入 installer\uninstall.ps1' 'Green'
}

# ==================== 3. caddy.exe ====================
$caddy = Join-Path $Dest 'steam-community\caddy.exe'
if ($SkipCaddy) {
    Say '已跳过 caddy.exe（-SkipCaddy）' 'Yellow'
} elseif (Test-Path $caddy) {
    $sz = [math]::Round((Get-Item $caddy).Length / 1MB, 1)
    Say ('caddy.exe 已存在（' + $sz + ' MB），跳过') 'Green'
} else {
    $srcCaddy = Join-Path $Source 'steam-community\caddy.exe'
    if (Test-Path $srcCaddy) {
        Say '从仓库复制 caddy.exe ...'
        Copy-Item $srcCaddy $caddy -Force
    } else {
        Say '正在从 caddyserver.com 下载 caddy.exe（约 51 MB，视网络 1–5 分钟）...' 'Yellow'
        $url = 'https://caddyserver.com/api/download?os=windows&arch=amd64'
        $ok = $false
        try {
            & curl.exe -L --fail --retry 2 --connect-timeout 20 -o $caddy $url
            if ($LASTEXITCODE -eq 0 -and (Test-Path $caddy) -and (Get-Item $caddy).Length -gt 5MB) { $ok = $true }
        } catch { }
        if (-not $ok) {
            if (Test-Path $caddy) { Remove-Item $caddy -Force -ErrorAction SilentlyContinue }
            Fail '下载 caddy.exe 失败。可以手动下载后放到 steam-community\ 目录再重跑安装：' 
        }
    }
    if (Test-Path $caddy) {
        $sz = [math]::Round((Get-Item $caddy).Length / 1MB, 1)
        Say ('caddy.exe 就绪（' + $sz + ' MB）') 'Green'
    }
}

# ==================== 4. 快捷方式 ====================
function New-Shortcut([string]$lnkPath, [string]$scriptPath, [string]$desc) {
    $wsh = New-Object -ComObject WScript.Shell
    $sc = $wsh.CreateShortcut($lnkPath)
    $sc.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $sc.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $scriptPath + '"'
    $sc.WorkingDirectory = (Split-Path -Parent $scriptPath)
    $sc.Description = $desc
    $sc.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',13'
    $sc.WindowStyle = 1
    $sc.Save()
}

$launcher = Join-Path $Dest 'gui\Launcher.ps1'
$steamPs  = Join-Path $Dest 'steam-community\SteamProxy.ps1'
$desktop  = [Environment]::GetFolderPath('Desktop')
$startDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'

New-Shortcut (Join-Path $desktop '并行网络工具箱.lnk') $launcher '双链路并行 + Steam 社区直连'
New-Shortcut (Join-Path $startDir '并行网络工具箱.lnk') $launcher '双链路并行 + Steam 社区直连'
Say '已创建快捷方式：桌面 / 开始菜单' 'Green'

if (Test-Path $steamPs) {
    New-Shortcut (Join-Path $desktop 'Steam 社区直连.lnk') $steamPs 'Steam 社区 / 市场 / 创意工坊 直连开关'
    Say '已创建快捷方式：Steam 社区直连' 'Green'
}

# ==================== 5. 立即开启（可选） ====================
if ($StartNow) {
    if (-not $SkipCaddy -and (Test-Path $steamPs) -and (Test-Path $caddy)) {
        Say ''
        Say '正在开启 Steam 社区直连 ...' 'Cyan'
        $sp = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File", $steamPs, "-EnableQuiet") -PassThru -WindowStyle Hidden
        $ok = $false
        for ($wait = 0; $wait -lt 60; $wait++) {
            Start-Sleep -Milliseconds 500
            if (@(Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { $ok = $true; break }
            if ($sp.HasExited -and $wait -gt 10) { break }
        }
        if ($ok) { Say "Steam 社区反代已开启（443 已监听）" "Green" }
        else    { Say "未确认开启成功，可双击桌面「Steam 社区直连」查看日志" "Yellow" }
    } else {
        Say '未开启 Steam 反代（缺少 caddy.exe 或用了 -SkipCaddy）' 'Yellow'
    }
}

Say ''
Say '===========================================' 'Green'
Say '  安装完成' 'Green'
Say '===========================================' 'Green'
Say ''
Say ('安装目录：' + $Dest)
Say '桌面「并行网络工具箱」：两个工具二选一'
Say '桌面「Steam 社区直连」：直接开 Steam 反代开关'
Say ''
Say ('卸载：powershell -ExecutionPolicy Bypass -File "' + (Join-Path $Dest 'installer\uninstall.ps1') + '"') 'Gray'
Say '      （安装目录里也放了一份卸载脚本）' 'Gray'
Say ''
Read-Host '按回车退出'