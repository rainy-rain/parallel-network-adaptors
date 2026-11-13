param([ValidateSet('enable','disable','status','test','run')][string]$Action = 'status')

$ErrorActionPreference = 'Continue'
$Root     = $PSScriptRoot
$PidFile  = Join-Path $Root 'cm-splitter.pid'
$LogFile  = Join-Path $Root 'cm-splitter.log'
$HostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$BeginMark = '# === SteamCM BEGIN ==='
$EndMark   = '# === SteamCM END ==='
$Chunk     = 20
$DelayMs   = 3
$Ports     = 27015..27036

# 本地回环 IP -> 真实 CM IP / 域名
$Dcs = @(
    @{ ip='127.0.0.2';  host='cmp1-hkg1'; target='103.28.54.100'  }
    @{ ip='127.0.0.3';  host='cmp2-hkg1'; target='103.28.54.101'  }
    @{ ip='127.0.0.4';  host='cmp3-hkg1'; target='103.28.54.102'  }
    @{ ip='127.0.0.5';  host='cmp1-sgp1'; target='103.10.124.4'   }
    @{ ip='127.0.0.6';  host='cmp2-sgp1'; target='103.10.124.5'   }
    @{ ip='127.0.0.7';  host='cmp1-tyo3'; target='45.121.184.100' }
    @{ ip='127.0.0.8';  host='cmp2-tyo3'; target='45.121.184.101' }
    @{ ip='127.0.0.9';  host='cmp1-lax1'; target='162.254.195.69' }
    @{ ip='127.0.0.10'; host='cmp2-lax1'; target='162.254.195.75' }
    @{ ip='127.0.0.11'; host='cmp1-dfw2'; target='162.254.194.56' }
    @{ ip='127.0.0.12'; host='cmp2-dfw2'; target='162.254.194.57' }
    @{ ip='127.0.0.13'; host='cmp1-syd1'; target='103.10.125.22'  }
    @{ ip='127.0.0.14'; host='ext1-bom2'; target='155.133.224.22' }
    @{ ip='127.0.0.15'; host='ext2-bom2'; target='155.133.224.23' }
    @{ ip='127.0.0.16'; host='ext1-maa2'; target='155.133.225.20' }
    @{ ip='127.0.0.17'; host='ext2-maa2'; target='155.133.225.21' }
    @{ ip='127.0.0.18'; host='cmp1-sea1'; target='205.196.6.132'  }
    @{ ip='127.0.0.19'; host='cmp2-sea1'; target='205.196.6.133'  }
    @{ ip='127.0.0.20'; host='cmp1-atl3'; target='162.254.199.165'}
    @{ ip='127.0.0.21'; host='cmp2-atl3'; target='162.254.199.184'}
    @{ ip='127.0.0.22'; host='cmp1-iad1'; target='162.254.192.98' }
    @{ ip='127.0.0.23'; host='cmp2-iad1'; target='162.254.192.99' }
    @{ ip='127.0.0.24'; host='cmp1-ord1'; target='162.254.193.103'}
    @{ ip='127.0.0.25'; host='cmp2-ord1'; target='162.254.193.75' }
)

function Get-RelayPid {
    if (-not (Test-Path $PidFile)) { return 0 }
    try { return [int]((Get-Content $PidFile -Raw -ErrorAction Stop).Trim()) } catch { return 0 }
}

function Test-RelayRunning {
    $p = Get-RelayPid
    if ($p -le 0) { return $false }
    return [bool](Get-Process -Id $p -ErrorAction SilentlyContinue)
}

function Get-ListenCount {
    try {
        $all = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                 Where-Object { $_.LocalPort -ge 27015 -and $_.LocalPort -le 27036 -and $_.LocalAddress -like '127.0.0.*' })
        return $all.Count
    } catch { return 0 }
}

function Write-HostsBlock([bool]$On) {
    try { $raw = [IO.File]::ReadAllText($HostsFile, [Text.Encoding]::Default) } catch { return $false }
    $body = [regex]::Replace($raw, '(?s)\r?\n?' + [regex]::Escape($BeginMark) + '.*?' + [regex]::Escape($EndMark) + '\r?\n?', "`r`n")
    if ($On) {
        $sb = New-Object Text.StringBuilder
        [void]$sb.Append($body.TrimEnd())
        [void]$sb.Append("`r`n`r`n" + $BeginMark + "`r`n")
        foreach ($d in $Dcs) { [void]$sb.Append("$($d.ip) $($d.host).steamserver.net`r`n") }
        [void]$sb.Append($EndMark + "`r`n")
        $body = $sb.ToString()
    }
    if ([string]::IsNullOrWhiteSpace($body)) { return $false }
    for ($i = 0; $i -lt 6; $i++) {
        try { [IO.File]::WriteAllText($HostsFile, $body, [Text.Encoding]::Default); return $true }
        catch { Start-Sleep -Milliseconds 400 }
    }
    return $false
}

