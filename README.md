# Traffic Keeper

飞牛 NAS / FnOS 流量平衡脚本，支持 **Web 管理界面**（浏览器配置 + 实时日志查看 + 链接管理）和 Docker 容器化一键部署。

通过定时下载公开大文件来生成网络流量，并记录每日下载次数、流量和耗时统计。

## 功能

### 核心能力
- **一键安装**：`install-traffic-keeper-fnos.sh` 自动完成所有部署步骤
- **Docker 容器化**：基于 `python:3.12-alpine` 镜像，通过 `docker-compose.yml` 管理
- **Web 管理界面**：通过 `http://<NAS_IP>:8080` 进行图形化配置、监控和链接管理
- **实时日志流**：Web 界面通过 SSE（Server-Sent Events）实时显示终端输出
- **配置热生效**：保存配置后下一轮任务循环自动加载，无需重启容器
- **下载限速**：支持 K/M/G/T 格式（如 `5M`、`1G`），0 或留空表示不限速
- **随机休眠**：每轮任务在 `SLEEP_MIN` ~ `SLEEP_MAX` 范围内随机休眠，避免固定周期被识别
- **动态休眠**：单次下载量较小时自动缩短休眠时间（可关闭）
- **每日流量上限**：达到设定值后自动暂停，次日重置
- **链接抓取**：自动从 GitHub Release 和国内镜像站抓取大文件链接
- **链接检测**：按间隔自动检测抓取链接的有效性，过滤失效/过小链接
- **文件大小过滤**：根据 Content-Length / Content-Range 过滤小文件
- **统计持久化**：每日数据保存到 `data/` 和 `流量统计/`
- **镜像源容错**：Alpine 软件源支持三镜像自动切换（阿里云 / 清华 / 官方），超时可控
- **可选单位格式**：时间支持 `s/m/h`，数据支持 `K/M/G/T`，纯数字分别默认秒和字节

## 项目架构

```
traffic-keeper/
├── install-traffic-keeper-fnos.sh  # 一键安装脚本
├── traffic-keeper.sh                # 主运行脚本（下载逻辑）
├── fetch-links.sh                   # 独立链接抓取脚本
├── webserver.py                     # Web 管理界面服务器（Python 标准库）
├── entrypoint.sh                    # 容器入口（同时启动主脚本 + Web 服务）
├── docker-compose.yml               # Docker Compose 配置
├── .env                             # 环境变量配置文件
├── data/                            # 统计数据目录
│   ├── stats_data_YYYY-MM-DD.log    # 每日原始数据
│   ├── console.log                  # 主脚本终端日志（Web 实时读取）
│   └── links/                       # 抓取链接目录
│       ├── fetched-links.txt        # 校验通过的可用链接
│       ├── validated_urls.list      # 检测有效的链接
│       ├── invalid_urls.list        # 检测失效的链接
│       ├── .last-fetch              # 上次抓取时间戳
│       ├── .last-check              # 上次检测时间戳
│       └── check_duration.txt       # 检测耗时（秒）
└── 流量统计/                        # 显示用统计数据
    └── stats_show_YYYY-MM-DD.log   # 每日格式化统计
```

## 核心模块职责

### 1. 一键安装脚本 (install-traffic-keeper-fnos.sh)

**职责**：一键部署整个 Traffic Keeper 系统

**功能**：
- 配置所有脚本的可执行权限
- 检查必需文件是否齐全（5 个核心文件：`traffic-keeper.sh`、`fetch-links.sh`、`webserver.py`、`entrypoint.sh`、`docker-compose.yml`）
- 缺失文件自动从 GitHub 仓库下载（`raw.githubusercontent.com`）
- `.env` 不存在或缺少关键字段时自动生成默认配置
- 自动检测 `.env` 中可能的单位配置错误并修复
- 自动检测 `docker compose` 或 `docker-compose` 命令
- 自动探测 NAS 的 LAN IP 并输出访问地址
- 清理旧容器，拉取最新镜像，启动新容器

### 2. 主运行脚本 (traffic-keeper.sh)

**职责**：核心流量生成逻辑，控制下载循环

**主要功能**：
- Alpine 软件源多镜像容错（阿里云 / 清华 / 官方，超时控制）
- 环境变量加载与合法性校验（含可选单位自动转换：s/m/h、K/M/G/T）
- 下载链接验证（Content-Length / Content-Range 双重检测）
- 流量统计记录（次数、字节数、耗时）
- 动态/固定休眠控制
- 每日流量上限控制
- 日期切换自动重置统计
- 抓取链接循环使用 + 兜底 `.env` 备用链接
- 下载前文件大小预检，过小文件自动跳过
- 链接检测间隔控制，避免每轮重复检测所有链接

