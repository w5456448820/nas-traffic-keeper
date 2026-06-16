#!/usr/bin/env sh
# =========================================================
#  Traffic Keeper - 独立链接抓取脚本
#  输出：./links/fetched-links.txt
#  逻辑：
#    1. 能确认大小的，达标才抓取
#    2. 无法确认大小的，保留到下载时判断
# =========================================================

set -e

BASE_DIR="$(dirname "$0")"
OUTPUT_FILE="$BASE_DIR/links/fetched-links.txt"
FETCH_MIN_FILE_BYTES=${FETCH_MIN_FILE_BYTES:-1073741824}

mkdir -p "$BASE_DIR/links"
> "$OUTPUT_FILE"

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

human_bytes() {
  VALUE="${1:-0}"
  is_uint "$VALUE" || VALUE=0
  numfmt --to=iec-i --suffix=B "$VALUE" 2>/dev/null || echo "${VALUE}B"
}

extract_content_length() {
  echo "$1" | tr -d '\r' | awk 'tolower($1)=="content-length:" {size=$2} END{print size}'
}

extract_content_range_total() {
  echo "$1" | tr -d '\r' | awk 'tolower($1)=="content-range:" {split($0,a,"/"); size=a[2]; gsub(/[^0-9].*/, "", size)} END{print size}'
}

# 尝试获取文件大小
# 返回：0=达标，1=过小，2=无法确认
remote_file_size_check() {
  URL="$1"
  MIN_VALUE="$FETCH_MIN_FILE_BYTES"
  is_uint "$MIN_VALUE" || MIN_VALUE=1073741824
  [ "$MIN_VALUE" -le 0 ] && return 0

  # 尝试 HEAD 请求
  set +e
  HEAD_OUT="$(curl -IL --connect-timeout 5 --max-time 15 \
    -w "\nHTTP_CODE=%{http_code}\n" \
    "$URL" 2>&1)"
  CURL_EXIT=$?
  set -e

  if [ "$CURL_EXIT" -eq 0 ]; then
    HTTP_CODE="$(echo "$HEAD_OUT" | grep HTTP_CODE | tail -n 1 | cut -d= -f2)"
    case "$HTTP_CODE" in
      2*|3*)
        REMOTE_SIZE="$(extract_content_length "$HEAD_OUT")"
        if is_uint "$REMOTE_SIZE"; then
          if [ "$REMOTE_SIZE" -ge "$MIN_VALUE" ]; then
            echo "✅ 文件大小达标，已抓取：$(human_bytes "$REMOTE_SIZE") ≥ $(human_bytes "$MIN_VALUE") $URL"
            return 0
          fi
          echo "❌ 文件过小，未抓取：$(human_bytes "$REMOTE_SIZE") < $(human_bytes "$MIN_VALUE") $URL"
          return 1
        fi
        ;;
    esac
  fi

  # 尝试 Range 请求
  set +e
  RANGE_OUT="$(curl -sS -L --range 0-0 --connect-timeout 5 --max-time 15 \
    -D - \
    -o /dev/null \
    "$URL" 2>&1)"
  CURL_EXIT=$?
  set -e

  if [ "$CURL_EXIT" -eq 0 ]; then
    REMOTE_SIZE="$(extract_content_range_total "$RANGE_OUT")"
    [ -n "$REMOTE_SIZE" ] || REMOTE_SIZE="$(extract_content_length "$RANGE_OUT")"
    if is_uint "$REMOTE_SIZE"; then
      if [ "$REMOTE_SIZE" -ge "$MIN_VALUE" ]; then
        echo "✅ 文件大小达标，已抓取：$(human_bytes "$REMOTE_SIZE") ≥ $(human_bytes "$MIN_VALUE") $URL"
        return 0
      fi
      echo "❌ 文件过小，未抓取：$(human_bytes "$REMOTE_SIZE") < $(human_bytes "$MIN_VALUE") $URL"
      return 1
    fi
  fi

  # 无法确认大小，保留到下载时判断
  echo "⚠️ 无法确认文件大小，保留到下载时判断：$URL"
  return 2
}

append_if_large_enough() {
  URL="$1"
  [ -n "$URL" ] || return 0
  remote_file_size_check "$URL"
  RESULT=$?
  if [ "$RESULT" -eq 0 ] || [ "$RESULT" -eq 2 ]; then
    echo "$URL" >> "$OUTPUT_FILE"
  fi
}

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
  cut -d '"' -f 4 | \
  while IFS= read -r URL; do
    append_if_large_enough "$URL"
  done
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

    append_if_large_enough "$FULL_URL"
  done
done

sed -i '/^$/d' "$OUTPUT_FILE"
grep -E '^https?://' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" || true
mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
sort -u "$OUTPUT_FILE" -o "$OUTPUT_FILE"

COUNT="$(wc -l < "$OUTPUT_FILE")"
if [ "$COUNT" -eq 0 ]; then
  echo "⚠️ 警告：未抓取到任何链接"
else
  echo "✅ 抓取完成，共 $COUNT 条链接"
fi
