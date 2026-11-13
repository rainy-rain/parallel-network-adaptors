using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public class CmSplitter
{
    public static string LogPath = "";
    static readonly object _lk = new object();
    // 必须持有强引用：否则 Thread/委托一旦不可达，闭包里的 TcpListener 会被 GC 回收，
    // 其 Finalizer 会关闭 socket，表现为"StartMany 返回 528 但监听几秒后全消失"。
    static readonly System.Collections.Generic.List<TcpListener> _keepL = new System.Collections.Generic.List<TcpListener>();
    static readonly System.Collections.Generic.List<Thread> _keepT = new System.Collections.Generic.List<Thread>();
    public static void L(string m)
    {
        if (string.IsNullOrEmpty(LogPath)) return;
        try { lock (_lk) { File.AppendAllText(LogPath, DateTime.Now.ToString("HH:mm:ss.fff") + " " + m + "\r\n", Encoding.UTF8); } }
        catch { }
    }

    public static int StartMany(string listenIp, int[] ports, string targetIp, int chunk, int delayMs, string tag)
    {
        int ok = 0;
        foreach (int p in ports)
        {
            try
            {
                var listener = new TcpListener(IPAddress.Parse(listenIp), p);
                listener.Start();
                _keepL.Add(listener);
                int tp = p;
                var th = new Thread(() =>
                {
                    while (true)
                    {
                        try
                        {
                            var client = listener.AcceptTcpClient();
                            var t = new Thread(() => Handle(client, targetIp, tp, chunk, delayMs, tag));
                            t.IsBackground = true; t.Start();
                        }
                        catch { }
                    }
                });
                th.IsBackground = true; th.Start();
                _keepT.Add(th);
                ok++;
            }
            catch (Exception ex) { L("listen " + listenIp + ":" + p + " err " + ex.Message); }
        }
        return ok;
    }

    static void Handle(TcpClient client, string targetIp, int port, int chunk, int delayMs, string tag)
    {
        TcpClient up = null;
        try
        {
            client.NoDelay = true;
            up = new TcpClient();
            up.NoDelay = true;
            var ar = up.BeginConnect(targetIp, port, null, null);
            if (!ar.AsyncWaitHandle.WaitOne(8000)) { L("up timeout " + tag + ":" + port); client.Close(); return; }
            up.EndConnect(ar);
            var cn = client.GetStream();
            var un = up.GetStream();

            var t1 = new Thread(() => PumpSplit(cn, un, chunk, delayMs));
            t1.IsBackground = true; t1.Start();
            PumpRaw(un, cn);
        }
        catch (Exception ex) { L("err " + tag + ":" + port + " " + ex.GetType().Name); try { client.Close(); } catch { } }
    }

    // Steam -> CM：分片发送，切断 DPI 对单段 ClientHello 的识别
    static void PumpSplit(NetworkStream from, NetworkStream to, int chunk, int delayMs)
    {
        var buf = new byte[32768];
        try
        {
            int n;
            while ((n = from.Read(buf, 0, buf.Length)) > 0)
            {
                int pos = 0;
                while (pos < n)
                {
                    int len = Math.Min(chunk, n - pos);
                    to.Write(buf, pos, len);
                    to.Flush();
                    pos += len;
                    if (pos < n && delayMs > 0) Thread.Sleep(delayMs);
                }
            }
        }
        catch { }
        try { to.Close(); } catch { }
        try { from.Close(); } catch { }
    }

    static void PumpRaw(NetworkStream from, NetworkStream to)
    {
        var buf = new byte[32768];
        try { int n; while ((n = from.Read(buf, 0, buf.Length)) > 0) { to.Write(buf, 0, n); to.Flush(); } }
        catch { }
        try { to.Close(); } catch { }
        try { from.Close(); } catch { }
    }
}