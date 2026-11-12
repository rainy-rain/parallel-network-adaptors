param(
    [ValidateSet('adapters', 'steam')][string]$Open = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Root        = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$AdaptersGui = Join-Path $Root 'gui\AdaptersGUI.ps1'
$SteamGui    = Join-Path $Root 'steam-community\SteamProxy.ps1'

function Launch([string]$script) {
    if (-not (Test-Path $script)) {
        [Windows.Forms.MessageBox]::Show(("找不到：`n" + $script), '文件缺失', 'OK', 'Error') | Out-Null
        return
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script + '"'
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = (Split-Path -Parent $script)
    [void][System.Diagnostics.Process]::Start($psi)
}

if ($Open -eq 'adapters') { Launch $AdaptersGui; return }
if ($Open -eq 'steam')    { Launch $SteamGui;    return }

# ---------- 主题 ----------
$BG     = [Drawing.Color]::FromArgb(24, 24, 28)
$BG2    = [Drawing.Color]::FromArgb(32, 32, 38)
$FG     = [Drawing.Color]::FromArgb(232, 232, 236)
$FG_DIM = [Drawing.Color]::FromArgb(150, 152, 160)

$form = New-Object Windows.Forms.Form
$form.Text = '并行网络工具箱'
$form.Size = New-Object Drawing.Size(560, 360)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $BG
$form.ForeColor = $FG
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

$lblTitle = New-Object Windows.Forms.Label
$lblTitle.Text = '并行网络工具箱'
$lblTitle.Location = New-Object Drawing.Point(24, 18)
$lblTitle.Size = New-Object Drawing.Size(480, 34)
$lblTitle.Font = New-Object Drawing.Font('Microsoft YaHei UI', 17, [Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $FG
$form.Controls.Add($lblTitle)

$lblSub = New-Object Windows.Forms.Label
$lblSub.Text = '两个独立工具，按需选用；互不依赖，可单独卸载'
$lblSub.Location = New-Object Drawing.Point(26, 56)
$lblSub.Size = New-Object Drawing.Size(480, 22)
$lblSub.ForeColor = $FG_DIM
$form.Controls.Add($lblSub)

function New-Card($title, $desc, $x, $y, $w, $h, $color, $handler) {
    $pnl = New-Object Windows.Forms.Panel
    $pnl.Location = New-Object Drawing.Point($x, $y)
    $pnl.Size = New-Object Drawing.Size($w, $h)
    $pnl.BackColor = $color
    $pnl.Cursor = [Windows.Forms.Cursors]::Hand

    $l1 = New-Object Windows.Forms.Label
    $l1.Text = $title
    $l1.Location = New-Object Drawing.Point(16, 14)
    $l1.Size = New-Object Drawing.Size(($w - 32), 26)
    $l1.Font = New-Object Drawing.Font('Microsoft YaHei UI', 12, [Drawing.FontStyle]::Bold)
    $l1.ForeColor = [Drawing.Color]::White
    $l1.BackColor = [Drawing.Color]::Transparent
    $l1.Cursor = [Windows.Forms.Cursors]::Hand
    $pnl.Controls.Add($l1)

    $l2 = New-Object Windows.Forms.Label
    $l2.Text = $desc
    $l2.Location = New-Object Drawing.Point(16, 44)
    $l2.Size = New-Object Drawing.Size(($w - 32), ($h - 54))
    $l2.ForeColor = [Drawing.Color]::FromArgb(220, 220, 226)
    $l2.BackColor = [Drawing.Color]::Transparent
    $l2.Cursor = [Windows.Forms.Cursors]::Hand
    $pnl.Controls.Add($l2)

    $pnl.Add_Click($handler)
    $l1.Add_Click($handler)
    $l2.Add_Click($handler)
    $form.Controls.Add($pnl)
    return $pnl
}

New-Card '双链路并行' `
    "把两条出口不同的网卡（如校园网 Wi-Fi + 手机 USB 共享）按连接分流。`n本机开 SOCKS5/HTTP 代理，多线程下载才能叠加带宽。" `
    24 96 250 130 ([Drawing.Color]::FromArgb(40, 74, 108)) { Launch $AdaptersGui } | Out-Null

New-Card 'Steam 社区直连' `
    "本机 Caddy 终结 TLS，再用 Akamai 域前置转发到 Valve 白名单域名。`nSNI 被墙时照样能开社区、市场、创意工坊。" `
    286 96 250 130 ([Drawing.Color]::FromArgb(46, 96, 66)) { Launch $SteamGui } | Out-Null

$lblFoot = New-Object Windows.Forms.Label
$lblFoot.Text = 'MIT License · 仅供学习与自用；请遵守所在网络的使用规定'
$lblFoot.Location = New-Object Drawing.Point(24, 246)
$lblFoot.Size = New-Object Drawing.Size(500, 20)
$lblFoot.ForeColor = [Drawing.Color]::FromArgb(110, 110, 118)
$form.Controls.Add($lblFoot)

$lblPath = New-Object Windows.Forms.Label
$lblPath.Text = $Root
$lblPath.Location = New-Object Drawing.Point(24, 270)
$lblPath.Size = New-Object Drawing.Size(500, 20)
$lblPath.ForeColor = [Drawing.Color]::FromArgb(90, 90, 98)
$form.Controls.Add($lblPath)

$btnClose = New-Object Windows.Forms.Button
$btnClose.Text = '关闭'
$btnClose.Location = New-Object Drawing.Point(444, 254)
$btnClose.Size = New-Object Drawing.Size(92, 32)
$btnClose.FlatStyle = 'Flat'
$btnClose.FlatAppearance.BorderSize = 0
$btnClose.BackColor = [Drawing.Color]::FromArgb(72, 72, 80)
$btnClose.ForeColor = [Drawing.Color]::White
$btnClose.Cursor = [Windows.Forms.Cursors]::Hand
$btnClose.Add_Click({ $form.Close() })
$form.Controls.Add($btnClose)

[void]$form.ShowDialog()
