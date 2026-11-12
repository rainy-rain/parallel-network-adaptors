param(
    [int]$Port = 1080,
    [string]$Primary = '',
    [string]$Secondary = '',
    [ValidateSet('split', 'primary', 'secondary')][string]$Mode = 'split',
    [switch]$List,
    [switch]$SelfTest,
    [switch]$Probe
)

$code = @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.Http;
using System.Text;
using System.Threading;

public class SplitProxy
{
    private TcpListener _listener;
    private int[] _ifaces;
    private int _rr = 0;
    private volatile bool _running = true;

    public SplitProxy(string bind, int port, int[] ifaceIndices)
    {
        _ifaces = ifaceIndices;
        _listener = new TcpListener(IPAddress.Parse(bind), port);
    }

    public void Start()
    {
        _listener.Start();
        Thread t = new Thread(AcceptLoop);
        t.IsBackground = true;
        t.Start();
    }

    public void Stop()
    {
        _running = false;
        try { _listener.Stop(); } catch { }
    }

    private void AcceptLoop()
    {
        while (_running)
        {
            TcpClient c;
            try { c = _listener.AcceptTcpClient(); }
            catch { break; }
            TcpClient captured = c;
            Thread t = new Thread(delegate() { Handle(captured); });
            t.IsBackground = true;
            t.Start();
        }
    }

    private static bool ReadExact(NetworkStream s, byte[] buf, int off, int len)
    {
        int done = 0;
        while (done < len)
        {
            int n;
            try { n = s.Read(buf, off + done, len - done); }
            catch { return false; }
            if (n <= 0) return false;
            done += n;
        }
        return true;
    }

    private static void Copy(NetworkStream from, NetworkStream to)
    {
        byte[] buf = new byte[32768];
        try
        {
            while (true)
            {
                int n = from.Read(buf, 0, buf.Length);
                if (n <= 0) break;
                to.Write(buf, 0, n);
            }
        }
        catch { }
        finally
        {
            try { to.Close(); } catch { }
        }
    }

    private static void Relay(NetworkStream client, NetworkStream upstream)
    {
        NetworkStream up = upstream;
        NetworkStream cl = client;
        Thread t = new Thread(delegate() { Copy(up, cl); });
        t.IsBackground = true;
        t.Start();
        Copy(cl, up);
    }

    private static bool IsFakeIp(IPAddress ip)
    {
        byte[] b = ip.GetAddressBytes();
        return b.Length == 4 && b[0] == 198 && (b[1] == 18 || b[1] == 19);
    }

    private static string ResolveReal(string host)
    {
        try
        {
            string url = "https://dns.alidns.com/resolve?name=" + Uri.EscapeDataString(host) + "&type=A";
            using (HttpClient hc = new HttpClient())
            {
                hc.Timeout = TimeSpan.FromSeconds(6);
                string json = hc.GetStringAsync(url).Result;
                int i = 0;
                while ((i = json.IndexOf("\"data\":\"", i)) >= 0)
                {
                    i += 8;
                    int j = json.IndexOf('"', i);
                    if (j <= i) break;
                    string v = json.Substring(i, j - i);
                    IPAddress tmp;
                    if (IPAddress.TryParse(v, out tmp) && tmp.AddressFamily == AddressFamily.InterNetwork) return v;
                    i = j;
                }
            }
        }
        catch { }
        return null;
    }

