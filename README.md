# Traffic Keeper

飞牛 NAS / FnOS 流量平衡脚本，支持**本地管理界面**（浏览器配置 + 实时日志查看）和 Docker 容器化部署。

通过定时下载公开大文件来生成网络流量，并记录每日下载次数、流量和耗时统计。

## 功能

### 核心能力
- **固定安装目录**：`/vol2/1000/Docker/traffic-keeper`
- **下载限速**：支持 K/M/G 格式，0 或留空表示不限速
- **随机休眠**：每轮任务在设定范围内随机休眠，避免固定周期被识别
- **动态休眠**：单次下载量较小时自动缩短休眠时间
- **每日流量上限**：达到设定值后自动暂停，次日重置
- **链接抓取**：自动从 GitHub Release 和国内镜像站抓取大文件链接
- **文件大小过滤**：根据 Content-Length/Content-Range 过滤小文件
- **统计持久化**：每日数据保存到 `data/` 和 `流量统计/`

### Web 管理界面（v2.7.0+）
- **浏览器配置**：通过 `http://<NAS_IP>:8080` 图形化配置所有参数
- **实时日志**：Web 界面实时显示 traffic-keeper.sh 的终端输出（Server-Sent Events）
- **配置热生效**：保存配置后下一轮任务循环自动加载，无需重启容器
- **统计面板**：顶部卡片实时展示今日下载次数、流量、累计耗时

### 一键部署
- `install-traffic-keeper-fnos.sh` 自动完成所有部署步骤
- 自动检查并修复 Alpine 软件源（三镜像源容错）
- 自动检测 Docker 环境（`docker compose` / `docker-compose`）
- 自动生成 `.env` 配置文件（保留用户自定义配置）
- 首次运行自动拉取 `python:3.12-alpine` 镜像

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
│   └── console.log                  # 主脚本终端日志（Web 实时读取）
├── 流量统计/                        # 显示用统计数据
│   └── stats_show_YYYY-MM-DD.log    # 每日格式化统计
└── links/                           # 抓取链接目录
    ├── fetched-links.txt             # 校验通过的可用链接
    └── .last-fetch                  # 上次抓取时间戳
```

## 核心模块职责

### 1. 一键安装脚本 (install-traffic-keeper-fnos.sh)

**职责**：一键部署整个 Traffic Keeper 系统

**功能**：
- 配置所有脚本的可执行权限
- 检查必需文件是否齐全（5 个核心文件）
- 若 `.env` 不存在或缺少关键字段，自动生成默认配置
- 自动检测 `docker compose` 或 `docker-compose` 命令
- 清理旧容器，拉取最新镜像，启动新容器
- 输出 NAS 实际 IP 和访问地址

### 2. 主运行脚本 (traffic-keeper.sh)

**职责**：核心流量生成逻辑，控制下载循环

**主要功能**：
- Alpine 软件源多镜像容错（阿里云/清华/官方，超时控制）
- 环境变量加载与合法性校验
- 下载链接验证（Content-Length/Content-Range）
- 流量统计记录（次数、字节数、耗时）
- 动态/固定休眠控制
- 每日流量上限控制
- 日期切换自动重置统计
- 抓取链接循环使用 + 兜底 `.env` 备用链接

### 3. 链接抓取脚本 (fetch-links.sh)

**职责**：从多个来源抓取可用的大文件下载链接

**数据来源**：
- GitHub API（curl, jq, nodejs releases）
- 国内镜像站（清华大学镜像源、阿里云镜像源等）

**输出**：`./links/fetched-links.txt`（一行一个校验通过的 URL）

### 4. Web 服务器 (webserver.py)

**职责**：提供管理界面（HTML + API）

**实现**：纯 Python 标准库（`http.server`, `socketserver`, `json`, `threading`），无需任何第三方依赖

**API 端点**：

| 端点 | 方法 | 说明 |
|------|------|------|
| `/` | GET | 管理界面 HTML 页面 |
| `/api/config` | GET | 读取当前 `.env` 配置 |
| `/api/config` | POST | 保存配置到 `.env` |
| `/api/stats` | GET | 读取今日统计数据 |
| `/api/logs` | GET | 获取历史日志（最新 2000 行） |
| `/api/logs/stream` | GET | **SSE 实时日志流** |

**核心类**：

| 类/函数 | 说明 |
|---------|------|
| `Handler` | HTTP 请求处理器（GET/POST 分发） |
| `LogWatcher` | 日志文件尾行监控（inode 变更检测防截断） |
| `ThreadedServer` | 多线程 HTTPServer（支持并发访问） |
| `env_to_dict()` | 解析 `.env` 为 Python dict |
| `write_env()` | 将 dict 写回 `.env`（保留注释和格式） |
| `get_stats()` | 读取并格式化今日统计数据 |

### 5. 容器入口脚本 (entrypoint.sh)

**职责**：同时启动主脚本和 Web 服务器

**流程**：
1. 创建 `/app/data` 目录
2. 后台启动 `traffic-keeper.sh`，将输出 `tee` 到 `/app/data/console.log`
3. 日志文件超过 2MB 时自动截断保留最新 500 行
4. 前台执行 `python3 webserver.py` 启动 Web 服务

## 配置

### 方式一：Web 界面（推荐）

浏览器访问 `http://<NAS_IP>:8080`，切换到 **⚙️ 配置管理** 标签页，直接修改所有参数后点击 **💾 保存配置**。

