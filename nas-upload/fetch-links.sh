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
grep -E '^https?://' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" || true
mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
sort -u "$OUTPUT_FILE" -o "$OUTPUT_FILE"

COUNT="$(wc -l < "$OUTPUT_FILE")"
if [ "$COUNT" -eq 0 ]; then
  echo "⚠️ 警告：未抓取到任何链接"
else
  echo "✅ 抓取完成，共 $COUNT 条链接"
fi