    private NetworkStream Dial(string host, int port)
    {
        IPAddress ip = null;
        IPAddress.TryParse(host, out ip);
        if (ip == null)
        {
            try
            {
                IPAddress[] addrs = Dns.GetHostAddresses(host);
                for (int i = 0; i < addrs.Length; i++)
                {
                    if (addrs[i].AddressFamily == AddressFamily.InterNetwork) { ip = addrs[i]; break; }
                }
                if (ip == null && addrs.Length > 0) ip = addrs[0];
            }
            catch { }
        }
        if (ip == null || IsFakeIp(ip))
        {
            string real = ResolveReal(host);
            IPAddress parsed;
            if (real != null && IPAddress.TryParse(real, out parsed)) ip = parsed;
        }
        if (ip == null) return null;

        int k = Interlocked.Increment(ref _rr);
        int idx = _ifaces[(k & 0x7FFFFFFF) % _ifaces.Length];

        Socket up = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        try
        {
            byte[] ifb = new byte[] { (byte)(idx >> 24), (byte)(idx >> 16), (byte)(idx >> 8), (byte)idx };
            up.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31, ifb);
            IAsyncResult ar = up.BeginConnect(new IPEndPoint(ip, port), null, null);
            if (!ar.AsyncWaitHandle.WaitOne(10000))
            {
                try { up.Close(); } catch { }
                return null;
            }
            up.EndConnect(ar);
        }
        catch
        {
            try { up.Close(); } catch { }
            return null;
        }
        return new NetworkStream(up, true);
    }

    private void Handle(TcpClient client)
    {
        try
        {
            using (client)
            {
                NetworkStream cs = client.GetStream();
                byte[] first = new byte[1];
                if (!ReadExact(cs, first, 0, 1)) return;
                if (first[0] == 5) Socks(cs);
                else Http(cs, first[0]);
            }
        }
        catch { }
    }

    private void Socks(NetworkStream cs)
    {
        byte[] nm = new byte[1];
        if (!ReadExact(cs, nm, 0, 1)) return;
        byte[] methods = new byte[nm[0]];
        if (!ReadExact(cs, methods, 0, methods.Length)) return;
        cs.Write(new byte[] { 5, 0 }, 0, 2);

        byte[] req = new byte[4];
        if (!ReadExact(cs, req, 0, 4)) return;
        if (req[1] != 1)
        {
            cs.Write(new byte[] { 5, 7, 0, 1, 0, 0, 0, 0, 0, 0 }, 0, 10);
            return;
        }

        string host = null;
        int port = 0;
        if (req[3] == 1)
        {
            byte[] a = new byte[6];
            if (!ReadExact(cs, a, 0, 6)) return;
            host = new IPAddress(new byte[] { a[0], a[1], a[2], a[3] }).ToString();
            port = (a[4] << 8) | a[5];
        }
        else if (req[3] == 3)
        {
            byte[] l = new byte[1];
            if (!ReadExact(cs, l, 0, 1)) return;
            byte[] d = new byte[l[0]];
            if (!ReadExact(cs, d, 0, d.Length)) return;
            host = Encoding.ASCII.GetString(d);
            byte[] p = new byte[2];
            if (!ReadExact(cs, p, 0, 2)) return;
            port = (p[0] << 8) | p[1];
        }
        else
        {
            cs.Write(new byte[] { 5, 8, 0, 1, 0, 0, 0, 0, 0, 0 }, 0, 10);
            return;
        }

        NetworkStream up = Dial(host, port);
        if (up == null)
        {
            cs.Write(new byte[] { 5, 4, 0, 1, 0, 0, 0, 0, 0, 0 }, 0, 10);
            return;
        }
        cs.Write(new byte[] { 5, 0, 0, 1, 0, 0, 0, 0, 0, 0 }, 0, 10);
        Relay(cs, up);
    }

    private void Http(NetworkStream cs, byte firstByte)
    {
        MemoryStream ms = new MemoryStream();
        ms.WriteByte(firstByte);
        byte[] one = new byte[1];
        while (ms.Length < 8192)
        {
            if (!ReadExact(cs, one, 0, 1)) return;
            ms.WriteByte(one[0]);
            byte[] all = ms.ToArray();
            int n = all.Length;
            if (n >= 4 && all[n - 1] == 10 && all[n - 2] == 13 && all[n - 3] == 10 && all[n - 4] == 13) break;
        }
        string head = Encoding.ASCII.GetString(ms.ToArray());
        string[] lines = head.Split(new string[] { "\r\n" }, StringSplitOptions.None);
        if (lines.Length == 0) return;
        string[] parts = lines[0].Split(' ');
        if (parts.Length < 2) return;

        if (parts[0].Equals("CONNECT", StringComparison.OrdinalIgnoreCase))
        {
            string hp = parts[1];
            int colon = hp.LastIndexOf(':');
            if (colon <= 0) return;
            string host = hp.Substring(0, colon);
            int port;
            if (!int.TryParse(hp.Substring(colon + 1), out port)) return;

            NetworkStream upTunnel = Dial(host, port);
            if (upTunnel == null)
            {
                byte[] bad = Encoding.ASCII.GetBytes("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
                cs.Write(bad, 0, bad.Length);
                return;
            }
            byte[] ok = Encoding.ASCII.GetBytes("HTTP/1.1 200 Connection Established\r\n\r\n");
            cs.Write(ok, 0, ok.Length);
            Relay(cs, upTunnel);
            return;
        }

        if (parts.Length < 3 || !parts[1].StartsWith("http://", StringComparison.OrdinalIgnoreCase))
        {
            byte[] bad = Encoding.ASCII.GetBytes("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n");
            cs.Write(bad, 0, bad.Length);
            return;
        }
        string uri = parts[1].Substring(7);
        int slash = uri.IndexOf('/');
        string hostport = slash < 0 ? uri : uri.Substring(0, slash);
        string path = slash < 0 ? "/" : uri.Substring(slash);
        string hostOnly = hostport;
        int portPlain = 80;
        int c2 = hostport.LastIndexOf(':');
        if (c2 > 0)
        {
            hostOnly = hostport.Substring(0, c2);
            int.TryParse(hostport.Substring(c2 + 1), out portPlain);
        }
        NetworkStream upPlain = Dial(hostOnly, portPlain);
        if (upPlain == null)
        {
            byte[] bad = Encoding.ASCII.GetBytes("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
            cs.Write(bad, 0, bad.Length);
            return;
        }
        StringBuilder sb = new StringBuilder();
        sb.Append(parts[0]).Append(' ').Append(path).Append(' ').Append(parts[2]).Append("\r\n");
        for (int i = 1; i < lines.Length; i++)
        {
            if (lines[i].Length == 0) continue;
            if (lines[i].StartsWith("Proxy-Connection", StringComparison.OrdinalIgnoreCase)) continue;
            sb.Append(lines[i]).Append("\r\n");
        }
        sb.Append("\r\n");
        byte[] outb = Encoding.ASCII.GetBytes(sb.ToString());
        upPlain.Write(outb, 0, outb.Length);
        Relay(cs, upPlain);
    }
}
'@

Add-Type -TypeDefinition $code -Language CSharp -ReferencedAssemblies System.Net.Http

function ConvertTo-IPv4Number([string]$ip) {
    $b = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
    return (([uint64]$b[0] * 16777216) + ([uint64]$b[1] * 65536) + ([uint64]$b[2] * 256) + [uint64]$b[3])
}

function Get-CidrMask([int]$bits) {
    if ($bits -le 0) { return [uint64]0 }
    return ([uint64]4294967295 - ([uint64]1 -shl (32 - $bits)) + 1)
}

function Get-EgressKind([string]$ip) {
    # 用网段判断这张网卡的流量最终从哪出去，避免把蜂窝链路当成校园网链路
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

function Get-LinkCandidates {
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
            Name        = $ad.Name
            Description = $desc
            IfIndex     = [int]$ad.ifIndex
            IP          = $ip.IPAddress
            Gateway     = $gw.NextHop
            Metric      = [int]$gw.InterfaceMetric
            Virtual     = $isVirtual
            Egress      = Get-EgressKind $ip.IPAddress
        }
    }
    return @($out | Sort-Object Virtual, Metric, Name)
}

