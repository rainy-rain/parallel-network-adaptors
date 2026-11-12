param(
    [switch]$Status,        # 纯命令行：打印链路与分流器状态后退出
    [switch]$StartQuiet,    # 纯命令行：静默启动分流器
    [switch]$StopQuiet      # 纯命令行：静默停止分流器
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Root        = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$SplitScript = Join-Path $Root 'split-proxy.ps1'
$FetchScript = Join-Path $Root 'multi-fetch.ps1'
$ProxyLog    = Join-Path $env:TEMP 'split-proxy.log'

# ---------- 主题 ----------
$BG      = [Drawing.Color]::FromArgb(24, 24, 28)
$BG2     = [Drawing.Color]::FromArgb(32, 32, 38)
$BORDER  = [Drawing.Color]::FromArgb(58, 58, 68)
$FG      = [Drawing.Color]::FromArgb(232, 232, 236)
$FG_DIM  = [Drawing.Color]::FromArgb(150, 152, 160)
$OK      = [Drawing.Color]::FromArgb(96, 200, 140)
$WARN    = [Drawing.Color]::FromArgb(230, 180, 90)
$ERR     = [Drawing.Color]::FromArgb(230, 110, 110)
$ACCENT  = [Drawing.Color]::FromArgb(88, 148, 220)

# ---------- 链路探测（与 split-proxy.ps1 保持一致的判定） ----------
function ConvertTo-IPv4Number([string]$ip) {
    $p = $ip.Split('.')
    if ($p.Count -ne 4) { return [uint32]0 }
    $v = ([uint64]$p[0] -shl 24) -bor ([uint64]$p[1] -shl 16) -bor ([uint64]$p[2] -shl 8) -bor [uint64]$p[3]; return [uint32]$v
}
function Get-CidrMask([int]$bits) {
    if ($bits -le 0) { return [uint32]0 }
    if ($bits -ge 32) { return [uint32]::MaxValue }
    return [uint32](([uint64]4294967295 -shl (32 - $bits)) -band [uint64]4294967295)
}
function Get-EgressKind([string]$ip) {
    $u = ConvertTo-IPv4Number $ip
    $map = @(
        @('10.66.80.0', 21, '校园网'),
        @('172.20.10.0', 28, 'iPhone蜂窝'),
        @('192.168.42.0', 24, '手机共享'),
        @('192.168.43.0', 24, '手机共享'),
        @('192.168.49.0', 24, '手机共享'),
        @('192.168.137.0', 24, 'ICS共享')
    )
    foreach ($m in $map) {
        $mask = Get-CidrMask ([int]$m[1])
        if (($u -band $mask) -eq ((ConvertTo-IPv4Number $m[0]) -band $mask)) { return [string]$m[2] }
    }
    return '其他'
}
function Get-Links {
    $out = @()
    foreach ($ad in (Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        $ip = Get-NetIPAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -notlike '127.*' } |
            Select-Object -First 1
        if (-not $ip) { continue }
        $gw = Get-NetRoute -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $gw) { continue }
        $desc = [string]$ad.InterfaceDescription
        $isVirtual = $desc -match 'TAP|TUN|Wintun|Tunnel|VirtualBox|Hyper-V|vEthernet|WSL|Loopback|Npcap|WireGuard|Bluetooth|Miniport'
        $out += [pscustomobject]@{
            Name    = $ad.Name
            IP      = $ip.IPAddress
            Gateway = $gw.NextHop
            Metric  = [int]$gw.InterfaceMetric
            Virtual = $isVirtual
            Egress  = (Get-EgressKind $ip.IPAddress)
            Kind    = $(if ($isVirtual) { '虚拟' } else { '物理' })
        }
    }
    return @($out | Sort-Object Virtual, Metric, Name)
}
function Test-ProxyAlive([int]$Port) {
    return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

# ---------- 命令行模式 ----------
if ($Status -or $StartQuiet -or $StopQuiet) {
    if ($StartQuiet) {
        if (Test-ProxyAlive 1080) { Write-Host '分流器已在运行 (1080)'; return }
        Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$SplitScript,'-Port','1080') -WindowStyle Hidden | Out-Null
        for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 500; if (Test-ProxyAlive 1080) { break } }
        Write-Host $(if (Test-ProxyAlive 1080) { '已启动 127.0.0.1:1080' } else { '启动失败，见 ' + $ProxyLog })
        return
    }
    if ($StopQuiet) {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*split-proxy.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Write-Host '已停止分流器'
        return
    }
    Write-Host '===== 链路 ====='
    $ls = Get-Links
    $i = 0
    foreach ($l in $ls) {
        $i++
        Write-Host ("[{0}] {1,-22} {2,-14} 网关 {3,-15} 度量 {4,-5} {5} | 出口 {6}" -f $i, $l.Name, $l.IP, $l.Gateway, $l.Metric, $l.Kind, $l.Egress)
    }
    Write-Host ''
    Write-Host ('分流器 1080: ' + $(if (Test-ProxyAlive 1080) { '运行中' } else { '未运行' }))
    return
}

