# NAS 流量平衡脚本

用于飞牛 NAS / FnOS 的 Traffic Keeper 一键安装脚本，通过 Docker 容器定时下载公开大文件来生成网络流量，并记录每日下载次数、流量和耗时统计。

## 功能

- 固定安装目录：`/vol2/1000/Docker/traffic-keeper`
- 自动生成 `.env`、`docker-compose.yml`、主运行脚本和链接抓取脚本
- 支持下载限速、随机休眠、动态休眠、每日流量上限
- 支持从 GitHub Release 和镜像站抓取下载链接
- 抓取失败或抓取链接不可用时，下一轮自动重新抓取
- 统计文件持久化保存到 `data/` 和 `流量统计/`
- 适配飞牛 NAS Docker 环境

## 使用方法

在飞牛 NAS 终端执行：

```bash
cd /vol2/1000/Docker
bash install-traffic-keeper-fnos.sh
```

如果脚本不在该目录，请先进入脚本所在目录再执行：

```bash
bash install-traffic-keeper-fnos.sh
```

## 常用命令

查看日志：

```bash
docker logs -f traffic-keeper
```

停止服务：

```bash
cd /vol2/1000/Docker/traffic-keeper
docker compose down
```

重启服务：

```bash
docker restart traffic-keeper
```

强制下一轮重新抓取链接：

```bash
rm -f /vol2/1000/Docker/traffic-keeper/links/.last-fetch
```

## 配置

安装后可编辑：

```bash
/vol2/1000/Docker/traffic-keeper/.env
```

常用配置项：

- `LIMIT_RATE`：下载限速，例如 `5M`
- `SLEEP_MIN`：每轮最小休眠秒数
- `SLEEP_MAX`：每轮最大休眠秒数
- `DYNAMIC_SLEEP`：是否启用动态休眠，`true` 或 `false`
- `RUN_TIMES_MAX`：每轮最多下载次数
- `MAX_DAILY_BYTES`：每日最大下载量，单位字节
- `DOWNLOAD_URLS`：备用下载链接列表

## 注意事项

本脚本仅适合在你拥有管理权限的 NAS 和网络环境中使用。请合理设置限速、休眠时间和每日流量上限，避免影响正常网络使用。