function Show-Links($links) {
    Write-Host "  出口：校园网=10.66.80.0/21  iPhone蜂窝=172.20.10.0/28  手机共享=192.168.42/43/49.0/24  ICS=192.168.137.0/24"
    $i = 0
    foreach ($x in $links) {
        $i++
        $tag = if ($x.Virtual) { '虚拟' } else { '物理' }
        Write-Host ("  [{0}] {1,-22} {2,-12} 网关 {3,-15} 度量 {4,-5} {5} | 出口 {6}" -f $i, $x.Name, $x.IP, $x.Gateway, $x.Metric, $tag, $x.Egress)
    }
}

function Match-Link($pattern, $links) {
    if ([string]::IsNullOrWhiteSpace($pattern)) { return $null }
    $m = $links | Where-Object { $_.Name -eq $pattern }
    if (-not $m) { $m = $links | Where-Object { $_.Description -like "*$pattern*" } }
    if (-not $m) { $m = $links | Where-Object { $_.IP -eq $pattern } }
    return ($m | Select-Object -First 1)
}

$logPath = Join-Path $env:TEMP 'split-proxy.log'
function Log([string]$m) {
    Write-Host $m
    try { Add-Content -Path $logPath -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -ErrorAction SilentlyContinue } catch {}
}

$links = Get-LinkCandidates
if ($links.Count -eq 0) { Log "没有找到任何已连接且带默认网关的 IPv4 网卡"; throw "没有可用链路" }

