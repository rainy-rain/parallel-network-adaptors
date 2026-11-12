#!/bin/bash
# SteamProxy.sh — macOS 版「Steam 社区直连」
#
# 原理与 Windows 版一致：本机用 Caddy 终结 TLS（证书由 Caddy 本地 CA 签发），
# 再把请求以 SNI=steampowered.com 转发到 Valve 白名单域名，由 Akamai 按 Host
# 头路由回社区。对外只出现白名单域名的 SNI，因此与 steamcommunity.com 是否被封无关。
#
# 用法：
#   sudo ./SteamProxy.sh enable     开启
#   sudo ./SteamProxy.sh disable    关闭
#        ./SteamProxy.sh test       自检
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# 提权后 $HOME 会变成 /var/root，先记下原用户家目录
USER_HOME="${SUDO_USER_HOME:-$HOME}"
CADDYFILE="$ROOT/Caddyfile"
CADDY="$ROOT/caddy"
[ -x "$CADDY" ] || CADDY="$(command -v caddy 2>/dev/null || true)"

HOSTS="/etc/hosts"
BEGIN_MARK="# >>> SteamProxy BEGIN >>>"
END_MARK="# <<< SteamProxy END <<<"
DOMAINS=("steamcommunity.com" "www.steamcommunity.com")
PLIST="$USER_HOME/Library/LaunchAgents/com.mosesmuxixie.steamproxy.plist"
CA_CRT="$USER_HOME/Library/Application Support/Caddy/pki/authorities/local/root.crt"
LOG="$ROOT/access.log"
STDOUT_LOG="$ROOT/caddy.out.log"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] $*" >&2; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log "需要管理员权限，正在请求授权…"
    exec osascript -e "do shell script \"SUDO_USER_HOME='$HOME' /bin/bash '$ROOT/SteamProxy.sh' $*\" with administrator privileges"
  fi
}

caddy_pid() {
  pgrep -x caddy 2>/dev/null | head -n1
}

port_open() {
  /usr/sbin/lsof -nP -iTCP:443 -sTCP:LISTEN >/dev/null 2>&1
}

hosts_has_block() {
  grep -qF "$BEGIN_MARK" "$HOSTS" 2>/dev/null
}

ca_trusted() {
  /usr/bin/security find-certificate -c "Caddy Local Authority" -a \
      /Library/Keychains/System.keychain >/dev/null 2>&1
}

write_hosts() {  # $1 = on|off
  local mode="$1" tmp
  tmp="$(mktemp)"
  # 删掉旧块
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    !skip {print}
  ' "$HOSTS" > "$tmp"

  if [ "$mode" = "on" ]; then
    {
      echo ""
      echo "$BEGIN_MARK"
      for d in "${DOMAINS[@]}"; do echo "127.0.0.1 $d"; done
      echo "$END_MARK"
    } >> "$tmp"
  fi

  if [ ! -s "$tmp" ]; then
    warn "拒绝写入空 hosts（保护性中止）"
    rm -f "$tmp"
    return 1
  fi

  cat "$tmp" > "$HOSTS"
  rm -f "$tmp"
  /usr/bin/dscacheutil -flushcache 2>/dev/null || true
  /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
  return 0
}

install_ca() {
  if [ ! -f "$CA_CRT" ]; then
    warn "找不到 Caddy 根证书：$CA_CRT"
    return 1
  fi
  /usr/bin/security add-trusted-cert -d -r trustRoot \
      -k /Library/Keychains/System.keychain "$CA_CRT" 2>/dev/null
  ca_trusted
}

write_plist() {
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.mosesmuxixie.steamproxy</string>
  <key>ProgramArguments</key>
  <array>
    <string>$CADDY</string>
    <string>run</string>
    <string>--config</string>
    <string>$CADDYFILE</string>
  </array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>NO_PROXY</key><string>*</string>
    <key>no_proxy</key><string>*</string>
  </dict>
  <key>StandardOutPath</key><string>$STDOUT_LOG</string>
  <key>StandardErrorPath</key><string>$STDOUT_LOG</string>
</dict>
</plist>
PLISTEOF
  /bin/launchctl unload "$PLIST" 2>/dev/null || true
  /bin/launchctl load "$PLIST" 2>/dev/null || true
}

