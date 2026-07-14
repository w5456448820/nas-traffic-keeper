#!/bin/bash
# Traffic Keeper FPK 构建脚本
# 用于在飞牛 NAS 上构建 .fpk 安装包

set -e

APP_NAME="traffic-keeper"
VERSION="2.9.3"
BUILD_DIR="/tmp/fpk-build-${APP_NAME}"

echo "=== Traffic Keeper FPK Builder ==="
echo "Version: ${VERSION}"

# 检查 fnpack
if ! command -v fnpack &> /dev/null; then
    echo "错误: fnpack 未安装，请先安装飞牛开发工具"
    exit 1
fi

# 清理并创建构建目录
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/cmd"
mkdir -p "${BUILD_DIR}/app/server"
mkdir -p "${BUILD_DIR}/app/ui/images"
mkdir -p "${BUILD_DIR}/config"

# 复制应用文件
cp -r app/server/* "${BUILD_DIR}/app/server/"
cp -r app/ui/* "${BUILD_DIR}/app/ui/"
cp -r cmd/* "${BUILD_DIR}/cmd/"
cp -r config/* "${BUILD_DIR}/config/"
cp manifest "${BUILD_DIR}/"
cp ICON.PNG "${BUILD_DIR}/"
cp ICON_256.PNG "${BUILD_DIR}/"

# 设置执行权限
chmod +x "${BUILD_DIR}/cmd/main"
chmod +x "${BUILD_DIR}/app/server/"*.sh

# 构建 FPK
cd "${BUILD_DIR}"
fnpack build

# 复制结果到当前目录
cp "${BUILD_DIR}/${APP_NAME}.fpk" "./dist/${APP_NAME}-v${VERSION}.fpk"

echo ""
echo "构建成功: ./dist/${APP_NAME}-v${VERSION}.fpk"