# ---------- 主窗口 ----------
$form = New-Object Windows.Forms.Form
$form.Text = '双链路并行（网卡分流）'
$form.Size = New-Object Drawing.Size(1000, 800)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $BG
$form.ForeColor = $FG
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

function New-FlatButton($text, $x, $y, $w, $h, $color, $handler) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object Drawing.Point($x, $y)
    $b.Size = New-Object Drawing.Size($w, $h)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $color
    $b.ForeColor = [Drawing.Color]::White
    $b.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
    $b.Cursor = [Windows.Forms.Cursors]::Hand
    $b.Add_Click($handler)
    $form.Controls.Add($b)
    return $b
}

$lblTitle = New-Object Windows.Forms.Label
$lblTitle.Text = '双链路并行（网卡分流）'
$lblTitle.Location = New-Object Drawing.Point(20, 14)
$lblTitle.Size = New-Object Drawing.Size(560, 32)
$lblTitle.Font = New-Object Drawing.Font('Microsoft YaHei UI', 16, [Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $FG
$form.Controls.Add($lblTitle)

$lblSub = New-Object Windows.Forms.Label
$lblSub.Text = '连接级分流：一条 TCP 只能走一条网卡，只有多线程 / 分片下载才能叠加带宽'
$lblSub.Location = New-Object Drawing.Point(22, 50)
$lblSub.Size = New-Object Drawing.Size(900, 22)
$lblSub.ForeColor = $FG_DIM
$form.Controls.Add($lblSub)

# 状态条
$pnlStatus = New-Object Windows.Forms.Panel
$pnlStatus.Location = New-Object Drawing.Point(20, 82)
$pnlStatus.Size = New-Object Drawing.Size(944, 52)
$pnlStatus.BackColor = $BG2
$form.Controls.Add($pnlStatus)

$lblState = New-Object Windows.Forms.Label
$lblState.Text = '分流器：未运行'
$lblState.Location = New-Object Drawing.Point(14, 8)
$lblState.Size = New-Object Drawing.Size(260, 20)
$lblState.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10, [Drawing.FontStyle]::Bold)
$lblState.ForeColor = $WARN
$pnlStatus.Controls.Add($lblState)

$lblDetail = New-Object Windows.Forms.Label
$lblDetail.Text = '端口 1080 · 模式 split · 链路 0 条'
$lblDetail.Location = New-Object Drawing.Point(14, 30)
$lblDetail.Size = New-Object Drawing.Size(600, 18)
$lblDetail.ForeColor = $FG_DIM
$pnlStatus.Controls.Add($lblDetail)

# 链路表格
$grid = New-Object Windows.Forms.DataGridView
$grid.Location = New-Object Drawing.Point(20, 144)
$grid.Size = New-Object Drawing.Size(944, 150)
$grid.BackgroundColor = $BG2
$grid.BorderStyle = 'None'
$grid.GridColor = $BORDER
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(44, 44, 52)
$grid.ColumnHeadersDefaultCellStyle.ForeColor = $FG
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)
$grid.DefaultCellStyle.BackColor = $BG2
$grid.DefaultCellStyle.ForeColor = $FG
$grid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(52, 74, 104)
$grid.DefaultCellStyle.SelectionForeColor = $FG
$grid.RowHeadersVisible = $false
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.ReadOnly = $true
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = 'Fill'
$grid.RowTemplate.Height = 26
foreach ($c in @(
    @('序号', 44), @('网卡', 170), @('IPv4', 130), @('网关', 130),
    @('度量', 56), @('类型', 56), @('出口归属', 120)
)) {
    $col = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $col.HeaderText = $c[0]
    $col.Name = $c[0]
    $col.FillWeight = $c[1]
    $col.SortMode = 'NotSortable'
    [void]$grid.Columns.Add($col)
}
$form.Controls.Add($grid)

