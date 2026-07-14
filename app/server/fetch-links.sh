#!/usr/bin/env sh
# =========================================================
#  Traffic Keeper - 独立链接抓取脚本
#  Version : 2.9.2
#  更新：支持可选数据单位 K/M/G/T（如 1G, 500M, 10K）
#  配置说明：.env 中 FETCH_MIN_FILE_BYTES 支持 K/M/G/T 单位，0 表示不限制
# =========================================================
# set -e  # disabled for FPK native mode

# 加载环境变量配置（子进程无法继承父进程的 shell 变量）
. "${TK_ENV_FILE:-/app/.env}" 2>/dev/null || true

BASE_DIR="${TK_APP_DIR:-$(dirname "$0")}"
OUTPUT_FILE="${TK_DATA_DIR:-/app/data}/links/fetched-links.txt"
FETCH_MIN_FILE_BYTES="${FETCH_MIN_FILE_BYTES:-1G}"  # 默认1G，支持 K/M/G/T 单位

mkdir -p "${TK_DATA_DIR:-/app/data}/links"
TMP_OUTPUT="${TK_DATA_DIR:-/app/data}/.tmp-fetched-links_$$.txt"
> "$TMP_OUTPUT"
OUTPUT_FILE="${TK_DATA_DIR:-/app/data}/links/fetched-links.txt"

# 记录抓取开始时间
START_TIME=$(date +%s)

# ==================== 单位转换工具函数（和主脚本完全一致） ====================
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

# 1024进制字节转人类可读格式（和主脚本日志完全统一）
human_bytes() {
    VALUE="${1:-0}"
    is_uint "$VALUE" || VALUE=0
    for unit in TiB GiB MiB KiB B; do
        div=1
        case "$unit" in
            TiB) div=1099511627776 ;;
            GiB) div=1073741824 ;;
            MiB) div=1048576 ;;
            KiB) div=1024 ;;
            B)   div=1 ;;
        esac
        if [ "$VALUE" -ge "$div" ]; then
            echo "$(awk "BEGIN {printf \"%.2f\", $VALUE/$div}") $unit"
            return
        fi
    done
    echo "0 B"
}
# =============================================================================

# 尝试获取文件大小，返回：0=达标，1=过小，2=无法确认
remote_file_size_check() {
    URL="$1"
    MIN_VALUE="$(parse_size "$FETCH_MIN_FILE_BYTES")"  # 转成字节后再判断
    is_uint "$MIN_VALUE" || MIN_VALUE=0
    [ "$MIN_VALUE" -le 0 ] && return 0  # 0 表示不限制大小

    set +e
    HEAD_OUT="$(curl -IL --connect-timeout 5 --max-time 30 --fail -L \
        -w "\nHTTP_CODE=%{http_code}\n" "$URL" 2>&1)"
    CURL_EXIT=$?
    # set -e  # disabled for FPK native mode

    if [ "$CURL_EXIT" -eq 0 ]; then
        HTTP_CODE="$(echo "$HEAD_OUT" | grep HTTP_CODE | tail -n 1 | cut -d= -f2)"
        case "$HTTP_CODE" in
            2*|3*)
                REMOTE_SIZE="$(echo "$HEAD_OUT" | tr -d '\r' | awk 'tolower($1)=="content-length:" {print $2}' | tail -n 1)"
                if is_uint "$REMOTE_SIZE"; then
                    # 如果 Content-Length 极小（< 1KB）但阈值 >= 1MB，很可能是 CDN 假响应，跳过
                    if [ "$REMOTE_SIZE" -lt 1024 ] && [ "$MIN_VALUE" -ge 1048576 ]; then
                        :
                    elif [ "$REMOTE_SIZE" -ge "$MIN_VALUE" ]; then
                        echo "✅ 文件大小达标，已抓取：$(human_bytes "$REMOTE_SIZE") $URL"
                        return 0
                    else
                        echo "❌ 文件过小，未抓取：$(human_bytes "$REMOTE_SIZE") < $(human_bytes "$MIN_VALUE") $URL"
                        return 1
                    fi
                fi
                ;;
        esac
    fi

    set +e
    RANGE_OUT="$(curl -sS -L --range 0-0 --connect-timeout 5 --max-time 30 \
        --fail -L -D - -o /dev/null "$URL" 2>&1)"
    CURL_EXIT=$?
    # set -e  # disabled for FPK native mode

    if [ "$CURL_EXIT" -eq 0 ]; then
        REMOTE_SIZE="$(echo "$RANGE_OUT" | tr -d '\r' | awk 'tolower($1)=="content-range:" {split($0,a,"/"); print a[2]}' | tr -dc '0-9')"
        [ -n "$REMOTE_SIZE" ] || REMOTE_SIZE="$(echo "$RANGE_OUT" | tr -d '\r' | awk 'tolower($1)=="content-length:" {print $2}' | tail -n 1)"
        if is_uint "$REMOTE_SIZE"; then
            awk "BEGIN { exit ($REMOTE_SIZE >= $MIN_VALUE) ? 0 : 1 }" && {
                echo "✅ 文件大小达标，已抓取：$(human_bytes "$REMOTE_SIZE") $URL"
                return 0
            }
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
        echo "$URL" >> "$TMP_OUTPUT"
    fi
}