### 3. 链接抓取脚本 (fetch-links.sh)

**职责**：从多个来源抓取可用的大文件下载链接

**数据来源**：
- **GitHub API**：curl、jq、nodejs 等仓库的 Releases 资源
- **国内镜像站**：清华大学镜像源、阿里云镜像源等

**输出**：`./data/links/fetched-links.txt`（一行一个 URL）

**过滤规则**：通过 `FETCH_MIN_FILE_BYTES` 配置最小文件大小阈值（支持 K/M/G/T 单位）

### 4. Web 服务器 (webserver.py)

**职责**：提供管理界面（HTML + API）

**实现**：纯 Python 标准库（`http.server`、`socketserver`、`json`、`threading`），零第三方依赖

**页签**：

| 页签 | 说明 |
|------|------|
| 配置管理 | 时间设置、数据设置、网络连接、系统设置 |
| 终端日志 | 实时日志流 + 搜索 + 自动滚动 |
| 历史数据 | 最近 100 条历史统计记录 |
| 抓取链接 | 当前可用链接列表（总计 / 可用数量） |
| 配置下载源 | 下载链接编辑（每行一个链接） |

**统计面板**：

| 指标 | 说明 |
|------|------|
| 生成日期 / 生成时间 | 今日统计的生成时间 |
| 下载次数 / 下载流量 / 累计耗时 | 今日下载统计 |
| 上次抓取 | 上次执行链接抓取的时间 |
| 抓取链接 | 抓取到的链接总数 |
| 可用链接 | 经检测后有效的链接数 |
| 检测时间 | 上次链接检测的时间 |
| 检测用时 | 上次链接检测的耗时 |

**API 端点**：

| 端点 | 方法 | 说明 |
|------|------|------|
| `/` | GET | 管理界面 HTML 页面 |
| `/api/config` | GET | 读取当前 `.env` 配置 |
| `/api/config` | POST | 保存配置到 `.env` |
| `/api/stats` | GET | 读取今日统计数据 |
| `/api/history` | GET | 读取历史统计数据（最近 100 条，按日期倒序） |
| `/api/links` | GET | 读取当前链接列表（总计 / 可用 / URL 列表） |
| `/api/logs` | GET | 获取历史日志（最新 2000 行） |
| `/api/logs/stream` | GET | **SSE 实时日志流** |

### 5. 容器入口脚本 (entrypoint.sh)

**职责**：同时启动主脚本和 Web 服务器

**流程**：
1. 创建 `/app/data` 目录
2. 后台启动 `traffic-keeper.sh`，输出同时写入 `console.log` 和标准输出
3. 日志文件超过 2MB 时自动截断保留最新 500 行
4. 前台执行 `python3 webserver.py` 启动 Web 服务（保证容器不退出）

## 配置

### 方式一：Web 界面（推荐）

浏览器访问 `http://<NAS_IP>:8080`，切换到对应标签页直接修改参数后点击 **保存配置**。

保存后下一轮任务循环自动生效，**无需重启容器**。

### 方式二：手动编辑 .env

```bash
vi /vol2/1000/Docker/traffic-keeper/.env
```

修改后无需重启，脚本主循环下一轮自动调用 `reload_env()` 重新加载。

### 环境变量说明

> **注意**：时间字段支持 `s`（秒）、`m`（分）、`h`（时）单位，如 `15m`、`1h`、`30s`；纯数字默认秒。数据字段支持 `K`、`M`、`G`、`T` 单位（1024 进制），如 `1G`、`500M`、`10K`；纯数字默认字节。主脚本会自动统一转换为内部单位。