# 按钮行 1
$y1 = 306
$btnScan  = New-FlatButton '重新检测链路' 20  $y1 130 34 ([Drawing.Color]::FromArgb(48, 82, 120)) { Refresh-Links }
$btnProbe = New-FlatButton '链路自检'     158 $y1 110 34 ([Drawing.Color]::FromArgb(48, 82, 120)) { Start-Probe }
$btnStart = New-FlatButton '启动分流'     276 $y1 110 34 ([Drawing.Color]::FromArgb(46, 110, 72))  { Start-Split }
$btnStop  = New-FlatButton '停止分流'     394 $y1 110 34 ([Drawing.Color]::FromArgb(72, 72, 80))   { Stop-Split }
$btnOpen  = New-FlatButton '打开分流日志' 512 $y1 120 34 ([Drawing.Color]::FromArgb(72, 72, 80))   { Open-ProxyLog }

# 按钮行 2
$y2 = 348
$btnKill = New-FlatButton '用代理重启选中进程' 20 $y2 170 34 ([Drawing.Color]::FromArgb(96, 70, 40)) { Restart-Selected }

$lblThreads = New-Object Windows.Forms.Label
$lblThreads.Text = '线程'
$lblThreads.Location = New-Object Drawing.Point(206, ($y2 + 7))
$lblThreads.Size = New-Object Drawing.Size(34, 20)
$lblThreads.ForeColor = $FG_DIM
$form.Controls.Add($lblThreads)

$numThreads = New-Object Windows.Forms.NumericUpDown
$numThreads.Location = New-Object Drawing.Point(242, ($y2 + 5))
$numThreads.Size = New-Object Drawing.Size(52, 24)
$numThreads.Minimum = 1
$numThreads.Maximum = 64
$numThreads.Value = 16
$numThreads.BackColor = $BG2
$numThreads.ForeColor = $FG
$numThreads.BorderStyle = 'FixedSingle'
$form.Controls.Add($numThreads)

$lblChunk = New-Object Windows.Forms.Label
$lblChunk.Text = '分片 MB'
$lblChunk.Location = New-Object Drawing.Point(302, ($y2 + 7))
$lblChunk.Size = New-Object Drawing.Size(54, 20)
$lblChunk.ForeColor = $FG_DIM
$form.Controls.Add($lblChunk)

$numChunk = New-Object Windows.Forms.NumericUpDown
$numChunk.Location = New-Object Drawing.Point(360, ($y2 + 5))
$numChunk.Size = New-Object Drawing.Size(48, 24)
$numChunk.Minimum = 1
$numChunk.Maximum = 64
$numChunk.Value = 4
$numChunk.BackColor = $BG2
$numChunk.ForeColor = $FG
$numChunk.BorderStyle = 'FixedSingle'
$form.Controls.Add($numChunk)

