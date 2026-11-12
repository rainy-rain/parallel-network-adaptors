#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
split-proxy.py —— macOS 版双链路分流代理（SOCKS5 + HTTP CONNECT）

和 Windows 版 split-proxy.ps1 行为一致：每进来一条连接，按轮询绑定一张网卡再出站。
区别只在底层机制：
  Windows 用 IP_UNICAST_IF（socket 选项 31）
  macOS   用 IP_BOUND_IF  （IPPROTO_IP, 25，参数是接口索引）

macOS 的一个硬性前提：绑定到副网卡的 socket 要能走到默认路由，必须先有一条
「ifscope 默认路由」。首次使用执行一次（需要 sudo）：

    sudo route -n add -ifscope en7 default 172.20.10.1

本脚本的 --setup-routes / --remove-routes 会代跑这两条命令。

用法：
    python3 split-proxy.py --list
    python3 split-proxy.py --probe
    python3 split-proxy.py --setup-routes
    python3 split-proxy.py --port 1080
"""

import argparse
import itertools
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

IP_BOUND_IF = 25          # macOS: IPPROTO_IP / IP_BOUND_IF
MB = 1024 * 1024
PROBE_HOST = "mirrors.tuna.tsinghua.edu.cn"
PROBE_PATH = "/ubuntu/ls-lR.gz"

# 出口归属：和 Windows 版保持同一张表
EGRESS_MAP = [
    ("10.66.80.0", 21, "校园网"),
    ("172.20.10.0", 28, "iPhone蜂窝"),
    ("192.168.42.0", 24, "手机共享"),
    ("192.168.43.0", 24, "手机共享"),
    ("192.168.49.0", 24, "手机共享"),
    ("192.168.137.0", 24, "ICS共享"),
]

VIRTUAL_PREFIX = ("lo", "utun", "awdl", "llw", "bridge", "gif", "stf", "ap", "anpi", "p2p")

_log_lock = threading.Lock()
_log_path = None


def log(msg):
    line = "%s %s" % (time.strftime("%H:%M:%S"), msg)
    with _log_lock:
        print(line, flush=True)
        if _log_path:
            try:
                with open(_log_path, "a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except OSError:
                pass


# ---------------------------------------------------------------- 工具函数

def run(cmd, timeout=15):
    """跑一条命令，失败返回空串（探测类命令失败是常态）。"""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.stdout if p.returncode == 0 else ""
    except Exception:
        return ""


def ip_to_int(ip):
    p = [int(x) for x in ip.split(".")]
    return (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]


def cidr_mask(bits):
    if bits <= 0:
        return 0
    return ((1 << 32) - (1 << (32 - bits))) & 0xFFFFFFFF


def egress_kind(ip):
    try:
        u = ip_to_int(ip)
    except Exception:
        return "其他"
    for net, bits, label in EGRESS_MAP:
        m = cidr_mask(bits)
        if (u & m) == (ip_to_int(net) & m):
            return label
    return "其他"


def hardware_ports():
    """en0 -> Wi-Fi / en7 -> iPhone USB；不在表里的就是虚拟接口。"""
    out = run(["networksetup", "-listallhardwareports"])
    ports, name = {}, None
    for line in out.splitlines():
        m = re.match(r"Hardware Port:\s*(.+)", line)
        if m:
            name = m.group(1).strip()
            continue
        m = re.match(r"Device:\s*(\S+)", line)
        if m and name:
            ports[m.group(1)] = name
            name = None
    return ports


def service_order():
    """服务顺序就是 macOS 的「优先级」，排在前面的优先。"""
    out = run(["networksetup", "-listnetworkserviceorder"])
    order = []
    for line in out.splitlines():
        m = re.search(r"Device:\s*([^,)]+)", line)
        if m:
            order.append(m.group(1).strip())
    return order


def if_info(name):
    out = run(["ifconfig", name])
    if not out:
        return None
    ip = None
    for line in out.splitlines():
        m = re.search(r"\binet (\d+\.\d+\.\d+\.\d+) netmask (0x[0-9a-fA-F]+)", line)
        if m:
            ip = m.group(1)
            break
    active = ("status: active" in out) or ("RUNNING" in out.splitlines()[0])
    if not ip or not active:
        return None
    return ip


def dhcp_router(name):
    out = run(["ipconfig", "getoption", name, "router"]).strip()
    return out if re.match(r"^\d+\.\d+\.\d+\.\d+$", out) else None


def netstat_gateway(name):
    out = run(["netstat", "-rn", "-f", "inet"])
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 3 and p[0] == "default" and p[-1] == name:
            return p[1]
    return None


def default_route():
    out = run(["route", "-n", "get", "default"])
    gw = re.search(r"gateway:\s*(\S+)", out)
    dev = re.search(r"interface:\s*(\S+)", out)
    return (gw.group(1) if gw else None, dev.group(1) if dev else None)


def has_ifscope_default(name):
    p = subprocess.run(["route", "-n", "get", "-ifscope", name, "default"],
                       capture_output=True, text=True)
    return p.returncode == 0


def get_links():
    ports = hardware_ports()
    order = service_order()
    rank = {d: i for i, d in enumerate(order)}
    _, default_dev = default_route()

    out = []
    for name in run(["ifconfig", "-l"]).split():
        if name.startswith(VIRTUAL_PREFIX) and name not in ports:
            continue
        ip = if_info(name)
        if not ip or ip.startswith("169.254.") or ip.startswith("127."):
            continue
        gw = dhcp_router(name) or netstat_gateway(name)
        is_global_default = (name == default_dev)
        out.append({
            "name": name,
            "port": ports.get(name, "虚拟接口"),
            "ip": ip,
            "gw": gw,
            "ifscope": has_ifscope_default(name),
            "global_default": is_global_default,
            "virtual": name not in ports,
            "rank": rank.get(name, 999),
            "egress": egress_kind(ip),
        })
    out.sort(key=lambda x: (x["virtual"], x["rank"], x["name"]))
    return out


def match_link(pattern, links):
    if not pattern:
        return None
    for link in links:
        if link["name"] == pattern:
            return link
    for link in links:
        if pattern.lower() in link["port"].lower():
            return link
    for link in links:
        if link["ip"] == pattern:
            return link
    return None


def pick_links(links, primary_arg, secondary_arg):
    pool = [x for x in links if not x["virtual"]] or links
    prim = match_link(primary_arg, links)
    if not prim:
        prim = next((x for x in pool if x["global_default"]), pool[0])
    sec = match_link(secondary_arg, links)
    if not sec:
        sec = next((x for x in pool if x["name"] != prim["name"]), None)
    return prim, sec


def show_links(links):
    print("可用链路（按优先级排序）：")
    print("  出口：校园网=10.66.80.0/21  iPhone蜂窝=172.20.10.0/28  "
          "手机共享=192.168.42/43/49.0/24  ICS=192.168.137.0/24")
    for i, x in enumerate(links, 1):
        route = "是" if (x["ifscope"] or x["global_default"]) else "否（--setup-routes）"
        tag = "虚拟" if x["virtual"] else "物理"
        print("  [%d] %-4s %-16s %-13s 网关 %-13s %s | 出口 %s | 默认路由 %s" % (
            i, x["name"], x["port"], x["ip"], x["gw"] or "-", tag, x["egress"], route))


# ---------------------------------------------------------------- 出口绑定

def dial(host, port, ifindex, timeout=15):
    """按接口索引绑定后连接；macOS 用 IP_BOUND_IF。"""
    infos = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
    last = None
    for fam, typ, proto, _, sa in infos:
        s = socket.socket(fam, typ, proto)
        try:
            s.setsockopt(socket.IPPROTO_IP, IP_BOUND_IF, ifindex)
            s.settimeout(timeout)
            s.connect(sa)
            s.settimeout(None)
            return s
        except Exception as e:      # noqa: BLE001 - 逐个地址重试
            last = e
            try:
                s.close()
            except OSError:
                pass
    raise last or OSError("connect failed")


def recvn(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("eof")
        buf += chunk
    return buf


def relay(a, b):
    """双向搬运；任一端 EOF 就半关闭另一端。"""
    def pump(src, dst):
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    break
                dst.sendall(data)
        except OSError:
            pass
        finally:
            try:
                dst.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    t = threading.Thread(target=pump, args=(b, a), daemon=True)
    t.start()
    pump(a, b)
    t.join(timeout=30)


# ---------------------------------------------------------------- 协议处理

class Proxy:
    def __init__(self, ifindices, label):
        self._rr = itertools.cycle(ifindices)
        self._lock = threading.Lock()
        self.label = label

    def next_if(self):
        with self._lock:
            return next(self._rr)


def handle_socks5(conn, proxy):
    _, nm = recvn(conn, 2)
    recvn(conn, nm)
    conn.sendall(b"\x05\x00")

    _, cmd, _, atyp = recvn(conn, 4)
    if atyp == 1:
        host = socket.inet_ntoa(recvn(conn, 4))
    elif atyp == 3:
        host = recvn(conn, recvn(conn, 1)[0]).decode("utf-8", "replace")
    else:
        conn.sendall(b"\x05\x08\x00\x01\x00\x00\x00\x00\x00\x00")
        return
    port = struct.unpack("!H", recvn(conn, 2))[0]

    if cmd != 1:
        conn.sendall(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00")
        return

    idx = proxy.next_if()
    try:
        up = dial(host, port, idx)
    except Exception as e:          # noqa: BLE001
        log("  ! %s:%d via if%d 失败: %s" % (host, port, idx, e))
        conn.sendall(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
        return
    log("  -> %s:%d via if%d" % (host, port, idx))
    conn.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
    relay(conn, up)
    up.close()


def handle_http(conn, proxy):
    data = b""
    while b"\r\n\r\n" not in data and len(data) < 16384:
        chunk = conn.recv(4096)
        if not chunk:
            return
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    parts = lines[0].split()
    if len(parts) < 2:
        return
    method, target = parts[0], parts[1]

    if method.upper() == "CONNECT":
        host, _, port_s = target.rpartition(":")
        idx = proxy.next_if()
        try:
            up = dial(host, int(port_s or 443), idx)
        except Exception as e:      # noqa: BLE001
            log("  ! CONNECT %s 失败: %s" % (target, e))
            conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            return
        log("  -> CONNECT %s via if%d" % (target, idx))
        conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        if rest:
            up.sendall(rest)
        relay(conn, up)
        up.close()
        return

    m = re.match(r"http://([^/]+)(/.*)?", target)
    if not m:
        conn.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
        return
    hostport, path = m.group(1), m.group(2) or "/"
    host, _, port_s = hostport.partition(":")
    keep = [ln for ln in lines[1:] if not ln.lower().startswith("proxy-connection")]
    request = ("%s %s HTTP/1.1\r\n" % (method, path) + "\r\n".join(keep) + "\r\n\r\n").encode("latin-1")

    idx = proxy.next_if()
    try:
        up = dial(host, int(port_s or 80), idx)
    except Exception as e:          # noqa: BLE001
        log("  ! %s %s 失败: %s" % (method, target, e))
        conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        return
    log("  -> %s %s via if%d" % (method, target, idx))
    up.sendall(request + rest)
    relay(conn, up)
    up.close()


def handle(conn, proxy):
    try:
        conn.settimeout(20)
        first = conn.recv(1, socket.MSG_PEEK)
        if not first:
            return
        if first == b"\x05":
            handle_socks5(conn, proxy)
        else:
            handle_http(conn, proxy)
    except Exception as e:          # noqa: BLE001
        log("  ! 连接异常: %s" % e)
    finally:
        try:
            conn.close()
        except OSError:
            pass


def serve(proxy, host, port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(128)
    log("代理已监听 %s:%d（SOCKS5 + HTTP CONNECT）" % (host, port))
    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            break
        threading.Thread(target=handle, args=(conn, proxy), daemon=True).start()


# ---------------------------------------------------------------- 路由 / 自检

def setup_routes(links, remove=False, only=None):
    _, default_dev = default_route()
    todo = [x for x in links if x["name"] != default_dev and (only is None or x["name"] == only)]
    if not todo:
        print("没有需要处理的副链路")
        return 0
    rc = 0
    for x in todo:
        if not x["gw"]:
            print("  %s 没有拿到网关，跳过（DHCP 没给 router 选项）" % x["name"])
            continue
        if remove:
            cmd = ["sudo", "route", "-n", "delete", "-ifscope", x["name"], "default"]
        else:
            if x["ifscope"]:
                print("  %s 已有 ifscope 默认路由，跳过" % x["name"])
                continue
            cmd = ["sudo", "route", "-n", "add", "-ifscope", x["name"], "default", x["gw"]]
        print("  $ " + " ".join(cmd))
        if subprocess.run(cmd).returncode != 0:
            rc = 1
    return rc


def probe(links, nbytes=500 * 1024):
    print("自检目标: %s%s，每条约 500 KB" % (PROBE_HOST, PROBE_PATH))
    try:
        ip = socket.getaddrinfo(PROBE_HOST, 80, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
    except Exception as e:          # noqa: BLE001
        print("  DNS 解析失败: %s" % e)
        return 1
    ok = True
    for link in links:
        idx = socket.if_nametoindex(link["name"])
        label = "主" if link["global_default"] else "副"
        sys.stdout.write("  [%s] %-4s %-13s ... " % (label, link["name"], link["ip"]))
        sys.stdout.flush()
        try:
            t0 = time.time()
            s = dial(ip, 80, idx, timeout=10)
            ms = int((time.time() - t0) * 1000)
            req = ("GET %s HTTP/1.1\r\nHost: %s\r\nRange: bytes=0-%d\r\n"
                   "User-Agent: split-probe\r\nConnection: close\r\n\r\n"
                   % (PROBE_PATH, PROBE_HOST, nbytes - 1))
            s.settimeout(15)
            t1 = time.time()
            s.sendall(req.encode("ascii"))
            got = 0
            while got < nbytes:
                chunk = s.recv(65536)
                if not chunk:
                    break
                got += len(chunk)
            secs = max(time.time() - t1, 0.001)
            s.close()
            mbps = got / MB / secs
            print("连接 %4d ms | 下载 %5.2f MB/s | %s" % (ms, mbps, "OK" if got else "空响应"))
            if mbps < 0.2:
                print("       速度过低（< 0.2 MB/s），可能无法叠加")
                ok = False
        except Exception as e:      # noqa: BLE001
            print("失败: %s" % e)
            ok = False
    print("自检通过" if ok else "自检未通过")
    return 0 if ok else 1


def selftest(links, port):
    proxy = Proxy([socket.if_nametoindex(x["name"]) for x in links],
                  ",".join(x["name"] for x in links))
    threading.Thread(target=serve, args=(proxy, "127.0.0.1", port), daemon=True).start()
    time.sleep(0.5)
    seen = []
    for i in range(2):
        out = subprocess.run(
            ["curl", "-s", "--max-time", "15", "--socks5-hostname",
             "127.0.0.1:%d" % port, "https://icanhazip.com"],
            capture_output=True, text=True)
        ip = out.stdout.strip()
        seen.append(ip)
        print("  第 %d 次出口 IP: %s" % (i + 1, ip or "（失败）"))
    if len(set(seen)) == 1 and seen[0]:
        print("两次出口 IP 相同——可能两条链路 NAT 到同一个公网地址，看日志里的 if 编号更准")
    return 0 if all(seen) else 1


# ---------------------------------------------------------------- 入口

def main():
    global _log_path
    ap = argparse.ArgumentParser(description="macOS 双链路分流代理")
    ap.add_argument("--port", type=int, default=1080)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--primary", default="")
    ap.add_argument("--secondary", default="")
    ap.add_argument("--mode", choices=["split", "primary", "secondary"], default="split")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--probe", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--setup-routes", action="store_true")
    ap.add_argument("--remove-routes", action="store_true")
    ap.add_argument("--force", action="store_true", help="缺 ifscope 路由也照常启动")
    ap.add_argument("--log", default="")
    args = ap.parse_args()

    _log_path = args.log or None
    links = get_links()
    if not links:
        print("没有找到任何已连接且带 IPv4 的网卡")
        return 1

    if args.list:
        show_links(links)
        return 0

    if args.setup_routes or args.remove_routes:
        return setup_routes(links, remove=args.remove_routes)

    prim, sec = pick_links(links, args.primary, args.secondary)

    if args.mode == "split" and not sec:
        print("只找到一条可用链路（%s）。请确认第二张网卡已连接。" % prim["name"])
        return 1
    if args.mode == "secondary" and not sec:
        print("只找到一条链路，没有第二条可选")
        return 1

    targets = {"primary": [prim], "secondary": [sec]}.get(args.mode) or [prim, sec]
    targets = [x for x in targets if x]

    if args.probe:
        return probe(targets)

    if args.selftest:
        return selftest(targets, args.port)

    # split 模式下副链路必须有 ifscope 默认路由，否则绑定后 EHOSTUNREACH
    missing = [x for x in targets if not x["ifscope"] and not x["global_default"]]
    if missing and not args.force:
        for x in missing:
            print("副链路 %s 缺少 ifscope 默认路由，绑定后连接会失败。" % x["name"])
            print("  先执行： sudo route -n add -ifscope %s default %s" % (x["name"], x["gw"] or "<网关>"))
            print("  或执行： python3 %s --setup-routes" % os.path.basename(sys.argv[0]))
        return 1

    indices = [socket.if_nametoindex(x["name"]) for x in targets]
    log("链路: " + ", ".join("%s(if%d)" % (x["name"], i) for x, i in zip(targets, indices)))
    proxy = Proxy(indices, ",".join(x["name"] for x in targets))

    def stop(_sig, _frm):
        log("收到退出信号")
        sys.exit(0)

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    serve(proxy, args.host, args.port)
    return 0


if __name__ == "__main__":
    sys.exit(main())
