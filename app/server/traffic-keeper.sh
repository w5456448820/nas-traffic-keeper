#!/usr/bin/env sh
# =========================================================
#  Traffic Keeper - 主运行脚本
#  Version : 2.9.2
#  更新内容：
#    - 修复 busybox awk printf "%d" 大数溢出导致单日下载限额失效
#    - 修复 GitHub Release 链接抓取后丢失问题
#    - GitHub Release 链接跳过 HEAD 大小检查（CDN 返回假 Content-Length）
#    - 支持可选单位：时间(s/m/h)、数据(K/M/G/T)
# =========================================================
# set -e  # disabled for FPK native mode

echo "🐳 Traffic Keeper 容器启动中..."

DATA_DIR="${TK_DATA_DIR:-/app/data}"
DISPLAY_DIR="${TK_DISPLAY_DIR:-/app/流量统计}"
LINKS_DIR="${TK_DATA_DIR:-/app/data}/links"
mkdir -p "$DATA_DIR" "$DISPLAY_DIR" "$LINKS_DIR"

LAST_URL=""
FETCH_STAMP="$LINKS_DIR/.last-fetch"
LINK_CHECK_STAMP="$LINKS_DIR/.last-check"

get_today() { date +%F; }
data_file() { echo "$DATA_DIR/stats_data_$(get_today).log"; }
show_file() { echo "$DISPLAY_DIR/stats_show_$(get_today).log"; }

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# 解析数据大小字符串为字节（支持 K/M/G/T，如 "10K", "5M", "2G", "1T"）
parse_size() {
    val="${1:-0}"
    val="$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    num="$(echo "$val" | sed 's/[^0-9].*//')"
    unit="$(echo "$val" | sed 's/^[0-9]*//' | tr '[:upper:]' '[:lower:]')"
    [ -z "$num" ] && num=0
    is_uint "$num" || num=0
    case "$unit" in
        t|ti|tib|tb) awk "BEGIN {print int($num * 1099511627776)}" ;;
        g|gi|gib|gb) awk "BEGIN {print int($num * 1073741824)}" ;;
        m|mi|mib|mb) awk "BEGIN {print int($num * 1048576)}" ;;
        k|ki|kib|kb) awk "BEGIN {print int($num * 1024)}" ;;
        ''|b|byte|bytes) echo "$num" ;;
        *) echo "$num" ;;
    esac
}

# 解析时间字符串为秒（支持 s/m/h，如 "10s", "5m", "2h"）
parse_time() {
    val="${1:-0}"
    val="$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    num="$(echo "$val" | sed 's/[^0-9].*//')"
    unit="$(echo "$val" | sed 's/^[0-9]*//' | tr '[:upper:]' '[:lower:]')"
    [ -z "$num" ] && num=0
    is_uint "$num" || num=0
    case "$unit" in
        h|hour|hours) echo $((num * 3600)) ;;
        m|min|minute|minutes) echo $((num * 60)) ;;
        s|sec|second|seconds|'') echo "$num" ;;
        *) echo "$num" ;;
    esac
}

# 1024进制字节转人类可读格式（TiB/GiB/MiB/KiB，绝对无单位错误）
human_bytes() {
    VALUE="${1:-0}"
    is_uint "$VALUE" || VALUE=0
    # 顺序必须从大到小，确保优先匹配大单位
    for unit in TiB GiB MiB KiB B; do
        div=1
        case "$unit" in
            TiB) div=1099511627776 ;;  # 1024^4，之前你这里是错的！
            GiB) div=1073741824 ;;      # 1024^3
            MiB) div=1048576 ;;         # 1024^2
            KiB) div=1024 ;;            # 1024^1
            B)   div=1 ;;
        esac
        if [ "$VALUE" -ge "$div" ]; then
            echo "$(awk "BEGIN {printf \"%.2f\", $VALUE/$div}") $unit"
            return
        fi
    done
    echo "0 B"
}
# ===================================================================