if ($List) {
    Write-Host "可用链路（按优先级排序）："
    Show-Links $links
    return
}

$physical = @($links | Where-Object { -not $_.Virtual })
$pool = if ($physical.Count -gt 0) { $physical } else { $links }

$prim = Match-Link $Primary $links
if (-not $prim) { $prim = $pool[0] }

$sec = Match-Link $Secondary $links
if (-not $sec) { $sec = $pool | Where-Object { $_.IfIndex -ne $prim.IfIndex } | Select-Object -First 1 }

switch ($Mode) {
    'primary' { $targets = @($prim.IfIndex) }
    'secondary' {
        if (-not $sec) { Log "只找到一条链路，没有第二条可选"; throw "只找到一条链路，没有第二条可选" }
        $targets = @($sec.IfIndex)
    }
    default {
        if (-not $sec) {
            Log ("只找到一条可用链路: {0}" -f $prim.Name); throw "只找到一条可用链路（$($prim.Name)）。请确认手机 USB 共享 / 第二个网络已连接后再试。"
        }
        $targets = @($prim.IfIndex, $sec.IfIndex)
    }
}

function Resolve-DoH([string]$name) {
    try {
        $r = Invoke-WebRequest -Uri ("https://dns.alidns.com/resolve?name={0}&type=A" -f $name) -UseBasicParsing -TimeoutSec 10
        $j = $r.Content | ConvertFrom-Json
        $a = $j.Answer | Where-Object { $_.type -eq 1 } | Select-Object -First 1
        if ($a) { return [string]$a.data }
    } catch {}
    return $null
}