$btnDownload = New-FlatButton '多线程下载测试' 418 $y2 130 34 ([Drawing.Color]::FromArgb(48, 82, 120)) { Start-Download }

# 进程列表
$lblProc = New-Object Windows.Forms.Label
$lblProc.Text = '可分流进程（双击用代理重启）'
$lblProc.Location = New-Object Drawing.Point(20, 394)
$lblProc.Size = New-Object Drawing.Size(400, 20)
$lblProc.ForeColor = $FG_DIM
$form.Controls.Add($lblProc)

$lstProc = New-Object Windows.Forms.ListBox
$lstProc.Location = New-Object Drawing.Point(20, 416)
$lstProc.Size = New-Object Drawing.Size(440, 180)
$lstProc.BackColor = $BG2
$lstProc.ForeColor = $FG
$lstProc.BorderStyle = 'None'
$lstProc.Font = New-Object Drawing.Font('Consolas', 9)
$lstProc.IntegralHeight = $false
$lstProc.Add_DoubleClick({ Restart-Selected })
$form.Controls.Add($lstProc)

# 右侧：说明
$txtHelp = New-Object Windows.Forms.TextBox
$txtHelp.Location = New-Object Drawing.Point(476, 416)
$txtHelp.Size = New-Object Drawing.Size(488, 180)
$txtHelp.BackColor = $BG2
$txtHelp.ForeColor = $FG_DIM
$txtHelp.BorderStyle = 'None'
$txtHelp.Multiline = $true
$txtHelp.ReadOnly = $true
$txtHelp.ScrollBars = 'Vertical'
$txtHelp.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$txtHelp.Text = @"
怎么用

1. 先点「重新检测链路」，确认两条都是「物理」且「出口归属」不同
   （例如一条 校园网，一条 手机共享）。虚拟网卡会被排除。

2. 点「链路自检」，每条链路各下载约 500 KB，看到两行 OK 才算通。

3. 点「启动分流」，在本机 127.0.0.1:1080 起 SOCKS5 + HTTP 代理。
   任何支持代理的软件把它设成 127.0.0.1:1080 即可。

4. 想让某软件立刻用上：在下面列表里双击它，会用代理环境重启。
   注意：多数软件需要在启动时才读取代理变量，所以必须重启。

5. 「多线程下载测试」会用 multi-fetch.ps1 把文件切段并发，
   每段落到不同网卡 —— 这才可能超过单条链路速度。

限制

· 单条 TCP 连接不会变快，只有多连接才叠加。
· Steam / 游戏启动器不认代理，需要 /32 路由或双 WAN。
· 只处理 TCP，UDP / QUIC 不走代理（浏览器会回落 TCP）。
"@
$form.Controls.Add($txtHelp)

# 日志
$lblLog = New-Object Windows.Forms.Label
$lblLog.Text = '日志'
$lblLog.Location = New-Object Drawing.Point(20, 604)
$lblLog.Size = New-Object Drawing.Size(100, 20)
$lblLog.ForeColor = $FG_DIM
$form.Controls.Add($lblLog)

$txtLog = New-Object Windows.Forms.RichTextBox
$txtLog.Location = New-Object Drawing.Point(20, 626)
$txtLog.Size = New-Object Drawing.Size(944, 118)
$txtLog.BackColor = [Drawing.Color]::FromArgb(16, 16, 20)
$txtLog.ForeColor = $FG
$txtLog.BorderStyle = 'None'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object Drawing.Font('Consolas', 9)
$form.Controls.Add($txtLog)

$lblFoot = New-Object Windows.Forms.Label
$lblFoot.Text = '改动：无。分流器只在本机开监听端口，不改路由、不装驱动、不需要管理员。'
$lblFoot.Location = New-Object Drawing.Point(20, 748)
$lblFoot.Size = New-Object Drawing.Size(900, 18)
$lblFoot.ForeColor = [Drawing.Color]::FromArgb(110, 110, 118)
$form.Controls.Add($lblFoot)