| 变量名 | 默认值 | 单位 | 说明 |
|--------|--------|------|------|
| `LIMIT_RATE` | `5M` | 数据 | 下载限速（K/M/G/T），0 或留空表示不限速 |
| `SLEEP_MIN` | `1m` | 时间 | 每轮任务最小休眠时间（支持 s/m/h） |
| `SLEEP_MAX` | `15m` | 时间 | 每轮任务最大休眠时间（支持 s/m/h） |
| `DYNAMIC_SLEEP` | `true` | - | 是否启用动态休眠（`true` / `false`） |
| `ROUND_MIN_BYTES` | `0` | 数据 | 本轮下载总量低于此值时跳过休眠，0 表示不检查（支持 K/M/G/T） |
| `RUN_TIMES_MAX` | `3` | - | 每轮最多执行下载次数 |
| `CONNECT_TIMEOUT` | `15s` | 时间 | 连接超时时间（支持 s/m/h） |
| `MAX_TIME` | `10m` | 时间 | 单次下载最大时间（支持 s/m/h） |
| `RETRY` | `5` | - | curl 重试次数 |
| `RETRY_DELAY` | `5s` | 时间 | 重试间隔（支持 s/m/h） |
| `FETCH_INTERVAL` | `6h` | 时间 | 链接抓取间隔（支持 s/m/h） |
| `LINK_CHECK_INTERVAL` | `30m` | 时间 | 链接检测间隔（支持 s/m/h） |
| `FETCH_MIN_FILE_BYTES` | `500M` | 数据 | 抓取链接的最小文件大小（支持 K/M/G/T） |
| `USER_AGENT` | `traffic-keeper/2.9.2 curl/8.0` | - | HTTP User-Agent |
| `MAX_DAILY_BYTES` | `200G` | 数据 | 单日最大下载量（支持 K/M/G/T） |
| `DOWNLOAD_URLS` | （多个 ISO 链接） | - | 备用下载链接列表（每行一个，内部存储为逗号分隔） |
| `WEB_PORT` | `8080` | - | Web 管理界面端口 |

## 关键函数说明

### traffic-keeper.sh 核心函数

#### 工具函数

| 函数名 | 参数 | 返回值 | 说明 |
|--------|------|--------|------|
| `get_today` | - | `YYYY-MM-DD` | 获取当前日期 |
| `is_uint` | `$1` | 0/1 | 验证是否为无符号整数 |
| `parse_size` | `$1` | 字节数 | 支持 K/M/G/T 单位转字节 |
| `parse_time` | `$1` | 秒数 | 支持 s/m/h 单位转秒 |
| `human_bytes` | `$1`（字节数） | 人类可读大小 | 字节数转可读格式（TiB/GiB/MiB/KiB/B） |
| `human_seconds` | `$1`（秒数） | `HH:MM:SS` | 秒数转可读格式 |
| `next_wake_time` | `$1`（秒数） | `HH:MM:SS` | 计算下次唤醒时间 |
| `normalize_url` | `$1` | 规范化 URL | 去除首尾空白和特殊字符 |
| `rand_n` | `$1`（最大值） | 1~MAX 随机数 | 生成均匀分布随机数 |

#### 配置函数

| 函数名 | 说明 |
|--------|------|
| `apply_defaults` | 应用默认配置值并校验参数合法性，支持可选单位格式 |
| `reload_env` | 重新加载 `.env` 配置，自动转换单位，错误时保持当前配置 |

#### 统计函数

| 函数名 | 说明 |
|--------|------|
| `read_var` | 从数据文件读取指定变量的值 |
| `validate_data_file` | 验证统计数据文件格式完整性 |
| `init_stats` | 初始化当日统计数据文件 |
| `generate_show_stats` | 生成显示用统计信息（`流量统计/` 目录） |
| `update_stats` | 更新统计数据（下载次数、流量、耗时） |

#### 链接管理函数

| 函数名 | 说明 |
|--------|------|
| `should_fetch_links` | 判断是否到达抓取间隔 |
| `force_fetch_next_round` | 删除时间戳文件，标记下一轮强制重新抓取 |
| `fetch_links` | 执行抓取脚本并验证结果 |
| `should_check_links` | 判断是否到达检测间隔 |
| `check_fetched_links` | 逐条校验抓取到的链接（去重 + 排除无效链接） |
| `validate_link` | 验证单个链接是否可用（HEAD 请求 + Content-Length 校验） |

#### 业务函数

| 函数名 | 说明 |
|--------|------|
| `check_daily_limit` | 检查是否达到每日流量上限 |
| `calc_sleep_time` | 计算本轮休眠时间（动态模式 = 随机，固定模式 = `SLEEP_MIN`） |

### fetch-links.sh 核心函数

| 函数名 | 参数 | 返回值 | 说明 |
|--------|------|--------|------|
| `is_uint` | `$1` | 0/1 | 验证是否为无符号整数 |
| `parse_size` | `$1` | 字节数 | 支持 K/M/G/T 单位转字节 |
| `human_bytes` | `$1` | 人类可读大小 | 字节数转可读格式 |
| `remote_file_size_check` | `$1`（URL） | 0/1/2 | 检查远端文件大小是否达标（0=达标，1=过小，2=无法确认） |
| `append_if_large_enough` | `$1`（URL） | - | 检查并追加达标链接到输出文件 |