switch ($Action) {

    'run' {
        Add-Type -Path (Join-Path $Root 'CmSplitter.cs')
        [CmSplitter]::LogPath = $LogFile
        $total = 0
        foreach ($d in $Dcs) {
            $total += [CmSplitter]::StartMany($d.ip, [int[]]$Ports, $d.target, $Chunk, $DelayMs, $d.host)
        }
        $PID | Out-File -FilePath $PidFile -Encoding ASCII -Force
        [CmSplitter]::L("=== started PID $PID, $total listeners, $($Dcs.Count) DC, chunk=$Chunk delay=${DelayMs}ms ===")
        while ($true) { Start-Sleep -Seconds 20 }
    }

    'enable' {
        foreach ($n in @('no_proxy','NO_PROXY','http_proxy','HTTP_PROXY','https_proxy','HTTPS_PROXY','all_proxy','ALL_PROXY')) {
            Remove-Item ('Env:' + $n) -ErrorAction SilentlyContinue
        }
        if (-not (Test-RelayRunning)) {
            $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File','cm-splitter.ps1','-Action','run')
            $sp = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WorkingDirectory $Root -WindowStyle Hidden -PassThru
            if ($sp) { $sp.Dispose() }
            $deadline = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 400
                if ((Get-ListenCount) -ge ($Dcs.Count * $Ports.Count) - 24) { break }
            }
        }
        $hostsOk = Write-HostsBlock $true
        & ipconfig /flushdns 2>&1 | Out-Null
        $lis = Get-ListenCount
        Write-Output ('CM_ENABLED=' + $(if ((Test-RelayRunning) -and $lis -gt 0) { 1 } else { 0 }))
        Write-Output ('CM_PID=' + (Get-RelayPid))
        Write-Output ('CM_LISTENERS=' + $lis)
        Write-Output ('CM_DC=' + $Dcs.Count)
        $hostsOn = 0
        try { $raw2 = [IO.File]::ReadAllText($HostsFile, [Text.Encoding]::Default); if ($raw2.Contains($BeginMark)) { $hostsOn = 1 } } catch { }
        Write-Output ('CM_HOSTS=' + $hostsOn)
    }

    'disable' {
        $p = Get-RelayPid
        if ($p -gt 0) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 800
        $hostsOk = Write-HostsBlock $false
        & ipconfig /flushdns 2>&1 | Out-Null
        if (Test-Path $PidFile) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
        $lis = Get-ListenCount
        Write-Output ('CM_ENABLED=' + $(if ((Test-RelayRunning) -and $lis -gt 0) { 1 } else { 0 }))
        Write-Output ('CM_PID=0')
        Write-Output ('CM_LISTENERS=' + $lis)
        Write-Output ('CM_DC=' + $Dcs.Count)
        $hostsOn = 0
        try { $raw2 = [IO.File]::ReadAllText($HostsFile, [Text.Encoding]::Default); if ($raw2.Contains($BeginMark)) { $hostsOn = 1 } } catch { }
        Write-Output ('CM_HOSTS=' + $hostsOn)
    }

    'status' {
        $run = Test-RelayRunning
        $lis = Get-ListenCount
        $hostsOn = 0
        try {
            $raw = [IO.File]::ReadAllText($HostsFile, [Text.Encoding]::Default)
            if ($raw.Contains($BeginMark)) { $hostsOn = 1 }
        } catch { }
        Write-Output ('CM_ENABLED=' + $(if ($run -and $lis -gt 0) { 1 } else { 0 }))
        Write-Output ('CM_PID=' + (Get-RelayPid))
        Write-Output ('CM_LISTENERS=' + $lis)
        Write-Output ('CM_DC=' + $Dcs.Count)
        Write-Output ('CM_HOSTS=' + $hostsOn)
    }

    'test' {
        $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
        if (-not $curl) { Write-Output 'CM_TEST=0'; break }
        $savedH = $env:HTTP_PROXY; $savedS = $env:HTTPS_PROXY; $savedA = $env:ALL_PROXY
        $env:HTTP_PROXY = ''; $env:HTTPS_PROXY = ''; $env:ALL_PROXY = ''
        $ok = 0; $tot = 0
        foreach ($h in @('cmp1-hkg1','cmp2-hkg1','cmp1-sgp1','cmp1-lax1')) {
            $tot++
            $r = & $curl -s -o NUL -w '%{http_code}|%{time_appconnect}' --noproxy '*' --connect-timeout 8 --max-time 15 ('https://' + $h + '.steamserver.net:27018/') 2>$null
            $a = "$r" -split '\|'
            if ($a[0] -eq '403') { $ok++; Write-Output ('CM_DC_' + $h + '=OK:' + $a[1]) }
            else { Write-Output ('CM_DC_' + $h + '=FAIL:' + $a[0]) }
        }
        $env:HTTP_PROXY = $savedH; $env:HTTPS_PROXY = $savedS; $env:ALL_PROXY = $savedA
        Write-Output ('CM_TEST_OK=' + $ok)
        Write-Output ('CM_TEST_TOTAL=' + $tot)
    }
}

exit 0