start_caddy() {
  if [ -z "$CADDY" ] || [ ! -x "$CADDY" ]; then
    warn "找不到 caddy 可执行文件。请先安装：brew install caddy"
    warn "或把 caddy 二进制放到：$ROOT/caddy"
    return 1
  fi
  if [ -n "$(caddy_pid)" ]; then
    log "Caddy 已在运行（PID $(caddy_pid)）"
    return 0
  fi
  log "启动 Caddy…"
  ( cd "$ROOT" && env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy NO_PROXY='*' no_proxy='*' nohup "$CADDY" run --config "$CADDYFILE" >>"$STDOUT_LOG" 2>&1 & )
  for _ in $(seq 1 40); do
    sleep 0.4
    if port_open; then
      log "443 已监听"
      return 0
    fi
  done
  warn "443 未在 16 秒内监听，查看日志：$STDOUT_LOG"
  return 1
}

stop_caddy() {
  /bin/launchctl unload "$PLIST" 2>/dev/null || true
  local pid
  pid="$(caddy_pid)"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      sleep 0.2
      [ -z "$(caddy_pid)" ] && break
    done
    [ -n "$(caddy_pid)" ] && kill -9 "$(caddy_pid)" 2>/dev/null || true
    log "已停止 Caddy（PID $pid）"
  fi
}

verify() {
  local code size
  code="$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 15 https://steamcommunity.com/ 2>/dev/null || echo 000)"
  size="$(/usr/bin/curl -s -o /dev/null -w '%{size_download}' --noproxy '*' --max-time 15 https://steamcommunity.com/ 2>/dev/null || echo 0)"
  if [ "$code" = "200" ] && [ "$size" -gt 1000 ]; then
    log "验证通过：HTTP $code，$size 字节"
    return 0
  fi
  warn "验证未通过：HTTP $code，$size 字节"
  return 1
}

cmd_enable() {
  need_root enable
  log "========== 开启 =========="
  start_caddy       || return 1
  install_ca        || warn "根证书导入失败，浏览器会报证书不受信任"
  write_hosts on    || return 1
  write_plist
  sleep 1
  verify
}

cmd_disable() {
  need_root disable
  log "========== 关闭 =========="
  stop_caddy
  write_hosts off && log "hosts 中的 Steam 条目已清除"
  if [ -f "$PLIST" ]; then
    /bin/launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    log "已删除开机自启项"
  fi
  log "已回到系统默认网络（根证书保留，可用 uninstall 清理）"
}

cmd_test() {
  log "========== 自检 =========="
  local pid
  pid="$(caddy_pid)"
  log "Caddy 进程：$([ -n "$pid" ] && echo "运行中 PID $pid" || echo "未运行")"
  log "443 监听：$(port_open && echo 是 || echo 否)"
  log "hosts 指向：$(hosts_has_block && echo 127.0.0.1 || echo 未配置)"
  log "根证书：$(ca_trusted && echo 已信任 || echo 未信任)"

  local ip
  ip="$(/usr/bin/curl -s --noproxy '*' --max-time 6 'https://cloudflare-dns.com/dns-query?name=steamcommunity.com&type=A' -H 'accept: application/dns-json' 2>/dev/null | /usr/bin/python3 -c 'import sys,json;d=json.load(sys.stdin);print(next((a["data"] for a in d.get("Answer",[]) if a["type"]==1),""))' 2>/dev/null || true)"
  if [ -n "$ip" ]; then
    log "SNI 探测：真实 IP $ip（当前 SNI 是否被封不影响本方案）"
  fi

  log "--- 本机反代连通性 ---"
  verify
}

usage() {
  cat <<EOF
SteamProxy.sh — macOS 版 Steam 社区直连

  enable    开启（启动 Caddy + 导入根证书 + 写 hosts + 开机自启）
  disable   关闭（停 Caddy + 清 hosts + 删自启）
  test      自检当前状态

前提：已安装 caddy（brew install caddy），或把 caddy 二进制放在本目录。
EOF
}

case "${1:-}" in
  enable)  cmd_enable ;;
  disable) cmd_disable ;;
  test)    cmd_test ;;
  *)       usage ;;
esac
