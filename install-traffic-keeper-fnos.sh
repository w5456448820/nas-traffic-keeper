#!/usr/bin/env bash
# =========================================================
#  Traffic Keeper - FnOS / 飞牛 NAS 一键安装脚本
#  Version : 2.7.0
#  新增功能：
#    - Web 管理界面（端口 8080）
#    - 支持通过 Web 界面修改所有配置参数
#    - 支持 Web 界面实时查看终端日志
# =========================================================
set -e

echo ""
echo "========================================"
echo "🚀 Traffic Keeper - 飞牛 NAS 一键安装"
echo "   （含 Web 管理界面）"
echo "========================================"
echo ""

PROJECT_DIR="/vol2/1000/Docker/traffic-keeper"
CONTAINER_NAME="traffic-keeper"

# 脚本所在目录（用于查找源文件）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

echo "📁 安装目录：$PROJECT_DIR"
echo ""

# ---------- 复制文件（优先从脚本所在目录复制） ----------
echo "✅ 部署项目文件..."

copy_file() {
    local filename="$1"
    if [ -f "$SCRIPT_DIR/$filename" ]; then
        cp "$SCRIPT_DIR/$filename" "$PROJECT_DIR/$filename"
        chmod +x "$PROJECT_DIR/$filename" 2>/dev/null || true
        return 0
    fi
    echo "⚠️  未找到源文件：$SCRIPT_DIR/$filename"
    return 1
}

# 主脚本和辅助脚本
for f in traffic-keeper.sh fetch-links.sh webserver.py entrypoint.sh; do
    copy_file "$f" || true
done

# 配置文件（若已有则不覆盖，保留用户自定义配置）
if [ ! -f "$PROJECT_DIR/.env" ]; then
    if [ -f "$SCRIPT_DIR/.env" ]; then
        cp "$SCRIPT_DIR/.env" "$PROJECT_DIR/.env"
    fi
fi

# docker-compose.yml（每次都更新，确保端口映射正确）
if [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
    cp "$SCRIPT_DIR/docker-compose.yml" "$PROJECT_DIR/docker-compose.yml"
fi

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

# 清理旧容器（如果存在）
if docker ps -aq -f name="^${CONTAINER_NAME}$" | grep -q .; then
    echo "🗑️  清理旧容器..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# 启动
$DOCKER_COMPOSE up -d

echo ""
echo "🎉 安装完成！"
echo "----------------------------------------"
echo "📁 项目目录：$PROJECT_DIR"
echo "🌐 Web 管理界面：http://<NAS_IP>:8080"
echo "   （将 <NAS_IP> 替换为您飞牛 NAS 的实际 IP 地址）"
echo "📄 查看容器日志：docker logs -f $CONTAINER_NAME"
echo "🛑 停止服务：cd $PROJECT_DIR && $DOCKER_COMPOSE down"
echo "========================================"