# ========== 从 GitHub API 抓取 ==========
echo "🔍 正在从 GitHub API 抓取 Release 资源..."

GITHUB_API="https://api.github.com"

REPOS_LIST="/tmp/tk_repos_$$.txt"
cat > "$REPOS_LIST" << 'REPOSEOF'
curl/curl
jqlang/jq
llvm/llvm-project
REPOSEOF

while IFS= read -r repo; do
    [ -z "$repo" ] && continue

    set +e
    RESP=$(curl -sL --connect-timeout 10 --max-time 30 --retry 2 "$GITHUB_API/repos/$repo/releases/latest" 2>/dev/null)
    CURL_RC=$?
    # set -e  # disabled for FPK native mode

    [ "$CURL_RC" -ne 0 ] && echo "⚠️  GitHub API 请求失败 ($repo): curl exit $CURL_RC" && continue
    [ -z "$RESP" ] && echo "⚠️  GitHub API 返回空 ($repo)" && continue
    echo "$RESP" | grep -q "browser_download_url" || { echo "ℹ️  $repo 无 browser_download_url"; continue; }

    # GitHub Release 文件通常较大，直接提取写入，不做 HEAD 大小检查（CDN 返回假 Content-Length）
    URL_COUNT=$(echo "$RESP" | grep "browser_download_url" | \
        grep -E "\.(tar\.gz|zip|tar\.xz|pkg|dmg|exe)" | \
        sed 's/.*"browser_download_url": "//;s/".*//' | tr -d '\r' | tee -a "$TMP_OUTPUT" | wc -l)
    echo "📦 $repo: 提取到 $URL_COUNT 个链接"
done < "$REPOS_LIST"
rm -f "$REPOS_LIST"

# ========== 从国内镜像站抓取 ==========
echo "🔍 正在从国内镜像站抓取资源..."

MIRRORS_LIST="/tmp/tk_mirrors_$$.txt"
cat > "$MIRRORS_LIST" << 'MIRRORSEOF'
https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/22.04/
https://releases.ubuntu.com/22.04/
MIRRORSEOF

while IFS= read -r base_url; do
    [ -z "$base_url" ] && continue

    base_url="$(echo "$base_url" | sed 's|/*$||')"

    set +e
    content=$(curl -sL --connect-timeout 10 --max-time 30 --max-redirs 2 "$base_url" 2>/dev/null)
    # set -e  # disabled for FPK native mode
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
            -e 's|/\{1,\}|/|g' \
            -e 's|\(https\?\):/|\1://|')"

        append_if_large_enough "$FULL_URL"
    done < "$FILES_LIST"

    rm -f "$FILES_LIST"
done < "$MIRRORS_LIST"
rm -f "$MIRRORS_LIST"

# ========== 清理并替换输出文件 ==========
sed -i '/^$/d' "$TMP_OUTPUT"
grep -E '^https?://' "$TMP_OUTPUT" > "${TMP_OUTPUT}.clean" 2>/dev/null || true
sort -u "${TMP_OUTPUT}.clean" -o "${TMP_OUTPUT}.clean"
COUNT="$(wc -l < "${TMP_OUTPUT}.clean")"

# 只有抓取到链接才替换原文件
if [ "$COUNT" -gt 0 ]; then
    cp "${TMP_OUTPUT}.clean" "$OUTPUT_FILE"
fi
rm -f "${TMP_OUTPUT}.clean" "$TMP_OUTPUT"
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# 格式化耗时
human_duration() {
    SECS="${1:-0}"
    is_uint "$SECS" || SECS=0
    if [ "$SECS" -ge 3600 ]; then
        printf "%dh%02dm%02ds" "$((SECS / 3600))" "$(((SECS % 3600) / 60))" "$((SECS % 60))"
    elif [ "$SECS" -ge 60 ]; then
        printf "%dm%02ds" "$((SECS / 60))" "$((SECS % 60))"
    else
        printf "%ds" "$SECS"
    fi
}

if [ "$COUNT" -eq 0 ]; then
    echo "⚠️  警告：未抓取到任何链接（耗时 $(human_duration "$DURATION")）"
else
    echo "✅ 抓取完成，共 $COUNT 条链接，耗时 $(human_duration "$DURATION")"
fi