# Traffic Keeper for 飞牛 NAS (FnOS)

Traffic Keeper 是一款专为飞牛 NAS 设计的流量保活工具，自动下载大文件以维持网络活跃。

## 功能特性

- 自动下载大文件维持网络流量活跃
- 支持可选时间/数据单位 (h/m/s, T/G/M/K)
- 自适应多下载源（GitHub、镜像站）
- 实时流量统计面板
- 飞牛 NAS 原生 FPK 应用包

## 安装方法

### 方式一：通过 FPK 包安装（推荐）

1. 下载最新 FPK 安装包：[`dist/traffic-keeper-v2.9.3.fpk`](dist/traffic-keeper-v2.9.3.fpk)
2. 登录飞牛 NAS 管理后台，进入「应用中心」
3. 点击「手动安装」，选择下载的 `.fpk` 文件
4. 安装完成后在应用中心点击「打开」即可使用

### 方式二：从源码构建

需要在飞牛 NAS 上安装 `fnpack` 工具：

```bash
git clone https://github.com/w5456448820/fnos-traffic-keeper.git
cd fnos-traffic-keeper
bash build.sh
```

构建完成后，`.fpk` 文件将生成在 `dist/` 目录中。

## 项目结构

```
.
├── app/
│   ├── server/           # 应用服务脚本
│   │   ├── traffic-keeper.sh   # 主运行脚本
│   │   ├── fetch-links.sh      # 链接获取脚本
│   │   └── webserver.py        # Web 服务
│   └── ui/               # 桌面入口配置
│       ├── config        # 应用中心打开按钮配置
│       └── images/       # 应用图标
│           ├── icon_64.png
│           └── icon_256.png
├── cmd/                  # 生命周期回调
│   ├── main              # 启动/停止入口
│   ├── install_callback
│   ├── install_init
│   ├── uninstall_callback
│   ├── uninstall_init
│   ├── upgrade_callback
│   ├── upgrade_init
│   ├── config_callback
│   └── config_init
├── config/               # 应用配置
│   ├── privilege         # 权限配置
│   └── resource          # 资源配置
├── manifest              # 应用清单
├── ICON.PNG              # 应用图标 (64x64)
├── ICON_256.PNG          # 应用图标 (256x256)
├── build.sh              # FPK 构建脚本
└── README.md
```

## 飞牛应用架构说明

本项目严格遵循飞牛 NAS 第三方应用 (FPK) 开发规范：

- **`app/server/`** — 应用主程序文件，安装后部署到 `/vol2/@appcenter/traffic-keeper/server/`
- **`app/ui/`** — 桌面入口配置，安装后部署到 `/vol2/@appcenter/traffic-keeper/ui/`，用于应用中心显示「打开」按钮
- **`cmd/main`** — 应用启动/停止入口，由系统调用管理生命周期
- **`cmd/*_callback`** — 安装/卸载/升级/配置的生命周期回调
- **`config/privilege`** — 定义应用运行用户和权限
- **`manifest`** — 应用元数据，包含桌面入口配置 (`desktop_uidir`, `desktop_applaunchname`)

## 版本历史

| 版本 | 日期 | 更新内容 |
|------|------|----------|
| v2.9.3 | 2026-07-14 | 修复 FPK 应用中心「打开」按钮问题；完善 app/ui/ 目录结构 |
| v2.9.2 | - | 初始 FPK 版本 |

## 开源协议

MIT License
