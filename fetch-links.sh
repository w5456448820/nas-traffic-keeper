#!/usr/bin/env sh
# =========================================================
#  Traffic Keeper - 独立链接抓取脚本
#  Version : 2.7.1
#  输出：./links/fetched-links.txt
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

# 尝试获取文件大小，返回：0=达标，1=过小，2=无法确认
remote_file_size_check() {
    URL="$1"
    MIN_VALUE="$FETCH_MIN_FILE_BYTES"
    is_uint "$MIN_VALUE" || MIN_VALUE=1073741824
    [ "$MIN_VALUE" -le 0 ] && return 0

    set +e
    HEAD_OUT="$(curl -IL --connect-timeout 10 --max-time 30 --fail -L \
        -w "\nHTTP_CODE=%{http_code}\n" "$URL" 2>&1)"
    CURL_EXIT=$?
    set -e

    if [ "$CURL_EXIT" -eq 0 ]; then
        HTTP_CODE="$(echo "$HEAD_OUT" | grep HTTP_CODE | tail -n 1 | cut -d= -f2)"
        case "$HTTP_CODE" in
            2*|3*)
                REMOTE_SIZE="$(echo "$HEAD_OUT" | tr -d '\r' | awk 'tolower($1)=="content-length:" {print $2}' | tail -n 1)"
                if is_uint "$REMOTE_SIZE"; then
                    if [ "$REMOTE_SIZE" -ge "$MIN_VALUE" ]; then
                        echo "✅ 文件大小达标，已抓取：$(human_bytes "$REMOTE_SIZE") $URL"
                        return 0
                    fi
                    echo "❌ 文件过小，未抓取：$(human_bytes "$REMOTE_SIZE") < $(human_bytes "$MIN_VALUE") $URL"
                    return 1
                fi
                ;;
        esac
    fi

    set +e
    RANGE_OUT="$(curl -sS -L --range 0-0 --connect-timeout 10 --max-time 30 \
        --fail -L -D - -o /dev/null "$URL" 2>&1)"
    CURL_EXIT=$?
    set -e

    if [ "$CURL_EXIT" -eq 0 ]; then
        REMOTE_SIZE="$(echo "$RANGE_OUT" | tr -d '\r' | awk 'tolower($1)=="content-range:" {split($0,a,"/"); print a[2]}' | tr -dc '0-9')"
        [ -n "$REMOTE_SIZE" ] || REMOTE_SIZE="$(echo "$RANGE_OUT" | tr -d '\r' | awk 'tolower($1)=="content-length:" {print $2}' | tail -n 1)"
        if is_uint "$REMOTE_SIZE"; then
            if [ "$REMOTE_SIZE" -ge "$MIN_VALUE" ]; then
                echo "✅ 文件大小达标，已抓取：$(human_bytes "$REMOTE_SIZE") $URL"
                return 0
            fi
            echo "❌ 文件过小，未抓取：$(human_bytes "$REMOTE_SIZE") < $(human_bytes "$MIN_VALUE") $URL"
            return 1
        fi
    fi

    echo "⚠️  无法确认文件大小，保留到下载时判断：$URL"
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

# ========== 从 GitHub API 抓取 ==========
echo "🔍 正在从 GitHub API 抓取 Release 资源..."

GITHUB_API="https://api.github.com"

REPOS_LIST="/tmp/tk_repos_$$.txt"
cat > "$REPOS_LIST" << 'REPOSEOF'
curl/curl
jqlang/jq
nodejs/node
REPOSEOF

while IFS= read -r repo; do
    [ -z "$repo" ] && continue

    set +e
    RESP=$(curl -sL --connect-timeout 10 --max-time 30 --retry 2 "$GITHUB_API/repos/$repo/releases/latest" 2>/dev/null)
    set -e

    echo "$RESP" | grep -q "browser_download_url" || continue

    URLS_LIST="/tmp/tk_urls_$$.txt"
    echo "$RESP" | grep "browser_download_url" | \
        grep -E "\.(tar\.gz|zip|tar\.xz|pkg|dmg|exe)" | \
        cut -d '"' -f 4 | tr -d '\r' > "$URLS_LIST"

    while IFS= read -r URL; do
        append_if_large_enough "$URL"
    done < "$URLS_LIST"

    rm -f "$URLS_LIST"
done < "$REPOS_LIST"
rm -f "$REPOS_LIST"

# ========== 从国内镜像站抓取 ==========
echo "🔍 正在从国内镜像站抓取资源..."

MIRRORS_LIST="/tmp/tk_mirrors_$$.txt"
cat > "$MIRRORS_LIST" << 'MIRRORSEOF'
https://mirrors.tuna.tsinghua.edu.cn/apache/httpd/
https://mirrors.aliyun.com/ubuntu-releases/22.04/
https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/22.04/
https://mirrors.aliyun.com/linux-kernel/v6.x/
https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/v20.12.2/
MIRRORSEOF

while IFS= read -r base_url; do
    [ -z "$base_url" ] && continue

    base_url="$(echo "$base_url" | sed 's|/*$||')"

    set +e
    content=$(curl -sL --connect-timeout 10 --max-time 30 --max-redirs 2 "$base_url" 2>/dev/null)
    set -e
    [ -n "$content" ] || continue

    ORIGIN="$(echo "$base_url" | sed -E 's#(https?://[^/]+).*#\1#')"
    BASE_PATH="$base_url/"

    FILES_LIST="/tmp/tk_files_$$.txt"
    echo "$content" | grep -oE 'href="[^"]+\.(iso|tar\.gz|zip|xz|exe|pkg)"' | \
        sed 's/href="//;s/"//' | tr -d '\r' > "$FILES_LIST"

    while IFS= read -r file; do
        file="$(echo "$file" | sed 's|^\./||')"

        case "$file" in
            http*) FULL_URL="$file" ;;
            //*)  FULL_URL="https:$file" ;;
            /*)   FULL_URL="${ORIGIN}${file}" ;;
            ../*) FULL_URL="${BASE_PATH}${file}" ;;
            *)    FULL_URL="${base_url}/${file}" ;;
        esac

        FULL_URL="$(echo "$FULL_URL" | sed \
            -e 's|/\./|/|g' \
            -e 's|://|://|g' \
            -e 's|/\+|/|g' \
            -e 's|\(https\?\):/\|\1://|')"

        append_if_large_enough "$FULL_URL"
    done < "$FILES_LIST"

    rm -f "$FILES_LIST"
done < "$MIRRORS_LIST"
rm -f "$MIRRORS_LIST"

# ========== 清理输出文件 ==========
sed -i '/^$/d' "$OUTPUT_FILE"
grep -E '^https?://' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" 2>/dev/null || true
mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
sort -u "$OUTPUT_FILE" -o "$OUTPUT_FILE"

COUNT="$(wc -l < "$OUTPUT_FILE")"
if [ "$COUNT" -eq 0 ]; then
    echo "⚠️  警告：未抓取到任何链接"
else
    echo "✅ 抓取完成，共 $COUNT 条链接"
fi