保存后下一轮任务循环自动生效，**无需重启容器**。

### 方式二：手动编辑 .env

```bash
vi /vol2/1000/Docker/traffic-keeper/.env
```

修改后无需重启，脚本主循环下一轮自动调用 `reload_env()` 重新加载。

### 环境变量说明

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `LIMIT_RATE` | `5M` | 下载限速（K/M/G），0 或留空表示不限速 |
| `SLEEP_MIN` | `60` | 每轮任务最小休眠秒数 |
| `SLEEP_MAX` | `900` | 每轮任务最大休眠秒数 |
| `DYNAMIC_SLEEP` | `true` | 是否启用动态休眠（`true` / `false`） |
| `DYNAMIC_SLEEP_MIN_BYTES` | `1073741824` (1 GiB) | 启用动态休眠所需的单次最小下载量 |
| `RUN_TIMES_MAX` | `3` | 每轮最多执行下载次数 |
| `CONNECT_TIMEOUT` | `15` | 连接超时秒数 |
| `MAX_TIME` | `3000` | 单次下载最大时间秒数 |
| `RETRY` | `5` | curl 重试次数 |
| `RETRY_DELAY` | `5` | 重试间隔秒数 |
| `FETCH_INTERVAL` | `21600` (6小时) | 链接抓取间隔秒数 |
| `FETCH_MIN_FILE_BYTES` | `1073741824` (1 GiB) | 抓取链接的最小文件大小 |
| `USER_AGENT` | `traffic-keeper/2.7.3 curl/8.0` | User-Agent |
| `MAX_DAILY_BYTES` | `214748364800` (200 GB) | 单日最大下载量 |
| `DOWNLOAD_URLS` | （多个 ISO 链接） | 备用下载链接列表（逗号分隔） |
| `WEB_PORT` | `8080` | Web 管理界面端口 |

## 关键函数说明

### traffic-keeper.sh 核心函数

#### 工具函数

| 函数名 | 参数 | 返回值 | 说明 |
|--------|------|--------|------|
| `get_today` | - | `YYYY-MM-DD` | 获取当前日期 |
| `is_uint` | `$1` | 0/1 | 验证是否为无符号整数 |
| `human_bytes` | `$1` (字节数) | 人类可读大小 | 字节数转可读格式（如 1.5GiB） |
| `human_seconds` | `$1` (秒数) | `XXmin XXs` | 秒数转可读格式 |
| `next_wake_time` | `$1` (秒数) | `HH:MM:SS` | 计算下次唤醒时间 |
| `normalize_url` | `$1` | 规范化 URL | 去除 URL 首尾空白和特殊字符 |
| `rand_n` | `$1` (最大值) | 1~MAX 随机数 | 生成均匀分布随机数（`$RANDOM` 算法） |

