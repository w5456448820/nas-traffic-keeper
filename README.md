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

## 项目架构

```
/workspace/
├── install-traffic-keeper-fnos.sh    # 主安装脚本（一键部署）
├── README.md                          # 项目说明文档
├── .gitattributes                     # Git 属性配置（行尾符处理）
└── .gitignore                         # Git 忽略配置
```

### 生成的部署结构

安装脚本会在 `/vol2/1000/Docker/traffic-keeper/` 目录下生成以下文件：

```
traffic-keeper/
├── .env                    # 环境变量配置文件
├── docker-compose.yml      # Docker Compose 配置
├── traffic-keeper.sh       # 主运行脚本
├── fetch-links.sh          # 独立链接抓取脚本
├── data/                   # 统计数据目录
│   └── stats_data_YYYY-MM-DD.log
├── 流量统计/               # 显示用统计数据
│   └── stats_show_YYYY-MM-DD.log
└── links/                  # 抓取链接目录
    └── fetched-links.txt
```

## 核心模块职责

### 1. 安装脚本 (install-traffic-keeper-fnos.sh)

**职责**: 一键部署整个 Traffic Keeper 系统

**功能**:
- 生成配置文件 (`.env`)
- 生成主运行脚本 (`traffic-keeper.sh`)
- 生成链接抓取脚本 (`fetch-links.sh`)
- 生成 Docker Compose 配置 (`docker-compose.yml`)
- 启动 Docker 容器

### 2. 主运行脚本 (traffic-keeper.sh)

**职责**: 核心流量生成逻辑，控制下载循环

**主要功能**:
- Alpine 软件源修复
- 环境变量加载与校验
- 下载链接验证
- 流量统计记录
- 动态/固定休眠控制
- 每日流量上限控制
- 日期切换自动重置统计

### 3. 链接抓取脚本 (fetch-links.sh)

**职责**: 从多个来源抓取可用的大文件下载链接

**数据来源**:
- GitHub API (curl, jq, nodejs releases)
- 国内镜像站 (清华大学镜像源、阿里云镜像源等)

## 配置

安装后可编辑：

```bash
/vol2/1000/Docker/traffic-keeper/.env
```

### 环境变量说明

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `LIMIT_RATE` | `5M` | 下载限速 (K/M/G)，0 或留空表示不限速 |
| `SLEEP_MIN` | `60` | 每轮任务最小休眠秒数 |
| `SLEEP_MAX` | `900` | 每轮任务最大休眠秒数 |
| `DYNAMIC_SLEEP` | `true` | 是否启用动态休眠 (`true`/`false`) |
| `DYNAMIC_SLEEP_MIN_BYTES` | `1073741824` (1 GiB) | 启用动态休眠所需的单次最小下载量 |
| `RUN_TIMES_MAX` | `3` | 每轮最多执行下载次数 |
| `CONNECT_TIMEOUT` | `15` | 连接超时秒数 |
| `MAX_TIME` | `3000` | 单次下载最大时间秒数 |
| `RETRY` | `5` | curl 重试次数 |
| `RETRY_DELAY` | `5` | 重试间隔秒数 |
| `FETCH_INTERVAL` | `21600` (6小时) | 链接抓取间隔秒数 |
| `FETCH_MIN_FILE_BYTES` | `1073741824` (1 GiB) | 抓取链接的最小文件大小 |
| `USER_AGENT` | `traffic-keeper/2.7.1 curl/8.0` | User-Agent |
| `MAX_DAILY_BYTES` | `214748364800` (200 GB) | 单日最大下载量 |
| `DOWNLOAD_URLS` | (多个ISO链接) | 备用下载链接列表 |

## 关键函数说明

### traffic-keeper.sh 核心函数

#### 工具函数

| 函数名 | 参数 | 返回值 | 说明 |
|--------|------|--------|------|
| `get_today` | - | `YYYY-MM-DD` | 获取当前日期 |
| `is_uint` | `$1` | 0/1 | 验证是否为无符号整数 |
| `human_bytes` | `$1` (字节数) | 人类可读大小 | 字节数转可读格式 (如 1.5GiB) |
| `human_seconds` | `$1` (秒数) | `XXmin XXs` | 秒数转可读格式 |
| `next_wake_time` | `$1` (秒数) | `HH:MM:SS` | 计算下次唤醒时间 |
| `normalize_url` | `$1` | 规范化URL | 去除 URL 首尾空白和特殊字符 |
| `rand_n` | `$1` (最大值) | 1~MAX 随机数 | 生成均匀分布随机数 |

#### 配置函数

| 函数名 | 说明 |
|--------|------|
| `apply_defaults` | 应用默认配置值并校验参数合法性 |
| `reload_env` | 重新加载 `.env` 配置文件 |

#### 统计函数

| 函数名 | 说明 |
|--------|------|
| `read_var` | 从数据文件读取指定变量的值 |
| `validate_data_file` | 验证统计数据文件格式完整性 |
| `init_stats` | 初始化当日统计数据文件 |
| `generate_show_stats` | 生成显示用统计信息 |
| `update_stats` | 更新统计数据（下载次数、流量、耗时） |

#### 链接管理函数

| 函数名 | 说明 |
|--------|------|
| `should_fetch_links` | 判断是否需要重新抓取链接 |
| `force_fetch_next_round` | 标记下一轮强制重新抓取链接 |
| `fetch_links` | 执行链接抓取逻辑 |
| `validate_link` | 验证单个链接的可用性和文件大小 |
| `check_fetched_links` | 批量验证抓取到的链接 |

#### 业务函数