# ---------- 行为 ----------
$script:Port = 1080
$script:Mode = 'split'

function Log([string]$m, [string]$color = '') {
    $t = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $m
    $c = switch ($color) {
        'ok'   { $OK }
        'warn' { $WARN }
        'err'  { $ERR }
        default { $FG }
    }
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.SelectionLength = 0
    $txtLog.SelectionColor = $c
    $txtLog.AppendText($t + "`n")
    $txtLog.ScrollToCaret()
}
function Refresh-Links {
    $grid.Rows.Clear()
    $ls = @(Get-Links)
    $i = 0
    foreach ($l in $ls) {
        $i++
        [void]$grid.Rows.Add($i, $l.Name, $l.IP, $l.Gateway, $l.Metric, $l.Kind, $l.Egress)
    }
    $phys = @($ls | Where-Object { -not $_.Virtual })
    Log ("检测到 " + $ls.Count + " 条链路，其中物理 " + $phys.Count + " 条")
    if ($phys.Count -lt 2) {
        Log '物理链路不足 2 条 —— 分流需要两条出口不同的物理网卡（如 校园网 Wi-Fi + 手机 USB 共享）' 'warn'
    } else {
        $eg = @($phys | Select-Object -ExpandProperty Egress -Unique)
        if ($eg.Count -ge 2) { Log ("两条物理链路出口不同：" + ($eg -join ' / ') + '，可以分流') 'ok' }
        else { Log ("两条物理链路出口相同（" + ($eg -join '') + '），分流不会提速 —— 可能是同一条网络的两种接入') 'warn' }
    }
    Refresh-State
}
function Refresh-State {
    $alive = Test-ProxyAlive $script:Port
    if ($alive) {
        $lblState.Text = '分流器：运行中'
        $lblState.ForeColor = $OK
        $conns = @(Get-NetTCPConnection -LocalPort $script:Port -State Established -ErrorAction SilentlyContinue).Count
        $lblDetail.Text = ('端口 ' + $script:Port + ' · 模式 ' + $script:Mode + ' · 活跃连接 ' + $conns + ' · 链路 ' + $grid.Rows.Count + ' 条')
    } else {
        $lblState.Text = '分流器：未运行'
        $lblState.ForeColor = $WARN
        $lblDetail.Text = ('端口 ' + $script:Port + ' · 模式 ' + $script:Mode + ' · 链路 ' + $grid.Rows.Count + ' 条')
    }
}
function Start-Split {
    if (Test-ProxyAlive $script:Port) { Log ('分流器已在运行（' + $script:Port + '）') 'ok'; return }
    if (-not (Test-Path $SplitScript)) { Log ('找不到 ' + $SplitScript) 'err'; return }
    $phys = @(Get-Links | Where-Object { -not $_.Virtual })
    if ($phys.Count -lt 2) {
        $r = [Windows.Forms.MessageBox]::Show(
            ('只找到 ' + $phys.Count + ' 条物理链路。' + "`n`n" + '分流需要至少两条出口不同的物理网卡。' + "`n" + '仍要启动吗（只会走单条）？'),
            '链路不足', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
    }
    Log ('启动分流器 127.0.0.1:' + $script:Port + ' ...')
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $SplitScript, '-Port', "$($script:Port)")
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [void][System.Diagnostics.Process]::Start($psi)
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 400
        if (Test-ProxyAlive $script:Port) { break }
    }
    if (Test-ProxyAlive $script:Port) {
        Log ('已启动，监听 127.0.0.1:' + $script:Port) 'ok'
        Log '把软件的 HTTP/SOCKS 代理指向这个地址即可；不认代理的软件需要 /32 路由'
    } else {
        Log '启动失败，点「打开分流日志」看原因' 'err'
    }
    Refresh-State
}
function Stop-Split {
    $hit = 0
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*split-proxy.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $hit++ }
    if ($hit -gt 0) { Log ('已停止分流器（' + $hit + ' 个进程）') 'ok' }
    else { Log '没有找到运行中的分流器' 'warn' }
    Start-Sleep -Milliseconds 400
    Refresh-State
}
function Start-Probe {
    if (-not (Test-Path $SplitScript)) { Log ('找不到 ' + $SplitScript) 'err'; return }
    $out = Join-Path $env:TEMP ('probe-' + [guid]::NewGuid().ToString('N') + '.log')
    Log '开始链路自检（每条约 500 KB）...'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $SplitScript + '" -Probe'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $script:probeProc = [System.Diagnostics.Process]::Start($psi)
    $script:probeOut = $out
    $script:probeTimer.Enabled = $true
}
function Read-ProbeOutput {
    $p = $script:probeProc
    if (-not $p) { $script:probeTimer.Enabled = $false; return }
    while ($p.StandardOutput.Peek() -ge 0) {
        $line = $p.StandardOutput.ReadLine()
        if ($line -ne $null -and $line.Trim() -ne '') {
            Log $line $(if ($line -match 'OK') { 'ok' } elseif ($line -match '失败|错误') { 'err' } else { '' })
        }
    }
    if ($p.HasExited) {
        while ($p.StandardOutput.Peek() -ge 0) {
            $line = $p.StandardOutput.ReadLine()
            if ($line -ne $null -and $line.Trim() -ne '') { Log $line }
        }
        $errText = $p.StandardError.ReadToEnd()
        if ($errText.Trim() -ne '') { Log $errText.Trim() 'err' }
        $script:probeTimer.Enabled = $false
        Log ('自检结束，退出码 ' + $p.ExitCode) $(if ($p.ExitCode -eq 0) { 'ok' } else { 'err' })
        $script:probeProc = $null
        Refresh-State
    }
}
$script:probeTimer = New-Object Windows.Forms.Timer
$script:probeTimer.Interval = 300
$script:probeTimer.Add_Tick({ Read-ProbeOutput })