#### 配置函数

| 函数名 | 说明 |
|--------|------|
| `apply_defaults` | 应用默认配置值并校验参数合法性 |
| `reload_env` | 重新加载 `.env` 配置文件，错误时保持当前配置继续运行 |

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

#### 业务函数

| 函数名 | 说明 |
|--------|------|
| `check_daily_limit` | 检查是否达到每日流量上限 |
| `calc_sleep_time` | 计算本轮休眠时间（动态模式 = 随机，固定模式 = `SLEEP_MIN`） |

### fetch-links.sh 核心函数

| 函数名 | 参数 | 返回值 | 说明 |
|--------|------|--------|------|
| `is_uint` | `$1` | 0/1 | 验证是否为无符号整数 |
| `human_bytes` | `$1` | 人类可读大小 | 字节数转可读格式 |
| `extract_content_length` | `$1` (响应头) | 文件大小 | 从 Content-Length 提取文件大小 |
| `extract_content_range_total` | `$1` (响应头) | 文件大小 | 从 Content-Range 提取文件总大小 |
| `remote_file_size_check` | `$1` (URL) | 0/1/2 | 检查远端文件大小是否达标 |
| `append_if_large_enough` | `$1` (URL) | - | 检查并追加达标链接到输出文件 |

### webserver.py 核心函数/类

| 类/函数 | 说明 |
|---------|------|
| `Handler.do_GET` | 分发 GET 请求（HTML 页面 + 4 个 API） |
| `Handler.do_POST` | 处理配置保存请求 |
| `LogWatcher` | 日志文件监控（防截断 inode 检测） |
| `ThreadedServer` | 多线程 HTTP 服务器 |
| `env_to_dict()` | 解析 `.env` 为 Python dict（处理引号） |
| `write_env()` | 将 dict 写回 `.env`（保留注释格式） |
| `get_stats()` | 读取并格式化今日统计数据 |

## 依赖关系

### 容器镜像

- **基础镜像**：`python:3.12-alpine`（Python 3.12 + Alpine Linux）
- **重启策略**：`always`（容器退出后自动重启）

### Alpine 软件源

容器启动时自动修复软件源，依次尝试：

1. `https://mirrors.aliyun.com/alpine/v{VER}/...`
2. `https://mirrors.tuna.tsinghua.edu.cn/alpine/v{VER}/...`
3. `http://dl-cdn.alpinelinux.org/alpine/v{VER}/...`

每个镜像最多等待 60 秒（`apk update`）+ 120 秒（`apk add`），失败自动尝试下一个。

> **重要**：若所有镜像均不可达，脚本继续运行（curl 失败会跳过下载，不阻塞容器）。

### 下载来源

1. **GitHub Releases**（通过 fetch-links.sh 抓取）：curl, jq, nodejs
2. **国内镜像站**：
   - 清华大学镜像源 (`mirrors.tuna.tsinghua.edu.cn`)
   - 阿里云镜像源 (`mirrors.aliyun.com`)
   - 官方镜像源 (`releases.ubuntu.com`, `cdn.kernel.org` 等)

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
      - ./data:/app/data                                 # 数据目录（读写）
      - ./流量统计:/app/流量统计                          # 显示统计（读写）
      - links:/app/links                                 # 抓取链接（持久化）
      - /etc/localtime:/etc/localtime:ro                # 时区同步
    ports:
      - "8080:8080"                                      # Web 管理界面
    tmpfs:
      - /tmp                                            # 临时文件系统
    command: ["/bin/sh", "/app/entrypoint.sh"]          # 入口脚本
