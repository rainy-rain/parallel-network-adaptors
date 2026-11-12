#!/bin/bash
# multi-fetch.sh —— macOS 版分段并发下载（bash 3.2 + 系统自带 curl）
#
# 和 Windows 版 multi-fetch.ps1 同一套思路：HEAD 探长度和 Range 支持，切段并发拉，
# 再顺序拼接。区别：这里只依赖 curl，不依赖 PowerShell；并发段的速度按「墙钟」
# 另算一遍，避免把各段自己的窗口速度相加导致虚高。
#
# 用法：
#   ./multi-fetch.sh -u <URL> -o <输出文件> [-t 线程数] [-c 分段MB] [-m 限流量MB]
#                    [-p socks5h://127.0.0.1:1080] [--compare] [-k]

set -u

URL=""
OUT=""
THREADS=8
CHUNK_MB=4
LIMIT_MB=0
PROXY=""
COMPARE=0
KEEP=0
MB=$((1024 * 1024))

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

while [ $# -gt 0 ]; do
    if [ $# -lt 2 ]; then
        case "$1" in
            --compare|-k|--keep|-h|--help) ;;
            *) echo "参数 $1 缺少值"; exit 1 ;;
        esac
    fi
    case "$1" in
        -u|--url)      URL="${2:-}"; shift 2 ;;
        -o|--out)      OUT="${2:-}"; shift 2 ;;
        -t|--threads)  THREADS="${2:-}"; shift 2 ;;
        -c|--chunk)    CHUNK_MB="${2:-}"; shift 2 ;;
        -m|--limit)    LIMIT_MB="${2:-}"; shift 2 ;;
        -p|--proxy)    PROXY="${2:-}"; shift 2 ;;
        --compare)     COMPARE=1; shift ;;
        -k|--keep)     KEEP=1; shift ;;
        -h|--help)     usage ;;
        *) echo "未知参数: $1"; usage ;;
    esac
done

[ -n "$URL" ] || { echo "缺少 -u <URL>"; exit 1; }
[ -n "$OUT" ] || OUT="$(basename "${URL%%\?*}")"
case "$THREADS" in ''|*[!0-9]*) echo "-t 需要整数"; exit 1 ;; esac
[ "$THREADS" -ge 1 ] || THREADS=1
[ "$THREADS" -gt 32 ] && THREADS=32
[ "$CHUNK_MB" -ge 1 ] || CHUNK_MB=4

# 默认直连：不让系统代理（Clash/Surge 常见 127.0.0.1:7897）混进来
if [ -n "$PROXY" ]; then
    PROXY_ARGS=(--proxy "$PROXY")
else
    PROXY_ARGS=(--noproxy "*")
fi

echo "目标: $URL"
echo "线程: $THREADS  分段: ${CHUNK_MB}MB${PROXY:+  代理: $PROXY}"

HEAD=$(curl -sIL --max-time 30 "${PROXY_ARGS[@]}" "$URL" 2>/dev/null | tr -d '\r')
if [ -z "$HEAD" ]; then
    echo "HEAD 请求失败：目标不可达或需要登录"
    exit 2
fi

TOTAL=$(printf '%s\n' "$HEAD" | awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}')
if [ "$TOTAL" -le 0 ]; then
    echo "拿不到 Content-Length，目标可能不支持分段"
    exit 2
fi
if ! printf '%s\n' "$HEAD" | grep -qi '^accept-ranges:[[:space:]]*bytes'; then
    echo "目标不支持 Accept-Ranges: bytes，无法并发分段"
    exit 2
fi

FETCH=$TOTAL
if [ "$LIMIT_MB" -gt 0 ]; then
    LIM=$((LIMIT_MB * MB))
    [ "$LIM" -lt "$TOTAL" ] && FETCH=$LIM
fi

MAXW=$((FETCH / (CHUNK_MB * MB)))
[ "$MAXW" -lt 1 ] && MAXW=1
[ "$THREADS" -gt "$MAXW" ] && WORKERS=$MAXW || WORKERS=$THREADS
PART=$(( (FETCH + WORKERS - 1) / WORKERS ))