human_seconds() {
    VALUE="${1:-0}"
    is_uint "$VALUE" || VALUE=0
    printf "%02d:%02d:%02d" "$((VALUE / 3600))" "$(((VALUE % 3600) / 60))" "$((VALUE % 60))"
}

next_wake_time() {
    date -d "+$1 seconds" +"%H:%M:%S" 2>/dev/null || echo "--:--:--"
}

normalize_url() {
    printf '%s' "$1" | tr -d '`' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

read_var() {
    FILE="$(data_file)"
    [ -f "$FILE" ] || { echo ""; return 0; }
    grep "^$1=" "$FILE" 2>/dev/null | cut -d= -f2- | tail -n 1 || true
}

apply_defaults() {
    LIMIT_RATE="${LIMIT_RATE:-5M}"
    SLEEP_MAX="${SLEEP_MAX:-15m}"
    SLEEP_MIN="${SLEEP_MIN:-1m}"
    DYNAMIC_SLEEP="${DYNAMIC_SLEEP:-true}"
    ROUND_MIN_BYTES="${ROUND_MIN_BYTES:-0}"
    RUN_TIMES_MAX="${RUN_TIMES_MAX:-3}"
    CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-15s}"
    MAX_TIME="${MAX_TIME:-50m}"
    RETRY="${RETRY:-5}"
    RETRY_DELAY="${RETRY_DELAY:-5s}"
    FETCH_INTERVAL="${FETCH_INTERVAL:-6h}"
    LINK_CHECK_INTERVAL="${LINK_CHECK_INTERVAL:-30m}"
    FETCH_MIN_FILE_BYTES="${FETCH_MIN_FILE_BYTES:-1G}"
    MAX_DAILY_BYTES="${MAX_DAILY_BYTES:-200G}"
    USER_AGENT="${USER_AGENT:-'traffic-keeper/2.9.2 curl/8.0'}"
    WEB_PORT="${WEB_PORT:-8080}"

    # 校验数据量配置（支持 K/M/G/T 可选单位，全部转为字节）
    ROUND_MIN_BYTES=$(parse_size "$ROUND_MIN_BYTES")
    FETCH_MIN_FILE_BYTES=$(parse_size "$FETCH_MIN_FILE_BYTES")
    MAX_DAILY_BYTES=$(parse_size "$MAX_DAILY_BYTES")
    
    # 校验时间配置（支持 s/m/h 可选单位，全部转为秒）
    SLEEP_MAX=$(parse_time "$SLEEP_MAX")
    SLEEP_MIN=$(parse_time "$SLEEP_MIN")
    CONNECT_TIMEOUT=$(parse_time "$CONNECT_TIMEOUT")
    MAX_TIME=$(parse_time "$MAX_TIME")
    RETRY_DELAY=$(parse_time "$RETRY_DELAY")
    FETCH_INTERVAL=$(parse_time "$FETCH_INTERVAL")
    LINK_CHECK_INTERVAL=$(parse_time "$LINK_CHECK_INTERVAL")
    
    # 确保都是无符号整数
    is_uint "$RUN_TIMES_MAX" || RUN_TIMES_MAX=3
    is_uint "$CONNECT_TIMEOUT" || CONNECT_TIMEOUT=15
    is_uint "$MAX_TIME" || MAX_TIME=3000
    is_uint "$RETRY" || RETRY=5
    is_uint "$RETRY_DELAY" || RETRY_DELAY=5
    is_uint "$FETCH_INTERVAL" || FETCH_INTERVAL=21600
    is_uint "$LINK_CHECK_INTERVAL" || LINK_CHECK_INTERVAL=1800
    is_uint "$SLEEP_MAX" || SLEEP_MAX=900
    is_uint "$SLEEP_MIN" || SLEEP_MIN=60
    is_uint "$WEB_PORT" || WEB_PORT=8080
    
    [ "$SLEEP_MIN" -gt "$SLEEP_MAX" ] && SLEEP_MIN=$SLEEP_MAX || true
}

