# macOS 版：双网卡分流

跟 Windows 版同一套思路：**按连接**把流量轮流绑到两张网卡上，让两条链路各跑一半连接。
不是把单条连接的带宽叠加起来——单线程下载再快也只走一条链路，并发下载/多标签页/多任务才吃到叠加收益。

| Windows | macOS | 作用 |
| --- | --- | --- |
| `split-proxy.ps1` | `split-proxy.py` | SOCKS5 + HTTP CONNECT 分流代理 |
| `multi-fetch.ps1` | `multi-fetch.sh` | 分段并发下载，带单连接对照 |
| `dl.ps1` | `dl.sh` | 起代理 + 下载一步到位 |
| `app-split.ps1` / `.bat` | `app-split.sh` | 让某个 App 走代理 |

## 为什么 macOS 版多一步

Windows 用 `IP_UNICAST_IF` 绑网卡，绑完就能按该网卡的路由表直接出去。macOS 用
`IP_BOUND_IF`（`IPPROTO_IP, 25`），但 macOS 的路由表默认只有一条全局默认路由，
并且它带 `ifscope`。绑定到副网卡的 socket 在路由表里找不到匹配项，会直接
`EHOSTUNREACH`。所以每条副链路要先补一条 ifscope 默认路由：

```bash
sudo route -n add -ifscope en7 default 172.20.10.1
```

`--setup-routes` 会替你跑（需要 sudo 密码）。**这个路由不持久**：重启、拔插网卡、
换 Wi-Fi 之后都要重加，换网络后网关变了也要改。

## 环境要求

- macOS 12 或更新
- `python3`（Xcode 命令行工具自带；也可以 `brew install python`）
- `curl`（系统自带）

```bash
cd mac
chmod +x split-proxy.py multi-fetch.sh dl.sh app-split.sh
```

## 第一次使用

```bash
# 1. 看有哪些链路，出口归属对不对
python3 split-proxy.py --list
#   [1] en0  Wi-Fi        10.66.82.96  网关 10.66.80.1  物理 | 出口 校园网 | 默认路由 是
#   [2] en7  iPhone USB   172.20.10.2  网关 172.20.10.1 物理 | 出口 iPhone蜂窝 | 默认路由 否（--setup-routes）

# 2. 给副链路补 ifscope 默认路由（要 sudo）
python3 split-proxy.py --setup-routes

# 3. 每条链路各测 500KB，确认都能出去
python3 split-proxy.py --probe

# 4. 起代理
python3 split-proxy.py --port 1080
```

`--list` 的出口归属和 Windows 版是同一张表：`10.66.80.0/21` 校园网、
`172.20.10.0/28` iPhone 蜂窝、`192.168.42/43/49.0/24` 手机共享、`192.168.137.0/24` ICS。
看到「iPhone蜂窝」就说明这条链路在花流量。

## 让程序走代理

**方式一：系统代理**（只影响遵守系统设置的 App）

系统设置 → 网络 → 当前服务 → 详细信息 → 代理 → SOCKS5 代理，填 `127.0.0.1:1080`。

**方式二：按 App 注入环境变量**

```bash
./app-split.sh Safari                  # 设好变量再打开
./app-split.sh -p 1080 "Google Chrome"
./app-split.sh --status                # 看当前值
./app-split.sh --off                   # 清掉
```

`launchctl setenv` 只对**之后新启动**的进程生效，已经开着的 App 要先退出。

**方式三：命令行**

```bash
export ALL_PROXY=socks5h://127.0.0.1:1080
export HTTPS_PROXY=http://127.0.0.1:1080
```

## 下载

```bash
# 直接分段并发，默认直连（不理系统代理）
./multi-fetch.sh -u https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ls-lR.gz -o /tmp/a.gz -t 8

# 走代理，吃双链路
./multi-fetch.sh -u <URL> -o out.bin -t 8 -p socks5h://127.0.0.1:1080

# 起代理 + 下载一步到位
./dl.sh -u <URL> -o out.bin -t 8
```

输出里有两个数：**墙钟吞吐**是真实速率，**分段合计**是把每段自己的窗口速度相加，
会偏高，只用来判断有没有跑满。

`--compare` 会用单连接再拉一遍同一区间，打印倍数——判断叠加是否真的生效。

## 排查

```bash
# 副链路的 ifscope 默认路由在不在
route -n get -ifscope en7 default

# 路由表里有没有两条 default
netstat -rn -f inet | grep default

# 代理日志（每条连接走了哪张网卡）
python3 split-proxy.py --port 1080 --log /tmp/split-proxy.log
```

常见错误：

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `副链路 en7 缺少 ifscope 默认路由` | 没跑 `--setup-routes`，或重启后丢了 | 重跑 `--setup-routes` |
| `EHOSTUNREACH` | 同上；或网关填错 | `--list` 看网关，重加路由 |
| 只有一条链路 | 第二张网卡没有 IPv4 / 没 DHCP 到地址 | `--list` 里看不到就先修网卡 |
| 两次出口 IP 一样 | 两条链路 NAT 到同一公网地址 | 看日志里的 `if` 编号；校园网常见 |
| 速度没涨 | 单连接本来就走一条链路；或对端按账号限速 | 用 `--compare` 和两个设备分别测 |

## 限制

- 连接级分流，不聚合单连接带宽。浏览器开多个连接、下载器多线程才吃得到。
- 校园网若按账号或 AP 限速，两条链路在同一 AP 上不会翻倍，换个出口（有线/另一台手机）才有意义。
- `--setup-routes` 改的是系统路由表，`--remove-routes` 可撤销。
- 代理只监听 `127.0.0.1`，局域网其他设备用不了（要开放改 `--host 0.0.0.0`，自行评估风险）。
