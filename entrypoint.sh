#!/usr/bin/env sh
# =========================================================
#  Traffic Keeper - 容器入口脚本
#  同时启动：1) traffic-keeper.sh 主脚本  2) Web 管理界面
#  主脚本输出同时写入 /app/data/console.log 供 Web 读取
# =========================================================
set -e

mkdir -p /app/data

# 启动主脚本（后台运行），输出同时 tee 到日志文件和标准输出
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

# 启动 Web 服务器（前台）
exec python3 /app/webserver.py