function Restart-Selected {
    $sel = $lstProc.SelectedItem
    if (-not $sel) { Log '先在列表里选一个进程' 'warn'; return }
    $parts = $sel.ToString() -split '\s+', 3
    $pidVal = 0
    if (-not [int]::TryParse($parts[0], [ref]$pidVal)) { Log '解析进程失败' 'err'; return }
    $proc = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
    if (-not $proc) { Log ('进程 ' + $pidVal + ' 已不存在') 'warn'; return }
    $exe = $null
    try { $exe = $proc.Path } catch { }
    if (-not $exe -and $proc.MainModule) { $exe = $proc.MainModule.FileName }
    if (-not $exe) { Log ('拿不到 ' + $proc.ProcessName + ' 的可执行路径（可能受保护），请手动从快捷方式启动') 'err'; return }
    if (-not (Test-ProxyAlive $script:Port)) { Log '分流器没在运行，先点「启动分流」' 'warn'; return }
    $r = [Windows.Forms.MessageBox]::Show(
        ('将关闭 ' + $proc.ProcessName + '（PID ' + $pidVal + '）并用代理环境重启它。' + "`n`n" + '未保存的内容会丢失，确定吗？'),
        '重启进程', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    try { Stop-Process -Id $pidVal -Force -ErrorAction Stop } catch { Log ('结束进程失败：' + $_.Exception.Message) 'err'; return }
    Start-Sleep -Milliseconds 700
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.UseShellExecute = $true
    $psi.WorkingDirectory = (Split-Path -Parent $exe)
    $px = 'http://127.0.0.1:' + $script:Port
    $psi.EnvironmentVariables['HTTP_PROXY']  = $px
    $psi.EnvironmentVariables['HTTPS_PROXY'] = $px
    $psi.EnvironmentVariables['ALL_PROXY']   = 'socks5://127.0.0.1:' + $script:Port
    foreach ($k in 'no_proxy', 'NO_PROXY') { try { $psi.EnvironmentVariables.Remove($k) } catch { } }
    try {
        [void][System.Diagnostics.Process]::Start($psi)
        Log ('已用代理重启 ' + $proc.ProcessName) 'ok'
    } catch {
        Log ('启动失败：' + $_.Exception.Message) 'err'
    }
}
function Start-Download {
    $url = [Microsoft.VisualBasic.Interaction]::InputBox('要下载的文件地址（建议用大文件，方便看叠加效果）', '多线程下载', 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/24.04/ubuntu-24.04.1-desktop-amd64.iso')
    if (-not $url) { return }
    if (-not (Test-ProxyAlive $script:Port)) { Log '分流器没在运行，先点「启动分流」' 'warn'; return }
    $outFile = Join-Path ([Environment]::GetFolderPath('MyDocuments')) ('parallel-dl-' + (Get-Date -Format 'HHmmss') + '.bin')
    Log ('开始下载：' + $url)
    Log ('线程 ' + $numThreads.Value + '，分片 ' + $numChunk.Value + ' MB，经 127.0.0.1:' + $script:Port)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $FetchScript + '" -Url "' + $url + '" -OutFile "' + $outFile + '" -Threads ' + $numThreads.Value + ' -ChunkMB ' + $numChunk.Value + ' -Proxy "http://127.0.0.1:' + $script:Port + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $script:dlProc = [System.Diagnostics.Process]::Start($psi)
    $script:dlTimer.Enabled = $true
}
function Read-Download {
    $p = $script:dlProc
    if (-not $p) { $script:dlTimer.Enabled = $false; return }
    while ($p.StandardOutput.Peek() -ge 0) {
        $line = $p.StandardOutput.ReadLine()
        if ($line -ne $null -and $line.Trim() -ne '') { Log $line }
    }
    if ($p.HasExited) {
        while ($p.StandardOutput.Peek() -ge 0) { $l = $p.StandardOutput.ReadLine(); if ($l) { Log $l } }
        $e = $p.StandardError.ReadToEnd()
        if ($e.Trim()) { Log $e.Trim() 'err' }
        Log ('下载进程结束，退出码 ' + $p.ExitCode) $(if ($p.ExitCode -eq 0) { 'ok' } else { 'err' })
        $script:dlProc = $null
        $script:dlTimer.Enabled = $false
    }
}
$script:dlTimer = New-Object Windows.Forms.Timer
$script:dlTimer.Interval = 400
$script:dlTimer.Add_Tick({ Read-Download })

function Open-ProxyLog {
    if (Test-Path $ProxyLog) { Start-Process notepad.exe $ProxyLog } else { Log ('日志还不存在：' + $ProxyLog) 'warn' }
}
function Refresh-Processes {
    $lstProc.Items.Clear()
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -and $_.Id -ne $PID } |
        Sort-Object ProcessName |
        ForEach-Object {
            $title = $_.MainWindowTitle
            if ($title.Length -gt 40) { $title = $title.Substring(0, 40) + '…' }
            [void]$lstProc.Items.Add(('{0,-6} {1,-22} {2}' -f $_.Id, $_.ProcessName, $title))
        }
    Log ('已列出 ' + $lstProc.Items.Count + ' 个有窗口的进程')
}
$script:procTimer = New-Object Windows.Forms.Timer
$script:procTimer.Interval = 5000
$script:procTimer.Add_Tick({ Refresh-Processes })
$script:procTimer.Enabled = $true

# 启动时刷新
$form.Add_Shown({
    Refresh-Links
    Refresh-Processes
    if (-not (Test-Path $SplitScript)) { Log ('警告：找不到 ' + $SplitScript) 'err' }
    if (-not (Test-Path $FetchScript)) { Log ('警告：找不到 ' + $FetchScript) 'err' }
})
$form.Add_FormClosing({ $script:procTimer.Enabled = $false })
[void]$form.ShowDialog()