| 函数名 | 说明 |
|--------|------|
| `check_daily_limit` | 检查是否达到每日流量上限 |
| `calc_sleep_time` | 计算本轮休眠时间（支持动态/固定模式） |

### fetch-links.sh 核心函数

| 函数名 | 参数 | 返回值 | 说明 |
|--------|------|--------|------|
| `is_uint` | `$1` | 0/1 | 验证是否为无符号整数 |
| `human_bytes` | `$1` | 人类可读大小 | 字节数转可读格式 |
| `extract_content_length` | `$1` (响应头) | 文件大小 | 从 Content-Length 提取文件大小 |
| `extract_content_range_total` | `$1` (响应头) | 文件大小 | 从 Content-Range 提取文件总大小 |
| `remote_file_size_check` | `$1` (URL) | 0/1/2 | 检查远端文件大小是否达标 |
| `append_if_large_enough` | `$1` (URL) | - | 检查并追加达标链接到输出文件 |

## 依赖关系

### 外部依赖

- **Docker**: 容器化运行环境
- **Docker Compose**: 容器编排
- **Alpine Linux 3.23**: 容器基础镜像
- **curl**: HTTP 客户端（下载和 API 请求）
- **coreutils**: 基础工具（`numfmt` 等）

### 镜像源

容器内使用阿里云 Alpine 镜像源：

```
https://mirrors.aliyun.com/alpine/v${ALPINE_VER}/main
https://mirrors.aliyun.com/alpine/v${ALPINE_VER}/community
```

### 下载来源

1. **GitHub Releases**: curl, jq, nodejs
2. **国内镜像站**:
   - 清华大学镜像源 (mirrors.tuna.tsinghua.edu.cn)
   - 阿里云镜像源 (mirrors.aliyun.com)
   - 官方镜像源 (releases.ubuntu.com, download.opensuse.org 等)

## Docker 配置

### 镜像与重启

- **基础镜像**: `alpine:3.23`
- **重启策略**: `always` (总是重启)
- **容器名称**: `traffic-keeper`

### 存储卷挂载

| 宿主机路径 | 容器内路径 | 说明 |
|-----------|-----------|------|
| `./traffic-keeper.sh` | `/app/traffic-keeper.sh:ro` | 主运行脚本 |
| `./fetch-links.sh` | `/app/fetch-links.sh:ro` | 链接抓取脚本 |
| `./.env` | `/app/.env:ro` | 环境配置 |
| `./data` | `/app/data` | 统计数据 |
| `./流量统计` | `/app/流量统计` | 显示统计 |
| `links` (volume) | `/app/links` | 抓取链接 |
| `/etc/localtime` | `/etc/localtime:ro` | 时区同步 |
| `tmpfs` | `/tmp` | 临时文件系统 |

### 日志配置

```yaml
logging:
  driver: json-file
  options:
    max-size: 2m
    max-file: 3
```

## 主循环流程

```
┌─────────────────────────────────────────────────────────────┐
│                      主循环 (while true)                    │
├─────────────────────────────────────────────────────────────┤
│  1. reload_env        - 重新加载配置                        │
│  2. fetch_links        - 检查/抓取下载链接                   │
│  3. check_fetched_links - 验证抓取的链接                    │
│  4. fallback DOWNLOAD_URLS - 抓取失败时使用备用链接          │
│  5. validate_data_file - 检查统计文件有效性                  │
│  6. check_daily_limit  - 检查是否达到日流量上限             │
│  7. 执行下载循环 (1~RUN_TIMES_MAX次)                        │
│     ├── 选择下载链接（避免重复）                            │
│     ├── 验证文件大小                                        │
│     ├── 执行 curl 下载                                      │
│     ├── 更新统计数据                                        │
│     └── 检查日流量上限                                      │
│  8. 生成统计显示文件                                        │
│  9. 计算休眠时间                                            │
│  10. sleep 休眠                                             │
│  11. 循环                                                   │
└─────────────────────────────────────────────────────────────┘
```

## 统计数据格式

### data/stats_data_YYYY-MM-DD.log

```
DATE=YYYY-MM-DD
GENERATE_TIME=HH:MM:SS
COUNT=下载次数
SIZE_BYTES=总下载字节数
TIME_SECONDS=总耗时秒数
```

### 流量统计/stats_show_YYYY-MM-DD.log

```
===============================
       📊 流量下载信息统计
-------------------------------
 生成日期    ：YYYY-MM-DD
 生成时间    ：HH:MM:SS
 下载次数    ：N
 下载流量    ：X.XXGiB
 累计耗时    ：XXmin XXs
===============================
```

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

## 注意事项

本脚本仅适合在你拥有管理权限的 NAS 和网络环境中使用。请合理设置限速、休眠时间和每日流量上限，避免影响正常网络使用。

## 版本历史

| 版本 | 更新内容 |
|------|----------|
| 2.7.1 | 新增 Web 管理界面（端口 8080），支持通过 Web 界面配置所有参数、实时查看终端日志；修复安装脚本在目标目录运行时的 cp 自复制问题；修复 apk 安装失败导致容器死循环重启的问题（三镜像源容错+超时机制）；修复 .env 多行格式导致 docker compose 解析失败的问题 |
| 2.7.0 | 重构项目结构，新增 entrypoint.sh、webserver.py、docker-compose.yml；支持 Docker 容器化部署；新增链接抓取脚本 fetch-links.sh |
| 2.6.16 | 修复 curl 请求跟随重定向(-L)，解决阿里云镜像 302 下载失败；增加更多国内镜像源；修复 docker-compose.yml YAML 层级错误；使用 $RANDOM 替代 od+mod 方案提高随机数质量；下载使用 -sS 替代 -# 避免进度条污染日志 |
