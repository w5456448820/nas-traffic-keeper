#!/usr/bin/env sh
# =========================================================
#  Traffic Keeper - 容器入口脚本（稳定版）
#  Version : 2.9.2
#  核心原则：不在入口用stdbuf（此时coreutils未安装）
# =========================================================
set -e

mkdir -p /app/data

# 启动主脚本（后台运行），输出同时写入日志文件和标准输出
( exec /app/traffic-keeper.sh 2>&1 ) | while IFS= read -r line; do
    printf '%s\n' "$line"
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "$line" >> /app/data/console.log
    # 日志文件超过 2MB 时截断保留最新 500 行
    SIZE=$(wc -c < /app/data/console.log 2>/dev/null || echo 0)
    if [ "$SIZE" -gt 2097152 ]; then
        tail -n 500 /app/data/console.log > /tmp/console.log.bak
        mv /tmp/console.log.bak /app/data/console.log
    fi
done &

# 启动 Web 服务器（前台，保证容器不退出）
exec python3 /app/webserver.py