### webserver.py 核心函数/类

| 类/函数 | 说明 |
|---------|------|
| `Handler.do_GET` | 分发 GET 请求（HTML 页面 + 8 个 API 端点） |
| `Handler.do_POST` | 处理配置保存请求 |
| `get_web_port()` | 从 `.env` 读取 `WEB_PORT`，默认 8080 |
| `LogWatcher` | 日志文件尾行监控（inode 变更检测，防截断） |
| `ThreadedServer` | 多线程 HTTPServer（支持并发访问） |
| `env_to_dict()` | 解析 `.env` 为 Python dict（处理引号，DOWNLOAD_URLS 逗号转换行） |
| `write_env()` | 将 dict 写回 `.env`（保留注释和格式，DOWNLOAD_URLS 换行转逗号） |
| `get_stats()` | 读取并格式化今日统计数据（含链接抓取/检测统计） |
| `get_history()` | 读取历史统计数据（data + stats_show 双源，去重） |
| `get_log_tail()` | 读取日志文件末尾（默认 1000 行） |

## 依赖关系

### 容器镜像

- **基础镜像**：`python:3.12-alpine`（Python 3.12 + Alpine Linux）
- **重启策略**：`always`（容器退出后自动重启）

### Alpine 软件源

容器启动时自动修复软件源，依次尝试：

1. `https://mirrors.aliyun.com/alpine/v{VERSION}/...`
2. `https://mirrors.tuna.tsinghua.edu.cn/alpine/v{VERSION}/...`
3. `http://dl-cdn.alpinelinux.org/alpine/v{VERSION}/...`

每个镜像最多等待 60 秒（`apk update`）+ 120 秒（`apk add`），失败自动尝试下一个。

> **重要**：若所有镜像均不可达，脚本继续运行（curl 失败会跳过下载，不阻塞容器）。

### 下载来源

1. **GitHub Releases**（通过 fetch-links.sh 抓取）：curl、jq、nodejs 等
2. **国内镜像站**：
   - 清华大学镜像源 (`mirrors.tuna.tsinghua.edu.cn`)
   - 阿里云镜像源 (`mirrors.aliyun.com`)
   - 官方镜像源 (`releases.ubuntu.com`、`cdn.kernel.org` 等)
3. **备用链接**：`.env` 中 `DOWNLOAD_URLS` 配置的链接

## Docker 配置

### docker-compose.yml 关键配置

```yaml
services:
  traffic-keeper:
    image: python:3.12-alpine          # Python 3.12 + Alpine Linux
    container_name: traffic-keeper
    restart: always
    working_dir: /app
    volumes:
      - ./traffic-keeper.sh:/app/traffic-keeper.sh:ro   # 主脚本（只读挂载）
      - ./fetch-links.sh:/app/fetch-links.sh:ro         # 抓取脚本（只读挂载）
      - ./webserver.py:/app/webserver.py:ro              # Web 服务器（只读挂载）
      - ./entrypoint.sh:/app/entrypoint.sh:ro            # 容器入口（只读挂载）
      - ./.env:/app/.env                                 # 配置文件（读写）
      - ./data:/app/data                                 # 数据目录（读写，含链接文件）
      - ./流量统计:/app/流量统计                          # 显示统计（读写）
      - /etc/localtime:/etc/localtime:ro                # 时区同步
    ports:
      - "8080:8080"                                      # Web 管理界面
    tmpfs:
      - /tmp                                            # 临时文件系统
    logging:
      driver: json-file
      options:
        max-size: 2m      # 单个日志文件最大 2MB
        max-file: 3       # 最多保留 3 个轮转文件
    command: ["/bin/sh", "/app/entrypoint.sh"]          # 入口脚本
```

## 主循环流程