reload_env() {
    echo ""
    echo "🔄 重新加载配置文件..."

    if ! . "${TK_ENV_FILE:-/app/.env}" >"${TK_DATA_DIR:-/app/data}/env_error.log" 2>&1; then
        echo "⚠️  配置文件有语法错误，保持当前配置继续运行"
        cat "${TK_DATA_DIR:-/app/data}/env_error.log" 2>/dev/null || true
        apply_defaults
        return 1
    fi

    apply_defaults

    # 校验数据量配置（支持 K/M/G/T 可选单位，全部转为字节）
    ROUND_MIN_BYTES=$(parse_size "${ROUND_MIN_BYTES:-0}")
    FETCH_MIN_FILE_BYTES=$(parse_size "${FETCH_MIN_FILE_BYTES:-0}")
    MAX_DAILY_BYTES=$(parse_size "${MAX_DAILY_BYTES:-0}")
    
    # 校验时间配置（支持 s/m/h 可选单位，全部转为秒）
    SLEEP_MAX=$(parse_time "${SLEEP_MAX:-0}")
    SLEEP_MIN=$(parse_time "${SLEEP_MIN:-0}")
    CONNECT_TIMEOUT=$(parse_time "${CONNECT_TIMEOUT:-0}")
    MAX_TIME=$(parse_time "${MAX_TIME:-0}")
    RETRY_DELAY=$(parse_time "${RETRY_DELAY:-0}")
    FETCH_INTERVAL=$(parse_time "${FETCH_INTERVAL:-0}")
    LINK_CHECK_INTERVAL=$(parse_time "${LINK_CHECK_INTERVAL:-0}")
    
    # 确保都是无符号整数
    is_uint "$SLEEP_MAX" || SLEEP_MAX=900
    is_uint "$SLEEP_MIN" || SLEEP_MIN=60
    is_uint "$CONNECT_TIMEOUT" || CONNECT_TIMEOUT=15
    is_uint "$MAX_TIME" || MAX_TIME=3000
    is_uint "$RETRY" || RETRY=5
    is_uint "$RETRY_DELAY" || RETRY_DELAY=5
    is_uint "$FETCH_INTERVAL" || FETCH_INTERVAL=21600
    is_uint "$LINK_CHECK_INTERVAL" || LINK_CHECK_INTERVAL=1800
    
    [ "$SLEEP_MIN" -gt "$SLEEP_MAX" ] && SLEEP_MIN=$SLEEP_MAX || true

    echo "✅ 配置已更新（单位已转为字节）"
}

rand_n() {
    MAX="${1:-1}"
    is_uint "$MAX" || MAX=1
    [ "$MAX" -lt 1 ] && MAX=1
    R="$RANDOM"
    DIV="$((32768 / MAX * MAX))"
    while [ "$R" -ge "$DIV" ]; do
        R="$RANDOM"
    done
    echo "$((R % MAX + 1))"
}

calc_sleep_time() {
    [ "$DYNAMIC_SLEEP" = "false" ] && { echo "$SLEEP_MIN"; return; }
    [ "${ROUND_SMALL_DOWNLOAD:-false}" = "true" ] && { echo "$SLEEP_MIN"; return; }

    MIN="${SLEEP_MIN:-60}"
    MAX="${SLEEP_MAX:-900}"
    is_uint "$MIN" || MIN=60
    is_uint "$MAX" || MAX=900

    [ "$MIN" -ge "$MAX" ] && { echo "$MIN"; return; }

    R="$RANDOM"
    DIFF="$((MAX - MIN + 1))"
    DIV="$((32768 / DIFF * DIFF))"
    while [ "$R" -ge "$DIV" ]; do
        R="$RANDOM"
    done
    OFFSET="$((R % DIFF))"
    echo "$((MIN + OFFSET))"
}

check_daily_limit() {
    MAX_BYTES="${MAX_DAILY_BYTES:-0}"
    is_uint "$MAX_BYTES" || MAX_BYTES=0
    [ "$MAX_BYTES" -le 0 ] && return 0
    CURRENT="$(read_var SIZE_BYTES)"
    CURRENT="${CURRENT:-0}"
    is_uint "$CURRENT" || CURRENT=0
    awk "BEGIN { exit ($CURRENT >= $MAX_BYTES) ? 1 : 0 }"
}

