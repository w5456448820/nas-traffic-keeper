#!/usr/bin/env bash
# =========================================================
#  Traffic Keeper - FnOS / 飞牛 NAS 一键安装脚本
#  Version : 2.8.0
#  更新内容：
#    - 统一所有模块版本号为 2.8.0
#    - 修复 Web 界面配置保存失败（quoted_keys 变量未定义）
#    - 修复 fetch-links.sh 子进程环境变量继承问题
#    - 修复 fetch-links.sh sed BRE 语法不兼容 busybox
#    - 修复 .env 配置项的单位问题（GB vs 字节）
#    - 增强配置检查逻辑
#    - 优化错误处理和用户提示
# =========================================================
set -e

echo ""
echo "========================================"
echo "🚀 Traffic Keeper - 飞牛 NAS 一键安装"
echo "   （含 Web 管理界面：端口 8080）"
echo "========================================"
echo ""

# 脚本所在目录 = 部署目标目录（两者相同则跳过复制）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
CONTAINER_NAME="traffic-keeper"

mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

echo "📁 项目目录：$PROJECT_DIR"
echo ""

# ============ 1. 确保所有脚本有可执行权限 ============
echo "✅ 配置脚本权限..."
for f in traffic-keeper.sh fetch-links.sh entrypoint.sh install-traffic-keeper-fnos.sh; do
    if [ -f "$PROJECT_DIR/$f" ]; then
        chmod +x "$PROJECT_DIR/$f"
    fi
done
# webserver.py 在容器内由 python 解释执行，宿主端无需 x 权限
# 但容器内会通过 volume 挂载，这里给个温和的 chmod 以避免挂载权限问题
[ -f "$PROJECT_DIR/webserver.py" ] && chmod +x "$PROJECT_DIR/webserver.py" 2>/dev/null || true

# ============ 2. 检查必需文件，缺失则从 GitHub 自动下载 ============
echo ""
echo "✅ 检查必需文件..."
MISSING=""
for f in traffic-keeper.sh fetch-links.sh webserver.py entrypoint.sh docker-compose.yml; do
    if [ ! -f "$PROJECT_DIR/$f" ]; then
        MISSING="$MISSING $f"
    fi
done
if [ -n "$MISSING" ]; then
    echo "⚠️  检测到缺失文件：$MISSING"
    echo "   正在从 GitHub 自动下载缺失文件..."
    echo "   （如无法访问 GitHub，请手动从 https://github.com/w5456448820/nas-traffic-keeper 下载）"
    TMP_DIR="$(mktemp -d 2>/dev/null || echo "/tmp/tk-auto-$(date +%s)")"
    mkdir -p "$TMP_DIR"
    BASE_URL="https://raw.githubusercontent.com/w5456448820/nas-traffic-keeper/main"
    DL_OK=true
    for f in traffic-keeper.sh fetch-links.sh webserver.py entrypoint.sh docker-compose.yml README.md; do
        if [ ! -f "$PROJECT_DIR/$f" ]; then
            echo "   ↓ 正在下载 $f ..."
            if curl -fsSL --connect-timeout 10 --max-time 30 -o "$TMP_DIR/$f" "$BASE_URL/$f" 2>/dev/null; then
                cp "$TMP_DIR/$f" "$PROJECT_DIR/$f"
                [ "${f##*.}" = "sh" ] && chmod +x "$PROJECT_DIR/$f"
            else
                echo "   ❌ 下载 $f 失败（请检查网络或手动克隆）"
                DL_OK=false
            fi
        fi
    done
    rm -rf "$TMP_DIR"
    if [ "$DL_OK" = false ]; then
        echo ""
        echo "⚠️  部分文件下载失败。请手动克隆仓库："
        echo "   cd $PROJECT_DIR && git clone https://github.com/w5456448820/nas-traffic-keeper.git ."
        exit 1
    fi
    echo "   自动下载完成 ✓"
else
    echo "   全部文件就绪 ✓"
fi

# ============ 3. 生成 .env（如缺失，或缺少关键字段时补齐）===========
echo ""
echo "✅ 检查配置文件..."

ENV_FILE="$PROJECT_DIR/.env"
need_write_env=false