```
┌─────────────────────────────────────────────────────────────┐
│                    entrypoint.sh                             │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  后台: traffic-keeper.sh (输出 → console.log + stdout)  │ │
│  └────────────────────────────────────────────────────────┘ │
│  前台: python3 webserver.py (端口 8080)                     │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│              traffic-keeper.sh 主循环 (while true)          │
├─────────────────────────────────────────────────────────────┤
│  1. reload_env()       - 重新加载 .env 配置（单位自动转换） │
│  2. fetch_links()      - 检查是否到达抓取间隔，到达则执行   │
│  3. check_fetched_links - 检查是否到达检测间隔，逐条校验    │
│  4. 选择下载来源       - 优先抓取链接，失败用 DOWNLOAD_URLS │
│  5. validate_data_file - 检查统计文件有效性（日期切换重置） │
│  6. check_daily_limit  - 检查是否达到日流量上限             │
│  7. 执行下载循环 (1~RUN_TIMES_MAX 次)                      │
│     ├── 随机选择链接（避免连续重复）                        │
│     ├── HEAD 请求预检文件大小                               │
│     ├── 过小文件跳过                                       │
│     ├── curl 下载（限速 + 超时 + 重试）                     │
│     ├── update_stats() 更新统计                             │
│     └── 检查日流量上限                                      │
│  8. 生成统计显示文件 (stats_show)                           │
│  9. calc_sleep_time() - 计算休眠时间                       │
│ 10. 输出统计摘要 + 休眠                                    │
│ 11. 循环                                                   │
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
       流量下载信息统计
-------------------------------
 生成日期    ：YYYY-MM-DD
 生成时间    ：HH:MM:SS
 下载次数    ：N
 下载流量    ：X.XXGiB
 累计耗时    ：XXmin XXs
===============================
```

### data/console.log

```
[HH:MM:SS]  Traffic Keeper 容器启动中...
[HH:MM:SS]  curl 已就绪，跳过软件包安装
[HH:MM:SS]  正在重新抓取可用下载链接...
[HH:MM:SS]  抓取完成，共 2082 条链接，耗时 1m57s
[HH:MM:SS]  有效链接数：331
[HH:MM:SS]  链接检测耗时：00:05:32
[HH:MM:SS]  本轮可用链接数：10
[HH:MM:SS]  开始新一轮下载任务（共 3 次）
[HH:MM:SS]  [1/3] 下载中...
[HH:MM:SS]     URL: https://...
[HH:MM:SS]     开始下载...
[HH:MM:SS]     下载完成：1.50GiB / 耗时 120s
...
```

## 使用方法

### 快速开始

```bash
cd /vol2/1000/Docker/traffic-keeper
chmod +x *.sh
./install-traffic-keeper-fnos.sh
```

安装完成后，浏览器访问：

```
http://<NAS_IP>:8080
```

安装脚本会自动探测您的 NAS IP 并输出访问地址。

### 目录结构要求

推荐将项目文件放到 `/vol2/1000/Docker/traffic-keeper` 目录（或任意目录），然后执行安装脚本。

### 目录不存在时

```bash
# 创建目录并进入
mkdir -p /vol2/1000/Docker/traffic-keeper
cd /vol2/1000/Docker/traffic-keeper

# 从 GitHub 克隆项目文件
git clone https://github.com/w5456448820/nas-traffic-keeper.git .

# 执行安装
chmod +x *.sh
./install-traffic-keeper-fnos.sh
```

## 常用命令

### 查看 Web 管理界面

```
http://<NAS_IP>:8080
```

### 查看容器状态

```bash
docker ps | grep traffic-keeper
```

### 查看容器日志（Docker 标准输出）

```bash
docker logs -f traffic-keeper
```

### 查看终端日志（Web 实时日志源）

```bash
tail -f /vol2/1000/Docker/traffic-keeper/data/console.log
```

### 停止服务

```bash
cd /vol2/1000/Docker/traffic-keeper
docker compose down
```

### 重启服务

```bash
cd /vol2/1000/Docker/traffic-keeper
docker compose down
docker compose up -d
```

### 强制重新抓取链接

```bash
rm -f /vol2/1000/Docker/traffic-keeper/data/links/.last-fetch
```

### 进入容器（调试）

```bash
docker exec -it traffic-keeper /bin/sh
```

### 重新拉取最新代码

```bash
cd /vol2/1000/Docker/traffic-keeper
git pull
docker compose down
docker compose up -d
```

## 注意事项

- 本脚本仅适合在你拥有管理权限的 NAS 和网络环境中使用
- 请合理设置限速、休眠时间和每日流量上限，避免影响正常网络使用
- `.env` 文件包含敏感配置，请妥善保管不要泄露
- Web 管理界面默认绑定 `0.0.0.0:8080`，在内网中可直接访问
- 如需限制 Web 管理界面访问，请通过飞牛 NAS 的防火墙或路由器 ACL 进行控制
- `.env` 中时间字段支持 `s/m/h` 单位（如 `15m`、`1h`），数据字段支持 `K/M/G/T` 单位（如 `1G`、`500M`），纯数字分别默认秒和字节
- 日志文件 `console.log` 超过 2MB 时自动截断保留最新 500 行
- 链接文件存储在 `data/links/` 目录下，包含 `fetched-links.txt`、`validated_urls.list`、`.last-fetch`、`.last-check` 等

