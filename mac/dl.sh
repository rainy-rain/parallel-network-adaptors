#!/bin/bash
# dl.sh —— 一步到位：先起分流代理，再用它并发下载
#
# 用法：
#   ./dl.sh -u <URL> -o <输出文件> [-t 8] [-p 1080] [--mode split|primary|secondary]
#
# 说明：代理是临时进程，下载结束自动关闭；想常驻就单独跑 split-proxy.py。

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
URL=""
OUT=""
THREADS=8
PORT=1080
MODE="split"
EXTRA=""

while [ $# -gt 0 ]; do
    if [ $# -lt 2 ]; then
        case "$1" in
            -h|--help) ;;
            *) echo "参数 $1 缺少值"; exit 1 ;;
        esac
    fi
    case "$1" in
        -u|--url)    URL="${2:-}"; shift 2 ;;
        -o|--out)    OUT="${2:-}"; shift 2 ;;
        -t|--threads) THREADS="${2:-}"; shift 2 ;;
        -p|--port)   PORT="${2:-}"; shift 2 ;;
        --mode)      MODE="${2:-}"; shift 2 ;;
        --primary)   EXTRA="$EXTRA --primary ${2:-}"; shift 2 ;;
        --secondary) EXTRA="$EXTRA --secondary ${2:-}"; shift 2 ;;
        -h|--help)   sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

[ -n "$URL" ] || { echo "缺少 -u <URL>"; exit 1; }

PY=${PYTHON:-python3}
command -v "$PY" >/dev/null 2>&1 || { echo "找不到 python3，先装 Xcode 命令行工具或 brew install python"; exit 1; }

echo "启动分流代理（$MODE 模式，端口 $PORT）..."
# shellcheck disable=SC2086
"$PY" "$HERE/split-proxy.py" --port "$PORT" --mode "$MODE" $EXTRA &
PID=$!
trap 'kill "$PID" 2>/dev/null' EXIT INT TERM

READY=0
n=0
while [ "$n" -lt 60 ]; do
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
        exec 3>&-
        READY=1
        break
    fi
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.1
    n=$((n + 1))
done

if [ "$READY" -ne 1 ]; then
    echo "代理没能起来，检查上面的报错（常见：副链路缺 ifscope 路由，先跑 --setup-routes）"
    exit 1
fi

bash "$HERE/multi-fetch.sh" -u "$URL" -o "$OUT" -t "$THREADS" --proxy "socks5h://127.0.0.1:$PORT"