# 检查旧配置中的字节单位问题
check_byte_units() {
    if [ -f "$ENV_FILE" ]; then
        local warnings=()
        
        # 检查可能的字节单位配置
        for field in FETCH_MIN_FILE_BYTES MAX_DAILY_BYTES ROUND_MIN_BYTES; do
            if grep -qE "^${field}=" "$ENV_FILE" 2>/dev/null; then
                local value=$(grep -E "^${field}=" "$ENV_FILE" | cut -d= -f2 | tr -d '"' | tr -d "'")
                # 如果值大于 1000 且不是明显的 GB 值（如 1, 2, 200），可能是字节单位
                if [ "$value" -gt 1000 ] 2>/dev/null && [ "$value" -ne 1 ] && [ "$value" -ne 2 ] && [ "$value" -ne 200 ]; then
                    warnings+=("${field}=${value} 可能使用了字节单位，应为 GB 单位")
                fi
            fi
        done
        
        if [ ${#warnings[@]} -gt 0 ]; then
            echo "   ⚠️  检测到可能的配置单位问题："
            for warning in "${warnings[@]}"; do
                echo "      - $warning"
            done
            echo "      新版本要求这些字段使用 GB 单位（如 1 表示 1GB）"
            echo "      将在生成新配置时自动修复"
            need_write_env=true
        fi
    fi
}

if [ ! -f "$ENV_FILE" ]; then
    echo "   未检测到 .env，将使用默认配置生成"
    need_write_env=true
else
    # 检查关键配置项是否存在
    for key in LIMIT_RATE SLEEP_MAX SLEEP_MIN ROUND_MIN_BYTES DOWNLOAD_URLS WEB_PORT; do
        if ! grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
            echo "   .env 中缺少关键字段 '$key'，将使用默认配置补齐"
            need_write_env=true
            break
        fi
    done
    
    # 检查是否有字节单位的配置需要修复
    if [ "$need_write_env" = false ]; then
        check_byte_units
    fi
fi

if [ "$need_write_env" = true ]; then
    cat > "$ENV_FILE" << 'ENVEOF'
# =========================================================
#  Traffic Keeper - 环境变量配置文件
#  可通过 Web 界面（http://<NAS_IP>:8080）修改
#  修改后无需重启容器，下一轮任务循环会自动重新加载
#
#  时间单位可选：s（秒）、m（分）、h（时），纯数字默认秒
#  数据单位可选：K、M、G、T（1024进制），纯数字默认字节
# =========================================================

# 下载限速（K/M/G），0 或留空表示不限速
LIMIT_RATE=5M

# 每轮任务最大休眠时间（支持 s/m/h，如 15m, 1h, 30s）
SLEEP_MAX=15m

# 每轮任务最小休眠时间（支持 s/m/h，如 1m, 30s）
SLEEP_MIN=1m

# 是否启用动态休眠（true / false）
DYNAMIC_SLEEP=true

# 启用动态休眠所需的单次最小下载量（支持 K/M/G/T，如 1G, 500M）
DYNAMIC_SLEEP_MIN_BYTES=1G

# 本轮下载总量低于此值时跳过动态休眠（支持 K/M/G/T），0 表示不检查
ROUND_MIN_BYTES=0

# 每轮最多执行下载次数
RUN_TIMES_MAX=3

# 连接超时（支持 s/m/h，如 15s, 1m）
CONNECT_TIMEOUT=15s

# 单次下载最大时间（支持 s/m/h，如 50m, 1h）
MAX_TIME=50m

# curl 重试次数
RETRY=5

# 重试间隔（支持 s/m/h，如 5s, 1m）
RETRY_DELAY=5s

# 链接抓取间隔（支持 s/m/h，如 6h, 30m）
FETCH_INTERVAL=6h

# 抓取链接的最小文件大小（支持 K/M/G/T，如 1G, 500M）
FETCH_MIN_FILE_BYTES=1G

# User-Agent
USER_AGENT='traffic-keeper/2.8.0 curl/8.0'

# 单日最大下载量（支持 K/M/G/T，如 200G, 1T）
MAX_DAILY_BYTES=200G

# 下载链接（逗号分隔）
DOWNLOAD_URLS="https://releases.ubuntu.com/22.04.5/ubuntu-22.04.5-desktop-amd64.iso,https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.tar.xz,http://updates-http.cdn-apple.com/2019WinterFCS/fullrestores/041-39257/32129B6C-292C-11E9-9E72-4511412B0A59/iPhone_4.7_12.1.4_16D57_Restore.ipsw,http://dldir1.qq.com/qqfile/qq/QQNT/Windows/QQ_9.9.15_240808_x64_01.exe,https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/22.04.5/ubuntu-22.04.5-desktop-amd64.iso,https://mirrors.aliyun.com/linux-kernel/v6.x/linux-6.6.tar.xz,https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/v20.12.2/node-v20.12.2-linux-x64.tar.xz,https://dldir1.qq.com/qqfile/qq/QQNT/Windows/QQ_9.9.15_240808_x64_01.exe,https://updates-http.cdn-apple.com/2019WinterFCS/fullrestores/041-39257/32129B6C-292C-11E9-9E72-4511412B0A59/iPhone_4.7_12.1.4_16D57_Restore.ipsw,https://mirrors.aliyun.com/ubuntu-releases/22.04.5/ubuntu-22.04.5-desktop-amd64.iso"

# Web 管理界面端口（需要与 docker-compose.yml 中的端口映射保持一致）
WEB_PORT=8080
ENVEOF
    echo "   .env 已生成（已修复配置单位问题） ✓"
else
    echo "   .env 已存在，将保留您的自定义配置 ✓"
fi

# ============ 4. Docker 环境检查 ============
echo ""
echo "🐳 检查 Docker 环境..."

if ! command -v docker >/dev/null 2>&1; then
    echo "❌ 未检测到 docker，请先在飞牛 NAS 应用中心安装 Docker"
    exit 1
fi

if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
    echo "   使用 docker compose ✓"
elif command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker-compose"
    echo "   使用 docker-compose ✓"
else
    echo "❌ 未检测到 Docker Compose，请确认 Docker 套件安装完整"
    exit 1
fi

# ============ 5. 清理旧容器 + 拉取/启动 ============
echo ""
echo "🐳 启动 Docker 容器..."

# 停止并清理旧容器（如果存在）
if docker ps -aq -f name="^${CONTAINER_NAME}$" | grep -q .; then
    echo "   清理旧容器..."
    $DOCKER_COMPOSE down >/dev/null 2>&1 || docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# 拉取最新镜像（如果镜像不存在则拉取，否则跳过）
if ! docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -q "^python:3.12-alpine$"; then
    echo "   首次启动，正在拉取 python:3.12-alpine 镜像..."
    echo "   （如长时间无输出，请检查 NAS 网络或配置 Docker 镜像加速器）"
    docker pull python:3.12-alpine 2>&1 || echo "   ⚠️  镜像拉取遇到问题，但仍将尝试启动"
fi

# 启动
$DOCKER_COMPOSE up -d

# 等待容器启动（最多 30 秒）
echo ""
echo "⏳ 等待容器启动..."
for i in $(seq 1 30); do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        echo "   ✓ 容器已启动"
        break
    fi
    sleep 1
done

# ============ 6. 输出结果 ============
echo ""
echo "🎉 安装完成！"
echo "----------------------------------------"
echo "📁 项目目录：$PROJECT_DIR"

# 尝试获取 NAS 的 LAN IP
NAS_IP=""
if command -v ip >/dev/null 2>&1; then
    NAS_IP="$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}' | head -1)"
fi
if [ -z "$NAS_IP" ]; then
    NAS_IP="<NAS_IP>"
else
    echo "🌐 Web 管理界面：http://$NAS_IP:8080"
    echo "   （如上述 IP 非您访问 NAS 的实际地址，请改用您常用的 NAS IP）"
fi

echo ""
echo "📄 查看容器日志：docker logs -f $CONTAINER_NAME"
echo "🛑 停止服务：cd $PROJECT_DIR && $DOCKER_COMPOSE down"
echo "🔄 重启服务：cd $PROJECT_DIR && $DOCKER_COMPOSE up -d"
echo "========================================"