```

### 日志配置

```yaml
logging:
  driver: json-file
  options:
    max-size: 2m      # 单个日志文件最大 2MB
    max-file: 3       # 最多保留 3 个轮转文件
```

## 主循环流程

```
┌─────────────────────────────────────────────────────────────┐
│                    entrypoint.sh                             │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  后台: traffic-keeper.sh (tee → console.log)           │ │
│  └────────────────────────────────────────────────────────┘ │
│  前台: python3 webserver.py (端口 8080)                     │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│              traffic-keeper.sh 主循环 (while true)          │
├─────────────────────────────────────────────────────────────┤
│  1. reload_env()       - 重新加载 .env 配置                 │
│  2. fetch_links()      - 检查是否到达抓取间隔，到达则执行   │
│  3. 选择下载来源       - 优先抓取链接，失败用 DOWNLOAD_URLS │
│  4. validate_data_file - 检查统计文件有效性（日期切换重置） │
│  5. check_daily_limit  - 检查是否达到日流量上限             │
│  6. 执行下载循环 (1~RUN_TIMES_MAX 次)                      │
│     ├── 随机选择链接（避免重复）                            │
│     ├── HEAD 请求验证文件大小                               │
│     ├── curl 下载（限速 + 超时 + 重试）                     │
│     ├── update_stats() 更新统计                             │
│     └── 检查日流量上限                                      │
│  7. 生成统计显示文件                                        │
│  8. calc_sleep_time() - 计算休眠时间                       │
│  9. sleep 休眠                                              │
│  10. 循环                                                   │
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

### data/console.log

```
[HH:MM:SS] 🐳 Traffic Keeper 容器启动中...
[HH:MM:SS] ✅ curl 已就绪，跳过软件包安装
[HH:MM:SS] 🔄 正在重新抓取可用下载链接...
[HH:MM:SS] ✅ 本轮可用链接数：10
[HH:MM:SS] 🚀 开始新一轮下载任务（共 3 次）
[HH:MM:SS] ➤ [1/3] 下载中...
[HH:MM:SS]    URL: https://...
[HH:MM:SS]    ⬇️  开始下载...
[HH:MM:SS]    ✅ 下载完成：1.50GiB / 耗时 120s
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

# 从 GitHub 克隆项目文件（使用您自己的仓库地址）
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
rm -f /vol2/1000/Docker/traffic-keeper/links/.last-fetch
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

## 版本历史

| 版本 | 更新内容 |
|------|----------|
| 2.7.3 | Web 界面顶部统计按日期倒序取最新文件（解决统计数据不刷新）；安装脚本缺失文件时自动从 GitHub 下载；.env 写入放弃原子替换避免 Docker volume 文件锁 Resource busy 错误；安装脚本支持飞牛 NAS 目录已有文件的一键安装；新增 stats_show 中文格式文件回退解析 |
| 2.7.2 | Web 界面统计数据按日期倒序取最新文件；新增 stats_show 文件回退支持；安装脚本缺失文件自动从 GitHub 下载 |
| 2.7.1 | 新增 Web 管理界面（端口 8080），支持通过 Web 界面配置所有参数、实时查看终端日志；修复安装脚本在目标目录运行时的 cp 自复制问题；修复 apk 安装失败导致容器死循环重启的问题（三镜像源容错+超时机制）；修复 .env 多行格式导致 docker compose 解析失败的问题 |
| 2.7.0 | 重构项目结构，新增 entrypoint.sh、webserver.py、docker-compose.yml；支持 Docker 容器化部署；新增链接抓取脚本 fetch-links.sh |
| 2.6.16 | 修复 curl 请求跟随重定向(-L)，解决阿里云镜像 302 下载失败；增加更多国内镜像源；修复 docker-compose.yml YAML 层级错误；使用 $RANDOM 替代 od+mod 方案提高随机数质量 |
