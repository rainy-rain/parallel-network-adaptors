#!/bin/bash
# app-split.sh —— 让某个 GUI App 走分流代理（macOS 版）
#
# 用法：
#   ./app-split.sh Safari              # 设代理变量并打开 App
#   ./app-split.sh -p 1080 "Google Chrome"
#   ./app-split.sh --off               # 清除代理变量
#   ./app-split.sh --status            # 看当前设置
#   ./app-split.sh --list              # 列出前台 App
#
# 注意：launchctl setenv 只影响「之后新启动」的进程。已经开着的 App 要先退出再开，
# 否则它还用旧环境。改完想彻底恢复，跑 --off 再重启 App。

set -u

PORT=1080
ACTION="run"
APP=""

while [ $# -gt 0 ]; do
    if [ $# -lt 2 ]; then
        case "$1" in
            --off|--status|--list|-h|--help) ;;
            *) echo "参数 $1 缺少值"; exit 1 ;;
        esac
    fi
    case "$1" in
        -p|--port) PORT="${2:-1080}"; shift 2 ;;
        --off)     ACTION="off"; shift ;;
        --status)  ACTION="status"; shift ;;
        --list)    ACTION="list"; shift ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         APP="$1"; shift ;;
    esac
done

PROXY="socks5h://127.0.0.1:$PORT"
HTTP_PROXY_V="http://127.0.0.1:$PORT"

case "$ACTION" in
    status)
        for k in ALL_PROXY HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
            printf '%-12s %s\n' "$k" "$(launchctl getenv "$k")"
        done
        exit 0
        ;;
    off)
        for k in ALL_PROXY HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
            launchctl unsetenv "$k"
        done
        echo "已清除代理变量（已运行的 App 需要重启才生效）"
        exit 0
        ;;
    list)
        osascript -e 'tell application "System Events" to get name of every process whose background only is false' \
            | tr ',' '\n' | sed 's/^ *//'
        exit 0
        ;;
esac

[ -n "$APP" ] || { echo "用法: $0 [-p 端口] <App 名称>；或 --off/--status/--list"; exit 1; }

launchctl setenv ALL_PROXY "$PROXY"
launchctl setenv HTTP_PROXY "$HTTP_PROXY_V"
launchctl setenv HTTPS_PROXY "$HTTP_PROXY_V"
launchctl setenv http_proxy "$HTTP_PROXY_V"
launchctl setenv https_proxy "$HTTP_PROXY_V"

echo "已设代理: SOCKS5 127.0.0.1:$PORT（变量已写入 launchd 用户环境）"
echo "提示：如果 $APP 已经在运行，先退出它；下面的 open 只会新开窗口。"
open -a "$APP" 2>/dev/null || { echo "打不开 $APP，检查 App 名称"; exit 1; }

echo
echo "命令行程序用这两行："
echo "  export ALL_PROXY=$PROXY"
echo "  export HTTPS_PROXY=$HTTP_PROXY_V"