validate_data_file() {
    FILE="$(data_file)"
    [ -f "$FILE" ] || return 1
    grep -q "^DATE=" "$FILE" && \
    grep -q "^GENERATE_TIME=" "$FILE" && \
    grep -q "^COUNT=" "$FILE" && \
    grep -q "^SIZE_BYTES=" "$FILE" && \
    grep -q "^TIME_SECONDS=" "$FILE"
}

init_stats() {
    cat > "$(data_file)" <<EOS
DATE=$(get_today)
GENERATE_TIME=$(date +%H:%M:%S)
COUNT=0
SIZE_BYTES=0
TIME_SECONDS=0
EOS
}

generate_show_stats() {
    DATE="$(get_today)"
    TIME="$(read_var GENERATE_TIME)"
    COUNT="$(read_var COUNT)"
    SIZE_VALUE="$(read_var SIZE_BYTES)"
    TIME_VALUE="$(read_var TIME_SECONDS)"

    TIME="${TIME:-$(date +%H:%M:%S)}"
    COUNT="${COUNT:-0}"
    SIZE_VALUE="${SIZE_VALUE:-0}"
    TIME_VALUE="${TIME_VALUE:-0}"

    FLOW="$(human_bytes "$SIZE_VALUE")"
    DUR="$(human_seconds "$TIME_VALUE")"

    cat > "$(show_file)" <<EOS
===============================
       📊 流量下载信息统计
-------------------------------
 生成日期    ：${DATE}
 生成时间    ：${TIME}
 下载次数    ：${COUNT}
 下载流量    ：${FLOW}
 累计耗时    ：${DUR}
===============================
EOS
}

update_stats() {
    COUNT="$(read_var COUNT)"
    SIZE_BYTES="$(read_var SIZE_BYTES)"
    TIME_SECONDS="$(read_var TIME_SECONDS)"

    COUNT="${COUNT:-0}"
    SIZE_BYTES="${SIZE_BYTES:-0}"
    TIME_SECONDS="${TIME_SECONDS:-0}"
    is_uint "$COUNT" || COUNT=0
    is_uint "$SIZE_BYTES" || SIZE_BYTES=0
    is_uint "$TIME_SECONDS" || TIME_SECONDS=0

    ADD_SIZE="${1:-0}"
    ADD_TIME="${2:-0}"
    is_uint "$ADD_SIZE" || ADD_SIZE=0
    is_uint "$ADD_TIME" || ADD_TIME=0

    COUNT="$((COUNT + 1))"
    SIZE_BYTES="$((SIZE_BYTES + ADD_SIZE))"
    TIME_SECONDS="$((TIME_SECONDS + ADD_TIME))"

    cat > "$(data_file)" <<EOS
DATE=$(get_today)
GENERATE_TIME=$(date +%H:%M:%S)
COUNT=$COUNT
SIZE_BYTES=$SIZE_BYTES
TIME_SECONDS=$TIME_SECONDS
EOS

    generate_show_stats
}

[ -f "$(data_file)" ] || init_stats
validate_data_file || init_stats
generate_show_stats

should_fetch_links() {
    FETCHED_LIST="$LINKS_DIR/fetched-links.txt"
    [ -s "$FETCHED_LIST" ] || return 0
    [ -f "$FETCH_STAMP" ] || return 0

    NOW="$(date +%s)"
    LAST="$(stat -c %Y "$FETCH_STAMP" 2>/dev/null || echo 0)"
    AGE="$((NOW - LAST))"
    [ "$AGE" -ge "$FETCH_INTERVAL" ]
}

force_fetch_next_round() {
    rm -f "$FETCH_STAMP" "$LINK_CHECK_STAMP"
    echo "ℹ️  已标记下一轮重新抓取链接"
}