function Test-LinkSpeed([int]$ifIndex, [string]$targetIp, [int]$port, [int]$bytes) {
    $result = [pscustomobject]@{ Ok = $false; Ms = 0; MBps = 0; Error = '' }
    $sock = $null
    try {
        $sock = New-Object System.Net.Sockets.Socket('InterNetwork', 'Stream', 'Tcp')
        $ifb = [byte[]]@(
            [byte](($ifIndex -shr 24) -band 0xFF), [byte](($ifIndex -shr 16) -band 0xFF),
            [byte](($ifIndex -shr 8) -band 0xFF), [byte]($ifIndex -band 0xFF)
        )
        $sock.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]31, $ifb)
        $sock.ReceiveTimeout = 10000
        $sock.SendTimeout = 10000
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $sock.Connect((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($targetIp), $port)))
        $result.Ms = [int]$sw.ElapsedMilliseconds
        $req = "GET /ubuntu-releases/24.04/ubuntu-24.04.5.1-desktop-amd64.iso HTTP/1.1`r`nHost: mirrors.tuna.tsinghua.edu.cn`r`nRange: bytes=0-$($bytes - 1)`r`nUser-Agent: split-probe`r`nConnection: close`r`n`r`n"
        [void]$sock.Send([Text.Encoding]::ASCII.GetBytes($req))
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        $buf = New-Object byte[] 65536
        $total = 0
        while ($total -lt $bytes) {
            $n = $sock.Receive($buf)
            if ($n -le 0) { break }
            $total += $n
        }
        $sw2.Stop()
        if ($total -gt 0) {
            $result.Ok = $true
            $sec = [Math]::Max($sw2.Elapsed.TotalSeconds, 0.001)
            $result.MBps = [math]::Round(($total / 1MB) / $sec, 2)
        }
    }
    catch { $result.Error = $_.Exception.Message }
    finally { if ($sock) { try { $sock.Close() } catch {} } }
    return $result
}

if ($Probe) {
    $probeHost = 'mirrors.tuna.tsinghua.edu.cn'
    $probeIp = Resolve-DoH $probeHost
    if (-not $probeIp) { $probeIp = '223.5.5.5'; $probeHost = '223.5.5.5 (仅连通性)' }
    $probeList = @()
    if ($Mode -eq 'primary') { $probeList = @($prim) }
    elseif ($Mode -eq 'secondary') { if ($sec) { $probeList = @($sec) } }
    else { $probeList = @($prim); if ($sec) { $probeList += $sec } }

    Write-Host ("自检目标: {0} ({1})，每条约 500 KB" -f $probeHost, $probeIp)
    $allOk = $true
    foreach ($l in $probeList) {
        $role = if ($l.IfIndex -eq $prim.IfIndex) { '主' } else { '副' }
        Write-Host -NoNewline ("  [{0}] {1,-20} {2,-12} ... " -f $role, $l.Name, $l.IP)
        $r = Test-LinkSpeed $l.IfIndex $probeIp 80 512000
        if ($r.Ok) {
            Write-Host ("连接 {0,4} ms | 下载 {1,5} MB/s | OK" -f $r.Ms, $r.MBps)
            if ($r.MBps -lt 0.2) { Write-Host "       速度过低（< 0.2 MB/s），可能无法叠加"; $allOk = $false }
        }
        else {
            Write-Host ("失败: {0}" -f $r.Error)
            $allOk = $false
        }
    }
    if ($allOk) { Write-Host "自检通过"; exit 0 }
    Write-Host "自检未通过"
    exit 1
}
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    Log "端口 $Port 已被占用"; throw "端口 $Port 已被占用，请换一个 -Port"
}

Log ("主链路: {0} ({1})" -f $prim.Name, $prim.IP)
if ($sec -and $Mode -ne 'primary') { Log ("副链路: {0} ({1})" -f $sec.Name, $sec.IP) }

$proxy = New-Object SplitProxy('127.0.0.1', $Port, [int[]]$targets)
$proxy.Start()
Log ("代理已监听 127.0.0.1:{0}（SOCKS5 + HTTP CONNECT） 模式={1} ifIndex={2}" -f $Port, $Mode, ($targets -join ','))

if ($SelfTest) {
    Write-Host "自检（应看到两个不同的出口）："
    1..3 | ForEach-Object {
        $r = & curl.exe -s -m 15 -x ("http://127.0.0.1:{0}" -f $Port) http://icanhazip.com 2>&1
        $t = ($r | Out-String).Trim()
        if ($t.Length -eq 0) { $t = '<空响应>' }
        if ($t.Length -gt 70) { $t = $t.Substring(0, 70) + '...' }
        Write-Host ("  #{0} -> {1}" -f $_, $t)
    }
    $proxy.Stop()
    exit 0
}

Write-Host "按 Ctrl+C 停止。"
while ($true) { Start-Sleep -Seconds 3600 }