echo "文件大小: $(awk -v b="$TOTAL" 'BEGIN{printf "%.1f MB", b/1048576}')  本次取: $(awk -v b="$FETCH" 'BEGIN{printf "%.1f MB", b/1048576}')  实际线程: $WORKERS"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/multifetch.XXXXXX") || exit 3
cleanup() {
    if [ "$KEEP" -eq 1 ]; then
        echo "分段保留在: $TMP"
    else
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT INT TERM

: > "$TMP/sizes.txt"
i=0
PIDS=""
while [ "$i" -lt "$WORKERS" ]; do
    START=$((i * PART))
    [ "$START" -ge "$FETCH" ] && break
    END=$((START + PART - 1))
    [ "$END" -ge "$FETCH" ] && END=$((FETCH - 1))
    SZ=$((END - START + 1))
    printf '%d %d\n' "$i" "$SZ" >> "$TMP/sizes.txt"
    (
        curl -sL --fail --max-time 900 "${PROXY_ARGS[@]}" \
             -r "${START}-${END}" -o "$TMP/part$(printf '%03d' "$i").bin" \
             -w '%{speed_download}' > "$TMP/spd$i.txt" 2> "$TMP/err$i.txt"
        echo $? > "$TMP/rc$i.txt"
    ) &
    PIDS="$PIDS $!"
    i=$((i + 1))
done

START_TS=$SECONDS
FAIL=0
for p in $PIDS; do
    wait "$p" || FAIL=1
done
ELAPSED=$((SECONDS - START_TS))
[ "$ELAPSED" -lt 1 ] && ELAPSED=1

GOT=0
while read -r idx need; do
    F="$TMP/part$(printf '%03d' "$idx").bin"
    RC=$(cat "$TMP/rc$idx.txt" 2>/dev/null || echo 1)
    if [ "$RC" -ne 0 ]; then
        echo "  段 $idx 下载失败: $(head -c 200 "$TMP/err$idx.txt" 2>/dev/null)"
        FAIL=1
        continue
    fi
    HAVE=$(stat -f%z "$F" 2>/dev/null || echo 0)
    GOT=$((GOT + HAVE))
    if [ "$HAVE" -ne "$need" ]; then
        echo "  段 $idx 长度不符：期望 $need，实际 $HAVE"
        FAIL=1
    fi
done < "$TMP/sizes.txt"

if [ "$FAIL" -ne 0 ]; then
    echo "有分段失败，未拼接。加 -k 可保留现场。"
    exit 4
fi

cat "$TMP"/part*.bin > "$OUT" || { echo "拼接失败"; exit 5; }
OUTSZ=$(stat -f%z "$OUT" 2>/dev/null || echo 0)
if [ "$OUTSZ" -ne "$GOT" ]; then
    echo "拼接后大小不符：$OUTSZ vs $GOT"
    exit 5
fi

SUM_BPS=$(cat "$TMP"/spd*.txt 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s+0}')
awk -v b="$SUM_BPS" -v g="$GOT" -v s="$ELAPSED" 'BEGIN{
    printf "完成: %.1f MB  用时 %d 秒\n", g/1048576, s
    printf "墙钟吞吐: %.2f MB/s (%.1f Mbps)\n", g/s/1048576, g*8/s/1000000
    printf "分段合计: %.2f MB/s (仅供参考，各段窗口不同会偏高)\n", b/1048576
}'

if [ "$COMPARE" -eq 1 ]; then
    echo "单连接对照（同一区间）..."
    SINGLE=$(curl -sL --fail --max-time 900 "${PROXY_ARGS[@]}" \
                  -r "0-$((FETCH - 1))" -o /dev/null -w '%{speed_download}' "$URL")
    awk -v s="$SINGLE" -v g="$GOT" -v t="$ELAPSED" 'BEGIN{
        printf "单连接: %.2f MB/s (%.1f Mbps)\n", s/1048576, s*8/1000000
        if (s > 0) printf "倍数: %.2fx\n", (g/t)/s
    }'
fi
