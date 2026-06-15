# NAS 流量平衡脚本

用于飞牛 NAS / FnOS 的 Traffic Keeper 一键安装脚本，通过 Docker 容器定时下载公开大文件来生成网络流量，并记录每日下载次数、流量和耗时统计。

## 功能

- 固定安装目录：`/vol2/1000/Docker/traffic-keeper`
- 自动生成 `.env`、`docker-compose.yml`、主运行脚本和链接抓取脚本
- 支持下载限速、随机休眠、动态休眠、每日流量上限
- 支持从 GitHub Release 和镜像站抓取下载链接
- 抓取失败或抓取链接不可用时，下一轮自动重新抓取
- 支持按单次下载量控制动态休眠，小于阈值时自动回退为固定最小休眠
- 支持按远端文件大小过滤抓取链接，小文件或无法确认大小的链接不参与下载
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
- `DYNAMIC_SLEEP_MIN_BYTES`：启用动态休眠所需的单次最小下载量，默认 `1073741824`，即 `1 GiB`
- `RUN_TIMES_MAX`：每轮最多下载次数
- `FETCH_MIN_FILE_BYTES`：抓取链接的最小文件大小，默认 `1073741824`，即 `1 GiB`
- `MAX_DAILY_BYTES`：每日最大下载量，单位字节
- `DOWNLOAD_URLS`：备用下载链接列表

## 更新说明

### v2.6.8-fnos-fixed

本次更新主要增强飞牛 NAS / FnOS 环境下的稳定性、链接可用性判断和动态休眠控制逻辑，避免无效链接、小文件链接或异常抓取结果参与下载任务。

新增单次下载量阈值控制：

```env
DYNAMIC_SLEEP_MIN_BYTES=1073741824
```

默认值为 `1 GiB`。当单次实际下载量小于该阈值时，本轮任务不会启用动态休眠，而是使用最小休眠时间 `SLEEP_MIN`，避免小文件、异常中断下载或无效下载结果触发过长的随机休眠。

新增抓取链接文件大小过滤：

```env
FETCH_MIN_FILE_BYTES=1073741824
```

默认值为 `1 GiB`。抓取到的下载链接会先检查远端文件大小，只有文件大小达到该阈值的链接才会参与后续下载。文件过小、无法确认文件大小，或校验失败的链接会被自动排除。

本版本继续保留此前已修复内容：

- 固定安装目录为 `/vol2/1000/Docker/traffic-keeper`
- 修复 `.env` 多行变量与 Docker Compose `env_file` 冲突
- 修复 URL 反引号导致的命令执行问题
- 修复 `curl` 失败触发 `set -e` 直接退出的问题
- 修复 `apply_defaults` 返回值导致容器反复重启的问题
- 固定 Alpine 镜像版本为 `alpine:3.23`
- 优化 curl 下载进度条显示
- 抓取失败或链接不可用时，下一轮自动重新抓取

两个新增参数都可以在 `.env` 中自行调整。设置为 `0` 时表示关闭对应限制：

```env
DYNAMIC_SLEEP_MIN_BYTES=0
FETCH_MIN_FILE_BYTES=0
```

## 注意事项

本脚本仅适合在你拥有管理权限的 NAS 和网络环境中使用。请合理设置限速、休眠时间和每日流量上限，避免影响正常网络使用。
