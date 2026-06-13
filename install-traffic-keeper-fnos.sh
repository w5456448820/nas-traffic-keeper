#!/usr/bin/env bash
# =========================================================
#  Traffic Keeper - FnOS / 飞牛 NAS 一键安装脚本
#  Version : v2.6.8-fnos-fixed
#  Update  :
#   - 固定安装目录：/vol2/1000/Docker/traffic-keeper
#   - 修复 .env 多行变量与 Docker Compose env_file 冲突
#   - 修复 URL 反引号导致的命令执行问题
#   - 修复 curl 失败触发 set -e 直接退出的问题
#   - 固定 Alpine 版本并动态匹配软件源
#   - 优化链接抓取、校验、统计展示与飞牛 NAS 兼容性
# =========================================================
set -e

echo ""
echo "========================================"
echo "🚀 Traffic Keeper - 飞牛 NAS 一键安装"
echo "========================================"
echo ""

PROJECT_DIR="/vol2/1000/Docker/traffic-keeper"

COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ENV_FILE="$PROJECT_DIR/.env"
MAIN_SCRIPT="$PROJECT_DIR/traffic-keeper.sh"
FETCH_SCRIPT="$PROJECT_DIR/fetch-links.sh"
LINKS_DIR="$PROJECT_DIR/links"
CONTAINER_NAME="traffic-keeper"

mkdir -p "$PROJECT_DIR" "$LINKS_DIR"
cd "$PROJECT_DIR"

echo "📁 安装目录：$PROJECT_DIR"
echo ""

echo "✅ 生成配置文件 (.env)"
cat > "$ENV_FILE" <<'EOF'
# =========================================================
#  Traffic Keeper - 环境变量配置文件
#  仅存放可调参数（无脚本逻辑）
# =========================================================

# 下载限速（K/M/G），0 或留空表示不限速
LIMIT_RATE=5M

# 每轮任务最大休眠时间（秒）
SLEEP_MAX=900

# 每轮任务最小休眠时间（秒）
SLEEP_MIN=60

# 是否启用动态休眠（true / false）
DYNAMIC_SLEEP=true

# 每轮最多执行下载次数
RUN_TIMES_MAX=3

# 连接超时（秒）
CONNECT_TIMEOUT=15

# 单次下载最大时间（秒）
MAX_TIME=3000

# curl 重试次数
RETRY=5

# 重试间隔（秒）
RETRY_DELAY=5

# 链接抓取间隔（秒），默认 6 小时
FETCH_INTERVAL=21600

# User-Agent
USER_AGENT='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'

# 单日最大下载量（字节）：4000 GB
MAX_DAILY_BYTES=4294967296000

# 下载链接（多行或逗号分隔）
DOWNLOAD_URLS="
https://releases.ubuntu.com/22.04.5/ubuntu-22.04.5-desktop-amd64.iso
https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.tar.xz
http://updates-http.cdn-apple.com/2019WinterFCS/fullrestores/041-39257/32129B6C-292C-11E9-9E72-4511412B0A59/iPhone_4.7_12.1.4_16D57_Restore.ipsw
http://dldir1.qq.com/qqfile/qq/QQNT/Windows/QQ_9.9.15_240808_x64_01.exe
https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/22.04.5/ubuntu-22.04.5-desktop-amd64.iso
https://mirrors.aliyun.com/linux-kernel/v6.x/linux-6.6.tar.xz
https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/v20.12.2/node-v20.12.2-linux-x64.tar.xz
https://dldir1.qq.com/qqfile/qq/QQNT/Windows/QQ_9.9.15_240808_x64_01.exe
https://updates-http.cdn-apple.com/2019WinterFCS/fullrestores/041-39257/32129B6C-292C-11E9-9E72-4511412B0A59/iPhone_4.7_12.1.4_16D57_Restore.ipsw
https://mirrors.aliyun.com/ubuntu-releases/22.04.5/ubuntu-22.04.5-desktop-amd64.iso
"
EOF

echo "✅ 生成主运行脚本 (traffic-keeper.sh)"
cat > "$MAIN_SCRIPT" <<'EOF'
#!/usr/bin/env sh
set -e

echo "🐳 Traffic Keeper 容器启动中..."