## 版本历史

| 版本 | 更新内容 |
|------|----------|
| 2.9.2 | 修复 busybox `awk printf "%d"` 对超过 2^31 的大数溢出为负数，导致 `MAX_DAILY_BYTES`（如 200G）解析失败、单日下载限额完全失效；修复 GitHub Release URL 提取后通过 `while read` 循环写入临时文件时数据丢失（改用 `tee -a` 管道直接写入）；GitHub Release 链接在 `validate_link()` 和下载前检查中跳过 HEAD 大小检测（GitHub CDN 对大文件返回假 Content-Length: 9）；移除无 `browser_download_url` 的仓库（nodejs/node、rust-lang/rust、tensorflow/tensorflow）和已 404 的 Ubuntu 24.04 镜像源 |
| 2.9.1 | 修复 `should_fetch_links()` 中硬编码旧路径 `/app/links/fetched-links.txt` 导致每次循环都重新抓取链接的问题（链接目录已迁移到 `/app/data/links/`）；Web 界面重构：新增"抓取链接"和"配置下载源"独立页签，下载链接输入改为按行分隔；统一所有模块版本号为 2.9.1 |
| 2.9.0 | 支持可选单位格式（时间 s/m/h，数据 K/M/G/T）；新增 `LINK_CHECK_INTERVAL` 链接检测间隔，避免每轮重复检测所有链接；去除 `DYNAMIC_SLEEP_MIN_BYTES` 动态休眠最小下载量阈值；修复 `set -e` 与函数内 `[ condition ] && action` 组合导致 `apply_defaults()` 异常退出的问题；Web 界面新增链接抓取时间、抓取链接数、可用链接数、检测时间统计展示；统一所有模块版本号为 2.9.0 |
| 2.8.0 | 修复 Web 界面配置保存失败（webserver.py `quoted_keys` 变量未定义导致 `NameError`）；修复 fetch-links.sh 子进程无法继承父进程环境变量导致 `FETCH_MIN_FILE_BYTES` 配置不生效；修复 fetch-links.sh 中 sed BRE 语法不兼容 busybox（`\|`、`\+` 在 Alpine 下报错）；安装脚本版本号与各模块版本号统一为 2.8.0 |
| 2.7.4 | 统一 GB/Bytes 单位换算规则（traffic-keeper.sh、fetch-links.sh、webserver.py 三方一致）；修复 TiB 换算除数错误（1024³ → 1024⁴）；fetch-links.sh 独立维护单位转换函数；install-traffic-keeper-fnos.sh 自动检测并修复旧配置字节单位错误；webserver.py 历史数据 GB/MB/KB 单位换算修复 |
| 2.7.3 | Web 界面顶部统计按日期倒序取最新文件（解决统计数据不刷新）；安装脚本缺失文件时自动从 GitHub 下载；.env 写入放弃原子替换避免 Docker volume 文件锁 Resource busy 错误；安装脚本支持飞牛 NAS 目录已有文件的一键安装；新增 stats_show 中文格式文件回退解析 |
| 2.7.2 | Web 界面统计数据按日期倒序取最新文件；新增 stats_show 文件回退支持；安装脚本缺失文件自动从 GitHub 下载 |
| 2.7.1 | 新增 Web 管理界面（端口 8080），支持通过 Web 界面配置所有参数、实时查看终端日志；修复安装脚本在目标目录运行时的 cp 自复制问题；修复 apk 安装失败导致容器死循环重启的问题（三镜像源容错+超时机制）；修复 .env 多行格式导致 docker compose 解析失败的问题 |
| 2.7.0 | 重构项目结构，新增 entrypoint.sh、webserver.py、docker-compose.yml；支持 Docker 容器化部署；新增链接抓取脚本 fetch-links.sh |
| 2.6.16 | 修复 curl 请求跟随重定向(-L)，解决阿里云镜像 302 下载失败；增加更多国内镜像源；修复 docker-compose.yml YAML 层级错误；使用 $RANDOM 替代 od+mod 方案提高随机数质量 |
