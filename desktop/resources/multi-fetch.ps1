<#
.SYNOPSIS
  IDM 原理复现：把同一个 HTTP 文件切成 N 段并发下载，再按序拼接。

.DESCRIPTION
  只在「服务器/链路按单连接限速」时才有收益。
  对 Steam depot（HTTPS + 签名分块 + 客户端已多连接）、
  对需要 MITM 才能改写的加密流量 无效。

.EXAMPLE
  ./multi-fetch.ps1 -Url https://example.com/big.iso -OutFile D:\big.iso -Threads 8 -ChunkMB 4

.EXAMPLE
  # 只取前 32MB 做测速对比，不落完整文件
  ./multi-fetch.ps1 -Url https://example.com/big.iso -OutFile D:\bench.bin -Threads 8 -LimitMB 32 -Compare
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [int]$Threads = 8,
    [int]$ChunkMB = 4,
    [int]$LimitMB = 0,
    [string]$Proxy = '',
    [switch]$Compare,
    [switch]$KeepParts
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch {}
$MB = 1MB

# Windows PowerShell 5.1：进程环境里若同时存在 NO_PROXY / no_proxy 这类仅大小写不同的键，
# Start-Process 会抛 "Item has already been added. Key in dictionary: 'NO_PROXY'"。
# 先清掉代理环境变量，避免并发段起不来；需要代理时用 -Proxy 显式指定。
foreach ($n in 'http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY', 'no_proxy', 'NO_PROXY') {
    try { [Environment]::SetEnvironmentVariable($n, $null, 'Process') } catch {}
}

$proxyArgs = @()
if ($Proxy -ne '') { $proxyArgs = @('--proxy', $Proxy) }
else { $proxyArgs = @('--noproxy', '*') }   # 不带 -Proxy 就真直连，忽略继承来的系统代理

# ---- 1. 探查目标：长度 + 是否支持 Range ----
$probe = curl.exe -sIL --max-time 25 @proxyArgs $Url
if ($LASTEXITCODE -ne 0) { throw "HEAD 请求失败 (curl exit $LASTEXITCODE)" }
$headText = if ($probe -is [array]) { $probe -join "`n" } else { [string]$probe }
$status = ([regex]::Match($headText, '(?m)^HTTP/[\d.]+\s+(\d{3})')).Groups[1].Value
if ($status -ne '200' -and $status -ne '206') { throw "HEAD 返回 HTTP $status" }
$rangeOk = ($headText -match '(?im)^accept-ranges:\s*bytes\s*$')
$cl = [regex]::Matches($headText, '(?im)^content-length:\s*(\d+)\s*$')
if ($cl.Count -eq 0) { throw "拿不到 Content-Length" }
$total = [int64]$cl[$cl.Count - 1].Groups[1].Value

if (-not $rangeOk) { throw "目标不支持 Accept-Ranges: bytes，无法分段（IDM 同款限制）" }
if ($total -le 0) { throw "拿不到 Content-Length" }

$fetch = if ($LimitMB -gt 0) { [Math]::Min([int64]$total, [int64]$LimitMB * $MB) } else { [int64]$total }

# ---- 2. 分段 ----
$workers = [Math]::Min([Math]::Max($Threads, 1), [Math]::Max([int][Math]::Floor($fetch / $ChunkMB / $MB), 1))
$partSize = [int64][Math]::Ceiling($fetch / $workers)
$segments = @()
for ($i = 0; $i -lt $workers; $i++) {
    $start = [int64]$i * $partSize
    if ($start -ge $fetch) { break }
    $end = [Math]::Min([int64]$fetch - 1, $start + $partSize - 1)
    $segments += [pscustomobject]@{ Index = $i; Start = $start; End = $end; Bytes = ($end - $start + 1) }
}
$workers = $segments.Count