# ---------- Alpine 软件源修复 ----------
ALPINE_VER="$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || echo 3.23)"
rm -f /etc/apk/repositories
echo "https://mirrors.aliyun.com/alpine/v${ALPINE_VER}/main" > /etc/apk/repositories
echo "https://mirrors.aliyun.com/alpine/v${ALPINE_VER}/community" >> /etc/apk/repositories

apk update
apk add --no-cache curl coreutils

DATA_DIR="/app/data"
DISPLAY_DIR="/app/流量统计"
mkdir -p "$DATA_DIR" "$DISPLAY_DIR" /app/links

LAST_URL=""
FETCH_STAMP="/app/links/.last-fetch"

get_today() { date +%F; }
data_file() { echo "$DATA_DIR/stats_data_$(get_today).log"; }
show_file() { echo "$DISPLAY_DIR/stats_show_$(get_today).log"; }

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

human_bytes() {
  VALUE="${1:-0}"
  is_uint "$VALUE" || VALUE=0
  numfmt --to=iec-i --suffix=B "$VALUE"
}

human_seconds() {
  VALUE="${1:-0}"
  is_uint "$VALUE" || VALUE=0
  printf "%02dmin %02ds" "$((VALUE / 60))" "$((VALUE % 60))"
}

next_wake_time() {
  date -d "+$1 seconds" +"%H:%M:%S"
}

read_var() {
  FILE="$(data_file)"
  [ -f "$FILE" ] || { echo ""; return 0; }
  grep "^$1=" "$FILE" 2>/dev/null | cut -d= -f2- | tail -n 1 || true
}

apply_defaults() {
  LIMIT_RATE="${LIMIT_RATE:-5M}"
  USER_AGENT="${USER_AGENT:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36}"
  DYNAMIC_SLEEP="${DYNAMIC_SLEEP:-true}"
  [ "$DYNAMIC_SLEEP" = "false" ] || DYNAMIC_SLEEP=true

  is_uint "${SLEEP_MIN:-}" || SLEEP_MIN=60
  is_uint "${SLEEP_MAX:-}" || SLEEP_MAX=900
  is_uint "${RUN_TIMES_MAX:-}" || RUN_TIMES_MAX=3
  is_uint "${CONNECT_TIMEOUT:-}" || CONNECT_TIMEOUT=15
  is_uint "${MAX_TIME:-}" || MAX_TIME=3000
  is_uint "${RETRY:-}" || RETRY=5
  is_uint "${RETRY_DELAY:-}" || RETRY_DELAY=5
  is_uint "${FETCH_INTERVAL:-}" || FETCH_INTERVAL=21600
  is_uint "${MAX_DAILY_BYTES:-}" || MAX_DAILY_BYTES=0

  [ "$SLEEP_MIN" -lt 1 ] && SLEEP_MIN=60
  [ "$SLEEP_MAX" -lt 1 ] && SLEEP_MAX=900
  [ "$RUN_TIMES_MAX" -lt 1 ] && RUN_TIMES_MAX=1
  [ "$CONNECT_TIMEOUT" -lt 1 ] && CONNECT_TIMEOUT=15
  [ "$MAX_TIME" -lt 1 ] && MAX_TIME=3000
  [ "$RETRY" -lt 0 ] && RETRY=5
  [ "$RETRY_DELAY" -lt 0 ] && RETRY_DELAY=5
  [ "$FETCH_INTERVAL" -lt 60 ] && FETCH_INTERVAL=60

  return 0
}

reload_env() {
  echo ""
  echo "🔄 重新加载配置文件..."

  if ! . /app/.env 2>/tmp/env_error.log; then
    echo "⚠️ 配置文件有语法错误，保持当前配置继续运行"
    cat /tmp/env_error.log 2>/dev/null || true
    apply_defaults
    return 1
  fi

  apply_defaults
  echo "✅ 配置已更新"
}

rand_n() {
  MAX="${1:-1}"
  is_uint "$MAX" || MAX=1
  [ "$MAX" -lt 1 ] && MAX=1
  NUM="$(od -An -N2 -tu2 /dev/urandom | awk '{print $1}')"
  [ -z "$NUM" ] && NUM="$(date +%s%N | cut -c9-13)"
  echo "$((NUM % MAX + 1))"
}

