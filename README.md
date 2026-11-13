# 并行网络工具箱

两个本机网络工具，互不依赖，可单独开、单独关。提供 **Tauri 桌面版**（Windows / macOS）与原来的 PowerShell 脚本版。

| 工具 | 解决什么 | 管理员 |
| --- | --- | --- |
| **双链路并行** | 两条出口不同的网卡按连接分流，多线程下载叠加带宽 | 不需要 |
| **Steam 社区直连** | SNI 被墙时仍能打开 Steam 社区 / 市场 / 创意工坊 | 需要 |

两者都**不装驱动、不建虚拟网卡、不改系统路由**。

---

## 桌面版（推荐）

原生窗口，Windows 与 macOS 同一套界面。

从 [Releases](https://github.com/rainy-rain/parallel-network-adaptors/releases) 下载对应平台的安装包：

| 平台 | 文件 |
| --- | --- |
| Windows 10/11 x64 | `ParallelNetworkToolkit_*_x64-setup.exe`（NSIS）或 `.msi` |
| macOS 11+ Apple Silicon | `ParallelNetworkToolkit_*_aarch64.dmg` |
| macOS 11+ Intel | `ParallelNetworkToolkit_*_x64.dmg` |

安装包自带运行所需的脚本，首次启动会把它们释放到应用数据目录；`caddy` 二进制由构建时打进包内（Windows 为 `caddy.exe`，macOS 为 `caddy`）。

自己编译：

```bash
cd desktop
pnpm install
node node_modules/@tauri-apps/cli/tauri.js icon icon-source.png   # 仅首次
pnpm tauri build
```

产物在 `desktop/src-tauri/target/release/bundle/`。

**macOS 首次打开**：未签名/未公证的包会被 Gatekeeper 拦下，右键 →「打开」，或

```bash
xattr -dr com.apple.quarantine /Applications/ParallelNetworkToolkit.app
```

桌面版的「Steam 社区直连」在 macOS 上用的是 `SteamProxy.sh`：hosts 写入、根证书导入（`security add-trusted-cert`）、launchd 开机自启，逻辑与 Windows 版一一对应。

---

## 脚本版（Windows）

适合不想装应用的场合，全部是纯 PowerShell，可直接读改。

### 安装

```powershell
powershell -ExecutionPolicy Bypass -File .\installer\install.ps1
```

会做四件事：

1. 复制整个工具箱到 `%LOCALAPPDATA%\ParallelNetworkToolkit`
2. 准备 `caddy.exe`（仓库里有就复制，没有就从 caddyserver.com 下载）
3. 在桌面和开始菜单建「并行网络工具箱」快捷方式
4. 把卸载脚本一并放进安装目录

加 `-StartNow` 可在装完后立即开启 Steam 社区反代。

装完双击桌面「并行网络工具箱」，两个工具二选一。

卸载：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ParallelNetworkToolkit\installer\uninstall.ps1"
```

---

## 界面说明（每个按钮是干什么的）

窗口分三个标签页，对应三个互相独立的工具。**鼠标悬停在任何按钮上也会显示同一段说明。**

### 顶栏

| 控件 | 作用 |
|---|---|
| 平台标签 | 显示当前识别到的系统（Windows / macOS）；决定走 `.ps1` 还是 `.sh` / `.py` |
| **刷新状态** | 重新读三项状态。每次都要起一次 PowerShell，约 1 秒 |
| 状态栏（底部） | 显示当前正在做什么、上一次操作的结果 |

### 标签页一：双链路并行

把多条网卡同时在一条本地 SOCKS5 端口上并行出口。**不需要管理员，不改路由，不装驱动。**

| 控件 | 作用 |
|---|---|
| **重新检测链路** | 枚举网卡，只保留「已启用 + 有 IPv4 + 有默认网关」的，标出物理 / 虚拟与出口归属（校园网 / 手机蜂窝 / ICS 共享…） |
| **链路自检** | 让每条链路各下载 500 KB，验证它**真的能出网**，并报出速度。链路表里有不代表能上网 |
| **启动分流** | 在 `127.0.0.1:1080` 起 SOCKS5。新连接按网卡轮询分发 |
| **停止分流** | 停掉并释放 1080 |
| **打开分流日志** | 打开分流器自己的日志文件 |
| **用代理重启选中进程** | 给选中的程序设 `HTTP_PROXY` / `ALL_PROXY` 后重启它 —— 只有走系统代理的程序才吃得到这套分流 |
| **线程数** | 分片下载的并发线程数，默认 16。线程越多越容易吃满多条链路，小文件收益有限 |
| **分片（MB）** | 每个分片多大，默认 4 MB。文件要被切成这么多份才能并行下载 |
| **多线程下载测试** | 按上面两个参数跑一次真实下载，验证带宽是否真的叠加 |

**这个工具解决什么**：单条 TCP 只能走一条网卡，所以一条连接再快也压不满两条线。只有多线程 / 分片这类并发场景，才能把两条线的带宽加在一起。

### 标签页二：Steam 社区直连

社区和商店被按 SNI 拦掉时，在本机终结 TLS 再转发到 Valve 白名单域名（域前置）。

| 控件 | 作用 |
|---|---|
| **开启** | 起 Caddy（监听 443）→ 装本地根证书 → 写 hosts → 验证一次 → 注册开机自启。**需要管理员** |
| **关闭** | 停 Caddy → 清 hosts → 删自启任务，**保留根证书**（下次开启更快） |
| **自检** | 四项状态（Caddy / hosts / 证书 / 443）+ SNI 是否还被封 + 反代能否连通 + 真的用浏览器拉一次首页 |
| **打开日志** | Caddy 访问日志（JSON，一次请求一行，含状态码、耗时、大小、UA） |
| 四行状态 | Caddy 进程 / hosts 是否写入 / 根证书是否已装 / 443 是否在听 |

**这个工具解决什么**：浏览器和 Steam 客户端把 SNI 写死在程序里，改不了。所以只能在本机做 TLS 终结 —— 客户端以为自己在跟 `steamcommunity.com` 说话，实际是 Caddy；Caddy 再以 `steampowered.com` 的身份去连 Akamai，回程原样交回。

### 标签页三：CM 直连中继

Steam 底部显示 NO CONNECTION、好友与聊天掉线 —— 这是 CM 连不上，与商店/社区无关。

| 控件 | 作用 |
|---|---|
| **开启 CM 直连** | 起中继（24 个 DC × 22 端口 = **528 个本地监听**）→ 写 hosts → 刷 DNS 缓存。**约 17 秒**。完成后要**彻底退出 Steam 再启动**（托盘右键退出，不是关窗口） |
| **关闭 CM 直连** | 停中继 → 从 hosts 删掉 CM 那一段 → 完全恢复原状 |
| **测速** | 对 4 个 DC 各做一次 TLS 握手，验证分片是否真的绕过了 DPI，报出握手耗时 |
| **打开日志** | 中继日志，每次连接一行（accept / tunnel up / 对端 IP） |
| 四行状态 | 是否在跑 / 监听数 / DC 数 / hosts 是否写入 / 中继进程 PID |

**这个工具解决什么**：这台网络对 CM 的 TLS 握手做 IP 级阻断（TCP 通、明文通、ClientHello 一发出就 RST），但 **DPI 不做 TCP 流重组**。所以把首包切成 20 字节一段、间隔 3 ms 写出去就能过。**全程走本地回环，不经过任何代理节点。**
## 工具一：双链路并行

把 Windows 上两条**互相独立**的链路（比如 校园网 Wi-Fi + 手机 USB 共享）按连接分流，让支持代理的软件同时使用两条线路。

> 它做的是**连接级分流**，不是带宽聚合：一条 TCP 连接只能走一条链路，只有多连接下载（多线程 / 分片）才可能叠加。

### 原理

1. 本机起一个 SOCKS5 + HTTP CONNECT 代理（默认 `127.0.0.1:1080`）；
2. 每进来一条连接，用 Windows 的 `IP_UNICAST_IF`（socket 选项 31）**强制指定出口网卡**，再按连接轮询；
3. 因为是在 socket 层指定网卡，**不需要管理员权限、不改系统路由、不干扰 VPN / TUN**；
4. 下载器把文件切成多段 → 每段各自命中不同网卡 → 两条链路同时跑。

### 图形界面

双击 `gui\AdaptersGUI.ps1`，或从工具箱启动器进入。

- **重新检测链路**：列出所有 Up 状态、有默认网关的网卡，标出物理/虚拟与出口归属
- **链路自检**：每条链路各下载约 500 KB，看到两行 OK 才算通
- **启动 / 停止分流**：在 `127.0.0.1:1080` 起停代理
- **用代理重启选中进程**：列出有窗口的进程，双击即用代理环境重启
- **多线程下载测试**：调 `multi-fetch.ps1`，看叠加效果

命令行模式（不开窗口）：

```powershell
powershell -ExecutionPolicy Bypass -File .\gui\AdaptersGUI.ps1 -Status
powershell -ExecutionPolicy Bypass -File .\gui\AdaptersGUI.ps1 -StartQuiet
powershell -ExecutionPolicy Bypass -File .\gui\AdaptersGUI.ps1 -StopQuiet
```

### 脚本清单

| 文件 | 作用 |
| --- | --- |
| `split-proxy.ps1` | 分流代理（SOCKS5 + HTTP CONNECT），自动探测网卡；`-Probe` 自检、`-List` 查看链路 |
| `multi-fetch.ps1` | 多线程分段下载器（IDM 原理），支持 `-Proxy` |
| `dl.ps1` | 一键：自动检查并启动分流器 + 多线程下载 |
| `app-split.ps1` | 列出有窗口且联网的进程，选择后用代理环境重启它 |
| `app-split.bat` | 双击入口：先自检链路，再选择软件 |

### 环境要求

- Windows 10 / 11，PowerShell 5.1+
- 两条**物理**且**出口不同**的链路（例如 校园网 Wi-Fi + 手机 USB 共享）
- 手机必须是 **USB 共享**；「手机开 Wi-Fi 热点让电脑连」不行 —— 一块无线网卡不能同时关联两个 Wi-Fi

### 快速开始

双击 `app-split.bat` → 自动自检 → 输入编号选择要分流的软件。

命令行方式：

```powershell
# 查看当前可用链路
powershell -ExecutionPolicy Bypass -File .\split-proxy.ps1 -List

# 链路自检（每条链路下载 500 KB，通过返回 0，失败返回 1）
powershell -ExecutionPolicy Bypass -File .\split-proxy.ps1 -Probe

# 双线下载
powershell -ExecutionPolicy Bypass -File .\dl.ps1 -Url https://example.com/big.iso -Threads 16
```

自检输出示例：

```
自检目标: mirrors.tuna.tsinghua.edu.cn (101.6.15.130)，每条约 500 KB
  [主] WLAN        10.66.81.134 ... 连接  145 ms | 下载  0.51 MB/s | OK
  [副] 以太网 2     192.168.0.2  ... 连接  191 ms | 下载  0.50 MB/s | OK
自检通过
```

### 软件支持度与验证

#### 列表里的标记

| 标记 | 来源 | 含义 |
| --- | --- | --- |
| `[支持]` / `[部分]` / `[不支持]` | 内置名单 | 已人工确认过的常见软件 |
| `[支持*]` | 静态扫描 | EXE 导入了 `winhttp`/`wininet`/`libcurl`，或属于 Electron/Chromium/CEF |
| `[很可能*]` | 静态扫描 | Qt Network 程序，通常跟随系统代理 |
| `[未知*]` | 静态扫描 | 只看到 `ws2_32`，或读不到导入表（加壳/动态加载） |
| `[不支持*]` | 静态扫描 | 没有网络导入表 |

带 `*` 的只是静态推断，不代表一定能用。

#### 启动后实测（自动）

选好软件并启动后，脚本会观察 12 秒：

- 统计经过代理端口的连接峰值——有连接说明它确实走了代理；
- 同时统计两条网卡各自的峰值速率——两边都有流量才算真的双线。

```
正在观察 12 秒：确认是否真的走代理、两条链路是否都在动 ...
  实测：经代理的连接峰值 8 条 → 该软件确实走了代理
  WLAN: 峰值 212.6 Mbps
  以太网 2: 峰值 24.7 Mbps
```

也可以手动触发：`app-split.ps1 -Verify -Port 1080`。

> 当检测到 DNS 返回 `198.18.x`（Clash TUN 的 fake-IP）时，代理会用 DoH 重新解析真实 IP，避免连到假地址。

### 链路出口识别

`-List` 会按网段标出每张网卡的出口归属，避免把蜂窝链路当成校园网：

```
可用链路（按优先级排序）：
  [1] WLAN      10.66.81.134 网关 10.66.80.1  度量 30 物理 | 出口 校园网
  [2] 以太网 2   192.168.0.2  网关 192.168.0.1 度量 35 物理 | 出口 手机共享
```

内置网段：校园网 `10.66.80.0/21`、iPhone 蜂窝 `172.20.10.0/28`、手机共享 `192.168.42/43/49.0/24`、ICS `192.168.137.0/24`。

`multi-fetch` 不带 `-Proxy` 时会强制直连（`--noproxy *`），不会误走系统代理。

### 实测参考

同一台机器、校园网 Wi-Fi + 手机 USB 共享：

| 配置 | 速度 |
| --- | --- |
| 单走 Wi-Fi，8 线程 | 50.4 Mbps |
| 单走手机 USB，4 线程 | 30.9 Mbps |
| 两条分流，8 线程 | 59.6 Mbps |

叠加后的上限约等于两条链路之和（50 + 31 ≈ 80 Mbps），不是翻倍。

### 限制

| 限制 | 说明 |
| --- | --- |
| 单连接不会变快 | 一条 TCP 流只能走一条链路 |
| 非代理型软件用不了 | Steam、游戏启动器、Windows Update 需要 `/32` 路由或双 WAN 路由器 |
| 仅 Windows | 依赖 `IP_UNICAST_IF` |
| 只处理 TCP | UDP / QUIC 不走代理（浏览器会自动回落 TCP） |
| 手机流量计费 | 第二条链路走蜂窝网络会产生流量费用 |

`mac/` 下另有一份 macOS 实现（Python + Shell），原理相同，用 `SO_BINDTODEVICE` 替代。

---

## 工具二：Steam 社区直连

校园网 / 企业网里 `steamcommunity.com` 常被按 **SNI 字符串**阻断：TLS ClientHello 里的 Server Name 命中黑名单，连接立刻被 RST。所有依赖该域名的页面（社区、市场、创意工坊、个人资料）全部打不开。

这个工具**不依赖代理、不建虚拟网卡**，只在本机做一件事：**终结 TLS，再用 Akamai 域前置转发**。

### 原理

1. 把 `steamcommunity.com` 的 hosts 指向 `127.0.0.1`；
2. 本机 Caddy 在 443 监听，用自签根证书对浏览器出示 `steamcommunity.com` 的证书；
3. Caddy 再向上游发起**真正的 TLS**，但：
   - `SNI = steampowered.com`（未被封的 Valve 白名单域名）
   - `Host = steamcommunity.com`
4. Akamai 校验通过这张 Valve 多域名证书（一张证书覆盖 47 个 Valve 域），按 `Host` 把请求路由到社区源站，回包照原路返回。

### 为什么 SNI 再封也能用

它**从头到尾都不用 `steamcommunity.com` 作为 SNI**，所以：

| 情况 | 结果 |
| --- | --- |
| SNI 解封 | 可用，多一跳本地转发（约 +0.1s） |
| SNI 重新封 | 可用 —— 这正是它的设计目标 |
| `steampowered.com` 也被拉黑 | 才会失效，把 Caddyfile 里的上游换成 `steam.tv` 或 `steamgames.com`（同一张证书覆盖） |

### 图形界面

双击 `steam-community\SteamProxy.ps1`，或从工具箱启动器进入。

- **开启**：启动 Caddy → 装根证书 → 写 hosts → 验证 HTTP 200 → 注册开机自启
- **关闭**：停 Caddy → 清 hosts → 删自启任务（根证书保留）
- **自检**：查四项状态 → Cloudflare DoH + `--resolve` 探测 SNI 是否被封 → 测本机反代 → Edge 无头加载社区页
- **卸载**：撤销全部改动

命令行模式：

```powershell
powershell -ExecutionPolicy Bypass -File .\steam-community\SteamProxy.ps1 -Test
powershell -ExecutionPolicy Bypass -File .\steam-community\SteamProxy.ps1 -EnableQuiet
powershell -ExecutionPolicy Bypass -File .\steam-community\SteamProxy.ps1 -DisableQuiet
```

### 实测数据

```
Caddy 进程：运行中 PID 8832
443 监听：是
hosts 指向：127.0.0.1
根证书：已信任
SNI 未封：真实 IP 23.15.140.216，HTTP 200，TLS 握手成功 0.268s
本机反代：HTTP 200，耗时 0.483s
浏览器加载：DOM 174,192 字符，title=[Steam Community]
```

`access.log` 里能看到 Steam 客户端自己的请求：

```
"User-Agent": ["Mozilla/5.0 (Windows NT 10.0; Win64; x64; Valve Steam Client/default/1792618285) ..."]
"uri": "/gid/.../ajaxgetvanityandclanid/?origin=https://steamloopback.host"
"status": 200
```

即 **Steam 客户端内嵌浏览器也走通了**，不只是系统浏览器。

### 已知限制

1. **登录仍需临时开代理**：`login.steampowered.com` 的域前置被 Akamai 返回 403（它校验 SNI 与 Host 一致性）。登录时开一次代理，登录完关掉。
2. **部分 API 模块可能空白**：`api.steampowered.com` 同理。社区主页、市场、创意工坊、个人资料不受影响。
3. **443 端口独占**：本工具占用本机 443。装了 IIS 或其他 HTTPS 服务需先让出。
4. **hosts 偶被占用**：脚本已做 6 次重试（间隔 400ms），仍失败会在日志里明确报错。

---

## 工具三：Steam CM 直连（TLS 分片）

Steam 底部状态栏显示 **NO CONNECTION**，库里能看、头像能显示，但好友和聊天一直掉线。这不是商店或社区的问题，是 **CM（连接管理器）** 连不上。

### 原理

Steam 的 CM 走自己的 TCP 协议（27015–27036 端口，WebSocket 走 443），**不读系统代理**（注册表 `HKCU\Software\Valve\Steam` 的 `ProxyMode` 是空的），所以 Clash 之类设了系统代理也管不到它。

实测该网络对 CM 的处理是：**TCP 三次握手放行，ClientHello 一发出去就回 RST**。24 个 CM 域名 × 23 个端口 = 552 个组合，TLS 成功 0 个；但同一批 IP 的 80 端口明文 HTTP 是 404 正常。也就是说封的是 **TLS 握手**，不是 IP 也不是端口。

关键发现：**这台网络的 DPI 不做 TCP 流重组**，只在单个 TCP 段内匹配 ClientHello 的特征。于是把首包切开分几次发出去就能过：

| 每段字节 | 段间延迟 | 结果 |
|---|---|---|
| 1 | 30 ms | OK（TLS 1.2 握手成功）|
| 3 | 10 ms | OK |
| 10 | 5 ms | OK |
| 50 | 2 ms | OK |
| 1000（不分片）| 0 | **RST** |

所以不需要任何代理：本机起一个转发器，把 Steam 发给 CM 的字节切成 20 字节一段、间隔 3 ms 写出去，CM 回来的数据原样转发。全程走本地回环，**不经过任何境外节点**。

### 结构

- `cm-splitter.ps1` — 启停、状态、测速，并维护 hosts
- `CmSplitter.cs` — 转发器本体（`TcpListener` + 分片写 + 双向 `Pump`）
- 24 个 CM 域名指向 `127.0.0.2`–`127.0.0.25`，每个 IP 上监听 22 个端口（27015–27036），共 **528 个监听**
- hosts 里由 `# === SteamCM BEGIN ===` / `# === SteamCM END ===` 包住的那一段，关闭时整段删除

### 用法

桌面版：Steam 标签页顶部的「CM 直连中继」卡片 → **开启**。

命令行：

```powershell
# 开启（起转发器 + 写 hosts + 刷新 DNS 缓存）
powershell -ExecutionPolicy Bypass -File cm-splitter.ps1 -Action enable

# 看状态
powershell -ExecutionPolicy Bypass -File cm-splitter.ps1 -Action status

# 测速（4 个 DC）
powershell -ExecutionPolicy Bypass -File cm-splitter.ps1 -Action test

# 关闭（停转发器 + 清 hosts）
powershell -ExecutionPolicy Bypass -File cm-splitter.ps1 -Action disable
```

`status` 输出 `KEY=VALUE` 五行：`CM_ENABLED` / `CM_PID` / `CM_LISTENERS` / `CM_DC` / `CM_HOSTS`。

### 实测

```
CM_ENABLED=1  CM_PID=23100  CM_LISTENERS=528  CM_DC=24  CM_HOSTS=1

cmp1-hkg1  403  0.414s   （含 TLS 握手）
cmp2-hkg1  403  0.400s
cmp1-sgp1  403  0.760s
```

同一条 `cmp1-hkg1:27018` 走 SOCKS5 代理要 3.47 s，分片中继 **0.41 s**，快 8 倍，而且不消耗节点流量。

Steam 侧日志确认：

```
ConnectionCompleted() (127.0.0.2:27020, WebSocket)
[Connected, 4, 7] Logging on [U:1:...]
[Logged On, 4, 7] processing complete
```

### 已知限制

- 仅 Windows。macOS 上这个卡片会提示不支持。
- 24 个 DC 里约 18 个可用；`cmp1/2-tyo3`、`ext1/2-bom2`、`ext1/2-maa2` 是 IP 本身路由不通，不是 DPI 问题。
- 需要 528 个监听端口，防火墙弹窗要允许。
- 开过 UU 加速器后它可能改写 hosts，重新点一次「开启」即可覆盖回来。
## 目录结构

```
.
├── split-proxy.ps1          双链路分流代理
├── multi-fetch.ps1          多线程分段下载
├── dl.ps1                   一键下载
├── app-split.ps1 / .bat     进程级分流
├── mac/                     macOS 实现
├── gui/
│   ├── Launcher.ps1         工具箱启动器
│   └── AdaptersGUI.ps1      双链路并行 图形界面
├── cm-splitter.ps1        # CM 直连中继（启停 / 状态 / 测速）
├── CmSplitter.cs          # 分片转发器本体
├── steam-community/
│   ├── SteamProxy.ps1       Steam 社区直连 图形界面
│   └── Caddyfile            反代规则
└── installer/
    ├── install.ps1          安装
    └── uninstall.ps1        卸载
```

`caddy.exe`（约 51 MB）不进仓库，安装时按需下载或从本地复制。

---

## 排错

| 现象 | 位置 |
| --- | --- |
| 分流器启不来 | `%TEMP%\split-proxy.log`，或 GUI 里点「打开分流日志」 |
| 只找到一条链路 | 确认手机 USB 共享已连接且分配了 IPv4 默认网关 |
| 端口被占用 | 分流器换 `-Port`，Steam 侧检查 443 |
| Steam 页面白屏 | 看 `steam-community\access.log` 有没有对应请求 |
| 证书告警 | 确认 `LocalMachine\Root` 里有 `Caddy Local Authority` 根证书 |

---

## 许可

MIT