should_check_links() {
    [ -s "$LINKS_DIR/fetched-links.txt" ] || return 0
    [ -f "$LINK_CHECK_STAMP" ] || return 0

    NOW="$(date +%s)"
    LAST="$(stat -c %Y "$LINK_CHECK_STAMP" 2>/dev/null || echo 0)"
    AGE="$((NOW - LAST))"
    [ "$AGE" -ge "$LINK_CHECK_INTERVAL" ]
}

fetch_links() {
    if ! should_fetch_links; then
        echo "ℹ️  链接抓取未到间隔，跳过本轮抓取"
        return 0
    fi

    echo ""
    echo "🔄 正在重新抓取可用下载链接..."

    if [ -x "${TK_APP_DIR:-/app}/fetch-links.sh" ]; then
        if sh "${TK_APP_DIR:-/app}/fetch-links.sh" && [ -s "$LINKS_DIR/fetched-links.txt" ]; then
            date +%s > "$FETCH_STAMP"
            return 0
        fi
        echo "⚠️  链接抓取失败或未抓取到链接，本轮将使用 .env 链接"
        force_fetch_next_round
        return 1
    else
        echo "⚠️  未找到 fetch-links.sh，跳过抓取"
        force_fetch_next_round
        return 1
    fi
}

validate_link() {
    URL="$(normalize_url "$1")"
    [ -n "$URL" ] || return 1

    # GitHub Release 文件通常较大且 CDN 返回假 Content-Length，直接放行
    case "$URL" in
        *github.com*/releases/download/*)
            echo "✅ 可用链接：$URL（GitHub Release，跳过大小检查）"
            return 0
            ;;
    esac

    check_min_file_size() {
        SIZE_VALUE="$1"
        MIN_VALUE="${FETCH_MIN_FILE_BYTES:-0}"
        is_uint "$MIN_VALUE" || MIN_VALUE=0
        [ "$MIN_VALUE" -le 0 ] && return 0
        if ! is_uint "$SIZE_VALUE"; then
            echo "   [校验] ⚠️  无法确认文件大小，保留到下载时判断"
            return 2
        fi
        awk "BEGIN { exit ($SIZE_VALUE >= $MIN_VALUE) ? 0 : 1 }" && {
            echo "   [校验] ✅ 文件大小达标：$(human_bytes "$SIZE_VALUE")"
            return 0
        }
        echo "   [校验] ❌ 文件过小：$(human_bytes "$SIZE_VALUE") < $(human_bytes "$MIN_VALUE")"
        return 1
    }

    set +e
    HEAD_OUT="$(curl -IL --connect-timeout 5 --max-time 30 --fail -L \
        -A "$USER_AGENT" -w "\nHTTP_CODE=%{http_code}\n" "$URL" 2>&1)"
    CURL_EXIT=$?
# set -e  # disabled for FPK native mode

    HTTP_CODE="$(echo "$HEAD_OUT" | grep HTTP_CODE | tail -n 1 | cut -d= -f2)"

    if [ "$CURL_EXIT" -eq 0 ]; then
        case "$HTTP_CODE" in
            2*|3*)
                REMOTE_SIZE="$(echo "$HEAD_OUT" | tr -d '\r' | awk 'tolower($1)=="content-length:" {print $2}' | tail -n 1)"
                check_min_file_size "$REMOTE_SIZE"
                SIZE_CHECK_EXIT=$?
                if [ "$SIZE_CHECK_EXIT" -eq 0 ] || [ "$SIZE_CHECK_EXIT" -eq 2 ]; then
                    echo "✅ 可用链接：$URL"
                    return 0
                elif [ "$SIZE_CHECK_EXIT" -eq 1 ]; then
                    return 1
                fi
                ;;
        esac
    fi

    set +e
    RANGE_OUT="$(curl -sS -L --range 0-0 --connect-timeout 5 --max-time 30 \
        --fail -L -A "$USER_AGENT" -D - -o /dev/null "$URL" 2>&1)"
    CURL_EXIT=$?
# set -e  # disabled for FPK native mode

    if [ "$CURL_EXIT" -eq 0 ]; then
        REMOTE_SIZE="$(echo "$RANGE_OUT" | tr -d '\r' | awk 'tolower($1)=="content-range:" {split($0,a,"/"); print a[2]}' | tr -dc '0-9')"
        [ -n "$REMOTE_SIZE" ] || REMOTE_SIZE="$(echo "$RANGE_OUT" | tr -d '\r' | awk 'tolower($1)=="content-length:" {print $2}' | tail -n 1)"
        check_min_file_size "$REMOTE_SIZE"
        SIZE_CHECK_EXIT=$?
        if [ "$SIZE_CHECK_EXIT" -eq 0 ] || [ "$SIZE_CHECK_EXIT" -eq 2 ]; then
            echo "✅ 可用链接：$URL"
            return 0
        fi
    fi

    case "$CURL_EXIT" in
        28) echo "❌ 连接超时：$URL" ;;
        7)  echo "❌ DNS 或连接失败：$URL" ;;
        *)  echo "❌ 链接不可用 (code $CURL_EXIT, HTTP ${HTTP_CODE:-unknown})：$URL" ;;
    esac
    return 1
}

check_fetched_links() {
    FETCHED_LIST="$LINKS_DIR/fetched-links.txt"
    VALIDATED_LIST="$LINKS_DIR/validated_urls.list"
    INVALID_LIST="$LINKS_DIR/invalid_urls.list"

    [ -f "$FETCHED_LIST" ] || return 1
    [ -s "$FETCHED_LIST" ] || return 1

    if ! should_check_links; then
        echo "ℹ️  链接检测未到间隔，跳过本轮检测"
        return 0
    fi

    CHECK_START=$(date +%s)

    > "$VALIDATED_LIST"
    > "$INVALID_LIST"

    echo "🔍 正在逐条检查抓取到的链接..."

    while IFS= read -r URL; do
        URL="$(normalize_url "$URL")"
        [ -n "$URL" ] || continue
        validate_link "$URL"
        VALIDATE_EXIT=$?
        if [ "$VALIDATE_EXIT" -eq 0 ] || [ "$VALIDATE_EXIT" -eq 2 ]; then
            echo "$URL" >> "$VALIDATED_LIST"
        else
            echo "$URL" >> "$INVALID_LIST"
        fi
    done < "$FETCHED_LIST"

    [ -s "$VALIDATED_LIST" ] || return 1

    awk 'NF && !seen[$0]++' "$VALIDATED_LIST" > "${VALIDATED_LIST}.tmp"
    mv "${VALIDATED_LIST}.tmp" "$VALIDATED_LIST"
    cp "$VALIDATED_LIST" "$FETCHED_LIST"

    if [ -s "$INVALID_LIST" ]; then
        echo "⚠️  检查不通过的链接数：$(wc -l < "$INVALID_LIST")（已排除）"
    fi
    echo "✅ 有效链接数：$(wc -l < "$VALIDATED_LIST")"
    date +%s > "$LINK_CHECK_STAMP"

    CHECK_END=$(date +%s)
    CHECK_DURATION=$((CHECK_END - CHECK_START))
    echo "⏱️  链接检测耗时：$(human_seconds "$CHECK_DURATION")"
    echo "$CHECK_DURATION" > "$LINKS_DIR/check_duration.txt"
    return 0
}

# ---------- 主流程 ----------
. /app/.env 2>/dev/null || true
apply_defaults
reload_env

LAST_DATE=""
while true; do
    reload_env
    fetch_links || true

    LINK_SOURCE=""
    if check_fetched_links; then
        FINAL_BASE_URLS="$(cat "$LINKS_DIR/fetched-links.txt")"
        LINK_SOURCE="抓取链接"
        echo "✅ 使用校验通过的抓取链接"
    elif [ -n "${DOWNLOAD_URLS:-}" ]; then
        force_fetch_next_round
        FINAL_BASE_URLS="$DOWNLOAD_URLS"
        LINK_SOURCE=".env 配置"
        echo "⚠️  抓取链接不可用，回退使用 .env 中的 DOWNLOAD_URLS"
    else
        force_fetch_next_round
        echo "❌ 无可用下载链接"
        sleep 60
        continue
    fi

    FINAL_LIST="/tmp/urls.list"
    echo "$FINAL_BASE_URLS" | tr ',;' '\n' | tr -d '`' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'NF && !seen[$0]++' > "$FINAL_LIST"

    TOTAL="$(wc -l < "$FINAL_LIST")"
    if [ "$TOTAL" -lt 1 ]; then
        force_fetch_next_round
        echo "❌ 链接列表为空，60 秒后重试"
        sleep 60
        continue
    fi

    echo "✅ 本轮可用链接数：$TOTAL"

    TODAY="$(get_today)"
    if [ "$LAST_DATE" != "$TODAY" ]; then
        [ -f "$(data_file)" ] || init_stats
        validate_data_file || init_stats
        generate_show_stats
        echo ""
        echo "📅 日期切换：$TODAY（统计已自动重置）"
        LAST_DATE="$TODAY"
    fi

    if ! check_daily_limit; then
        echo ""
        echo "⚠️  单日流量已达上限（$(human_bytes "$MAX_DAILY_BYTES")）"
        echo "🛑 今日下载已暂停，明天自动恢复"
        sleep 60
        continue
    fi

    RUN_TIMES="$(rand_n "$RUN_TIMES_MAX")"
    ROUND_SMALL_DOWNLOAD=false
    ROUND_TOTAL_BYTES=0
    echo ""
    echo "🚀 开始新一轮下载任务（共 $RUN_TIMES 次）"

    for i in $(seq 1 "$RUN_TIMES"); do
        if [ "$TOTAL" -gt 1 ]; then
            TRY_COUNT=0
            while true; do
                URL="$(sed -n "$(rand_n "$TOTAL")p" "$FINAL_LIST")"
                [ "$URL" != "$LAST_URL" ] && break
                TRY_COUNT="$((TRY_COUNT + 1))"
                [ "$TRY_COUNT" -ge 5 ] && break
            done
        else
            URL="$(sed -n "1p" "$FINAL_LIST")"
        fi
        LAST_URL="$URL"

        echo ""
        echo "➤ [$i/$RUN_TIMES] 下载中..."
        printf '   URL: %s\n' "$URL"
        [ -n "$LINK_SOURCE" ] && printf '   来源: %s\n' "$LINK_SOURCE"

        SKIP_DOWNLOAD=false
        # GitHub Release 跳过大小检查（CDN 返回假 Content-Length）
        case "$URL" in
            *github.com*/releases/download/*)
                echo "   [下载前] ℹ️  GitHub Release 链接，跳过大小检查"
                ;;
            *)
                if [ "$FETCH_MIN_FILE_BYTES" -gt 0 ]; then
            echo "   [下载前] 🔍 正在检查文件大小..."
            set +e
            HEAD_SIZE="$(curl -IL --connect-timeout 5 --max-time 30 --fail -L \
                -A "$USER_AGENT" -w "\nHTTP_CODE=%{http_code}\n" "$URL" 2>&1 \
                | grep -i '^content-length:' | tail -n 1 | awk '{print $2}' | tr -d '\r')"
# set -e  # disabled for FPK native mode
            if is_uint "$HEAD_SIZE"; then
                if [ "$HEAD_SIZE" -lt "$FETCH_MIN_FILE_BYTES" ]; then
                    echo "   [下载前] ❌ 文件过小，跳过：$(human_bytes "$HEAD_SIZE") < $(human_bytes "$FETCH_MIN_FILE_BYTES")"
                    SKIP_DOWNLOAD=true
                else
                    echo "   [下载前] ✅ 文件大小达标：$(human_bytes "$HEAD_SIZE")"
                fi
            else
                echo "   [下载前] ⚠️  无法确认文件大小，继续下载"
            fi
        fi
        esac

        if [ "$SKIP_DOWNLOAD" = "true" ]; then
            continue
        fi

        RATE_OPT=""
        [ -n "$LIMIT_RATE" ] && [ "$LIMIT_RATE" != "0" ] && RATE_OPT="--limit-rate $LIMIT_RATE"

        METRICS_FILE="/tmp/curl_metrics_$$_$i.txt"
        echo "   ⬇️  开始下载..."
        set +e
        curl -L -o /dev/null -sS --fail \
            $RATE_OPT \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$MAX_TIME" \
            --retry "$RETRY" \
            --retry-delay "$RETRY_DELAY" \
            -A "$USER_AGENT" \
            -w "SIZE=%{size_download}\nTIME=%{time_total}\n" \
            "$URL" > "$METRICS_FILE"
        CURL_EXIT=$?
# set -e  # disabled for FPK native mode

        if [ "$CURL_EXIT" -ne 0 ]; then
            case "$CURL_EXIT" in
                28) MSG="连接超时" ;;
                7)  MSG="无法连接到服务器" ;;
                22) MSG="HTTP 返回错误" ;;
                56) MSG="数据传输失败" ;;
                35) MSG="SSL/TLS 握手失败" ;;
                18) MSG="下载未完成" ;;
                *)  MSG="未知网络错误（code $CURL_EXIT）" ;;
            esac
            echo ""
            echo "⚠️  下载失败：$MSG"
            echo "    URL: $URL"
            echo ""
        fi

        SIZE="$(grep '^SIZE=' "$METRICS_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2 | tr -d '\r\n')"
        TIME="$(grep '^TIME=' "$METRICS_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2 | cut -d. -f1 | tr -d '\r\n')"
        rm -f "$METRICS_FILE"
        SIZE="${SIZE:-0}"
        TIME="${TIME:-0}"
        is_uint "$SIZE" || SIZE=0
        is_uint "$TIME" || TIME=0

        if [ "$SIZE" -gt 0 ]; then
            echo "   ✅ 下载完成：$(human_bytes "$SIZE") / 耗时 ${TIME}s"
        fi

        [ "$SIZE" -gt 0 ] && update_stats "$SIZE" "$TIME"
        ROUND_TOTAL_BYTES=$((ROUND_TOTAL_BYTES + SIZE))

        if ! check_daily_limit; then
            echo "⚠️  单日流量已达到或超过上限，本轮提前结束"
            break
        fi
    done

    # 本轮总量低于阈值时，跳过休眠
    if [ "$ROUND_MIN_BYTES" -gt 0 ] && [ "$ROUND_TOTAL_BYTES" -lt "$ROUND_MIN_BYTES" ]; then
        echo ""
        echo "ℹ️  本轮下载总量 $(human_bytes "$ROUND_TOTAL_BYTES") < 阈值 $(human_bytes "$ROUND_MIN_BYTES")，跳过休眠"
        echo "ℹ️  立即开始下一轮..."
        echo ""
        continue
    fi

    echo ""
    [ -f "$(show_file)" ] || generate_show_stats
    cat "$(show_file)"

    SLEEP_TIME="$(calc_sleep_time)"
    WAKE_TIME="$(next_wake_time "$SLEEP_TIME")"

    echo ""
    if [ "$DYNAMIC_SLEEP" = "false" ]; then
        echo "😴 本轮结束，固定休眠 $(human_seconds "$SLEEP_TIME")（动态休眠已关闭）..."
    elif [ "$ROUND_SMALL_DOWNLOAD" = "true" ]; then
        echo "😴 本轮结束，固定休眠 $(human_seconds "$SLEEP_TIME")（动态休眠跳过）..."
    else
        echo "😴 本轮结束，随机休眠 $(human_seconds "$SLEEP_TIME")..."
    fi
    echo "⏰ 下次唤醒时间：$(date +%H:%M:%S) → $WAKE_TIME"
    echo ""

    sleep "$SLEEP_TIME"
done