calc_sleep_time() {
  [ "$DYNAMIC_SLEEP" = "false" ] && { echo "$SLEEP_MIN"; return; }

  MIN="${SLEEP_MIN:-60}"
  MAX="${SLEEP_MAX:-900}"
  is_uint "$MIN" || MIN=60
  is_uint "$MAX" || MAX=900

  [ "$MIN" -ge "$MAX" ] && { echo "$MIN"; return; }

  DIFF="$((MAX - MIN + 1))"
  NUM="$(od -An -N2 -tu2 /dev/urandom | awk '{print $1}')"
  [ -z "$NUM" ] && NUM="$(date +%s%N | cut -c9-13)"
  OFFSET="$((NUM % DIFF))"
  echo "$((MIN + OFFSET))"
}

check_daily_limit() {
  MAX_BYTES="${MAX_DAILY_BYTES:-0}"
  is_uint "$MAX_BYTES" || MAX_BYTES=0
  [ "$MAX_BYTES" -le 0 ] && return 0
  CURRENT="$(read_var SIZE_BYTES)"
  CURRENT="${CURRENT:-0}"
  is_uint "$CURRENT" || CURRENT=0
  [ "$CURRENT" -ge "$MAX_BYTES" ] && return 1 || return 0
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
  FETCHED_LIST="/app/links/fetched-links.txt"
  [ -s "$FETCHED_LIST" ] || return 0
  [ -f "$FETCH_STAMP" ] || return 0

  NOW="$(date +%s)"
  LAST="$(stat -c %Y "$FETCH_STAMP" 2>/dev/null || echo 0)"
  AGE="$((NOW - LAST))"
  [ "$AGE" -ge "$FETCH_INTERVAL" ]
}

force_fetch_next_round() {
  rm -f "$FETCH_STAMP"
  echo "ℹ️ 已标记下一轮重新抓取链接"
}

fetch_links() {
  if ! should_fetch_links; then
    echo "ℹ️ 链接抓取未到间隔，跳过本轮抓取"
    return 0
  fi

  echo ""
  echo "🔄 正在重新抓取可用下载链接..."

  if [ -x /app/fetch-links.sh ]; then
    if sh /app/fetch-links.sh && [ -s /app/links/fetched-links.txt ]; then
      date +%s > "$FETCH_STAMP"
      return 0
    fi

    echo "⚠️ 链接抓取失败或未抓取到链接，本轮将尝试使用已有链接或 .env 链接"
    force_fetch_next_round
    return 1
  else
    echo "⚠️ 未找到 fetch-links.sh，跳过抓取"
    force_fetch_next_round
    return 1
  fi
}

validate_link() {
  URL="$1"

  set +e
  HEAD_OUT="$(curl -IL --connect-timeout 5 --max-time 15 \
    -A "$USER_AGENT" \
    -w "\nHTTP_CODE=%{http_code}\n" \
    "$URL" 2>&1)"
  CURL_EXIT=$?
  set -e

  HTTP_CODE="$(echo "$HEAD_OUT" | grep HTTP_CODE | tail -n 1 | cut -d= -f2)"

  if [ "$CURL_EXIT" -eq 0 ]; then
    case "$HTTP_CODE" in
      2*|3*)
        echo "✅ 可用链接：$URL"
        return 0
        ;;
    esac
  fi

  set +e
  curl -L --range 0-0 --connect-timeout 5 --max-time 15 \
    -A "$USER_AGENT" \
    -o /dev/null \
    "$URL" >/dev/null 2>&1
  CURL_EXIT=$?
  set -e

  if [ "$CURL_EXIT" -eq 0 ]; then
    echo "✅ 可用链接：$URL"
    return 0
  fi

  case "$CURL_EXIT" in
    28) echo "❌ 连接超时：$URL" ;;
    7)  echo "❌ DNS 或连接失败：$URL" ;;
    *)  echo "❌ 链接不可用(code $CURL_EXIT, HTTP ${HTTP_CODE:-unknown})：$URL" ;;
  esac
  return 1
}