Write-Host "目标: $Url"
Write-Host ("文件总长: {0:N1} MB | 本次取: {1:N1} MB | 分段: {2} 段 x {3:N1} MB" -f ($total / $MB), ($fetch / $MB), $workers, ($partSize / $MB))

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("multifetch-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# ---- 3. 并发下载 ----
$sw = [Diagnostics.Stopwatch]::StartNew()
$procs = @()
foreach ($seg in $segments) {
    $partPath = Join-Path $tmp ("part{0}.bin" -f $seg.Index)
    $spdPath = Join-Path $tmp ("spd{0}.txt" -f $seg.Index)
    $curlArgs = @(
        '-sL', '--fail', '--max-time', '600'
    ) + $proxyArgs + @(
        '-r', ("{0}-{1}" -f $seg.Start, $seg.End),
        '-o', $partPath,
        '-w', '%{speed_download}',
        $Url
    )
    $p = Start-Process -FilePath 'curl.exe' -ArgumentList $curlArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput $spdPath -RedirectStandardError (Join-Path $tmp ("err{0}.txt" -f $seg.Index))
    $procs += [pscustomobject]@{ Proc = $p; Seg = $seg; Spd = $spdPath; Part = $partPath }
}
$procs | ForEach-Object { $_.Proc.WaitForExit() }
$sw.Stop()

$failed = @()
foreach ($item in $procs) {
    $got = if (Test-Path $item.Part) { (Get-Item $item.Part).Length } else { -1 }
    if ($got -ne $item.Seg.Bytes) { $failed += "seg$($item.Seg.Index) got=$got want=$($item.Seg.Bytes)" }
}
if ($failed.Count -gt 0) {
    throw ("有分段下载失败：" + ($failed -join ', '))
}

# ---- 4. 统计 ----
$speeds = @()
foreach ($item in $procs) {
    $raw = (Get-Content $item.Spd -Raw -ErrorAction SilentlyContinue)
    $speeds += if ([string]::IsNullOrWhiteSpace($raw)) { 0.0 } else { [double]$raw.Trim() }
}
$sumBps = ($speeds | Measure-Object -Sum).Sum
$elapsed = $sw.Elapsed.TotalSeconds

Write-Host ""
Write-Host ("每段速度: " + (($speeds | ForEach-Object { "{0:N2}" -f ($_ / $MB) }) -join ' / ') + " MB/s")
Write-Host ("并发合计: {0:N1} Mbps ({1:N2} MB/s) | 实际耗时 {2:N1} s | 平均 {3:N2} MB/s" -f `
        ($sumBps * 8 / 1e6), ($sumBps / $MB), $elapsed, (($fetch / $MB) / $elapsed))

# ---- 5. 拼接 ----
$fs = [System.IO.File]::Create($OutFile)
try {
    $buf = [byte[]]::new(1MB)
    foreach ($seg in $segments) {
        $partPath = Join-Path $tmp ("part{0}.bin" -f $seg.Index)
        $in = [System.IO.File]::OpenRead($partPath)
        try { $in.CopyTo($fs, $buf.Length) } finally { $in.Dispose() }
    }
}
finally { $fs.Dispose() }
Write-Host ("已写入: {0} ({1:N1} MB)" -f $OutFile, ((Get-Item $OutFile).Length / $MB))

# ---- 6. 可选：单连接对照 ----
if ($Compare) {
    Write-Host ""
    Write-Host "单连接对照（同一字节区间）..."
    $sw2 = [Diagnostics.Stopwatch]::StartNew()
    $single = curl.exe -sL --fail --max-time 600 @proxyArgs -r ("0-{0}" -f ($fetch - 1)) -o NUL -w '%{speed_download}' $Url
    $sw2.Stop()
    $singleBps = [double]$single
    Write-Host ("单连接: {0:N2} MB/s ({1:N1} Mbps) | 耗时 {2:N1} s" -f ($singleBps / $MB), ($singleBps * 8 / 1e6), $sw2.Elapsed.TotalSeconds)
    if ($singleBps -gt 0) {
        Write-Host ("并发 / 单连接 = {0:N2}x" -f ($sumBps / $singleBps))
    }
}

if (-not $KeepParts) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