check_fetched_links() {
  FETCHED_LIST="/app/links/fetched-links.txt"
  VALIDATED_LIST="/tmp/validated_urls.list"

  [ -f "$FETCHED_LIST" ] || return 1
  [ -s "$FETCHED_LIST" ] || return 1

  > "$VALIDATED_LIST"

  echo "🔍 正在逐条检查抓取到的链接..."

  while IFS= read -r URL; do
    [ -n "$URL" ] || continue
    validate_link "$URL" && echo "$URL" >> "$VALIDATED_LIST"
  done < "$FETCHED_LIST"

  [ -s "$VALIDATED_LIST" ] || return 1

  echo "✅ 有效链接数：$(wc -l < "$VALIDATED_LIST")"
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

  if check_fetched_links; then
    FINAL_BASE_URLS="$(cat /tmp/validated_urls.list)"
    echo "✅ 使用校验通过的抓取链接"
  elif [ -n "${DOWNLOAD_URLS:-}" ]; then
    force_fetch_next_round
    FINAL_BASE_URLS="$DOWNLOAD_URLS"
    echo "⚠️ 抓取链接不可用，回退使用 .env 中的 DOWNLOAD_URLS，下一轮将重新抓取"
  else
    force_fetch_next_round
    echo "❌ 无可用下载链接"
    sleep 60
    continue
  fi

  FINAL_LIST="/tmp/urls.list"
  echo "$FINAL_BASE_URLS" | tr ',;' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'NF && !seen[$0]++' > "$FINAL_LIST"

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

    RATE_OPT=""
    [ -n "$LIMIT_RATE" ] && [ "$LIMIT_RATE" != "0" ] && RATE_OPT="--limit-rate $LIMIT_RATE"

    set +e
    OUT="$(curl -L -o /dev/null -# \
      --fail \
      $RATE_OPT \
      --connect-timeout "$CONNECT_TIMEOUT" \
      --max-time "$MAX_TIME" \
      --retry "$RETRY" \
      --retry-delay "$RETRY_DELAY" \
      -A "$USER_AGENT" \
      -w "\nSIZE=%{size_download}\nTIME=%{time_total}\n" "$URL" 2>&1)"
    CURL_EXIT=$?
    set -e

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
      echo "⚠️  下载失败：$MSG（curl code $CURL_EXIT）"
      echo "    URL: $URL"
      echo ""
    fi

    SIZE="$(echo "$OUT" | grep '^SIZE=' | tail -n 1 | cut -d= -f2 | tr -d '\r\n')"
    TIME="$(echo "$OUT" | grep '^TIME=' | tail -n 1 | cut -d= -f2 | cut -d. -f1 | tr -d '\r\n')"
    SIZE="${SIZE:-0}"
    TIME="${TIME:-0}"
    is_uint "$SIZE" || SIZE=0
    is_uint "$TIME" || TIME=0

    [ "$SIZE" -gt 0 ] && update_stats "$SIZE" "$TIME"

    if ! check_daily_limit; then
      echo "⚠️ 单日流量已达到或超过上限，本轮提前结束"
      break
    fi
  done

  echo ""
  [ -f "$(show_file)" ] || generate_show_stats
  cat "$(show_file)"

  SLEEP_TIME="$(calc_sleep_time)"
  WAKE_TIME="$(next_wake_time "$SLEEP_TIME")"

  echo ""
  echo "😴 本轮结束，随机休眠 $(human_seconds "$SLEEP_TIME")..."
  echo "⏰ 下次唤醒时间：$(date +%H:%M:%S) → $WAKE_TIME"
  echo ""

  sleep "$SLEEP_TIME"
done
EOF

chmod +x "$MAIN_SCRIPT"

echo "✅ 生成链接抓取脚本 (fetch-links.sh)"
cat > "$FETCH_SCRIPT" <<'EOF'
#!/usr/bin/env sh
# =========================================================
#  Traffic Keeper - 独立链接抓取脚本
#  输出：./links/fetched-links.txt
# =========================================================

set -e

BASE_DIR="$(dirname "$0")"
OUTPUT_FILE="$BASE_DIR/links/fetched-links.txt"

mkdir -p "$BASE_DIR/links"
> "$OUTPUT_FILE"

echo "🔍 正在从 GitHub API 抓取 Release 资源..."

GITHUB_API="https://api.github.com"

echo "curl/curl
jqlang/jq
nodejs/node" | while IFS= read -r repo; do
  [ -z "$repo" ] && continue

  RESP=$(curl -sL --connect-timeout 10 --max-time 20 --retry 2 "$GITHUB_API/repos/$repo/releases/latest" || true)
  echo "$RESP" | grep -q "browser_download_url" || continue

  echo "$RESP" | \
  grep "browser_download_url" | \
  grep -E "\.(tar\.gz|zip|tar\.xz|pkg|dmg|exe)" | \
  cut -d '"' -f 4 >> "$OUTPUT_FILE"
done

echo "🔍 正在从国内镜像站抓取资源..."

echo "https://mirrors.tuna.tsinghua.edu.cn/apache/httpd/
https://mirrors.aliyun.com/ubuntu-releases/22.04/" | while IFS= read -r base_url; do
  [ -z "$base_url" ] && continue

  content=$(curl -sL --connect-timeout 10 --max-time 20 --max-redirs 2 "$base_url" || true)
  [ -n "$content" ] || continue

  ORIGIN="$(echo "$base_url" | sed -E 's#(https?://[^/]+).*#\1#')"
  BASE_PATH="$(echo "$base_url" | sed -E 's#(https?://[^/]+/.*)/?$#\1/#')"

  echo "$content" | grep -oE 'href="[^"]+\.(iso|tar\.gz|zip|xz|exe|pkg)"' | \
  sed 's/href="//;s/"//' | \
  while IFS= read -r file; do
    file="$(echo "$file" | sed 's|^\./||')"

    case "$file" in
      http*) FULL_URL="$file" ;;
      //*)  FULL_URL="https:$file" ;;
      /*)   FULL_URL="$ORIGIN$file" ;;
      ../*) FULL_URL="$BASE_PATH$file" ;;
      *)    FULL_URL="$base_url$file" ;;
    esac

    FULL_URL="$(echo "$FULL_URL" | sed \
      -e 's|/\./|/|g' \
      -e 's|https:/|https://|' \
      -e 's|http:/|http://|')"

    echo "$FULL_URL"
  done >> "$OUTPUT_FILE"
done

sed -i '/^$/d' "$OUTPUT_FILE"
sort -u "$OUTPUT_FILE" -o "$OUTPUT_FILE"

COUNT="$(wc -l < "$OUTPUT_FILE")"
if [ "$COUNT" -eq 0 ]; then
  echo "⚠️ 警告：未抓取到任何链接"
else
  echo "✅ 抓取完成，共 $COUNT 条链接"
fi
EOF

chmod +x "$FETCH_SCRIPT"

echo ""
echo "✅ 生成 docker-compose.yml"
cat > "$COMPOSE_FILE" <<'EOF'
services:
  traffic-keeper:
    image: alpine:3.23
    container_name: traffic-keeper
    restart: always
    working_dir: /app
    volumes:
      - .:/app
      - ./data:/app/data
      - ./流量统计:/app/流量统计
      - /etc/localtime:/etc/localtime:ro
    logging:
      driver: json-file
      options:
        max-size: 2m
        max-file: 3
    tmpfs:
      - /tmp
    command: ["/bin/sh", "/app/traffic-keeper.sh"]
EOF

echo ""
echo "🐳 正在启动 Docker 容器..."

if ! command -v docker >/dev/null 2>&1; then
  echo "❌ 未检测到 docker，请先在飞牛 NAS 应用中心安装 Docker"
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker-compose"
else
  echo "❌ 未检测到 Docker Compose，请确认 Docker 套件安装完整"
  exit 1
fi

if docker ps -aq -f name="^$CONTAINER_NAME$" | grep -q .; then
  echo "🗑️ 清理旧容器"
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

$DOCKER_COMPOSE up -d

echo ""
echo "🎉 安装完成！"
echo "----------------------------------------"
echo "📁 项目目录：$PROJECT_DIR"
echo "📄 查看日志：docker logs -f traffic-keeper"
echo "🛑 停止服务：cd $PROJECT_DIR && $DOCKER_COMPOSE down"
echo "========================================"
