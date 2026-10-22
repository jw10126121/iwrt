# VWrt — OpenWrt 云编译仓库

基于 [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede)（Lean源码）、[VIKINGYFY/immortalwrt](https://github.com/VIKINGYFY/immortalwrt)（VIKINGYFY源码）和 [LiBwrt/LibWrt](https://github.com/LiBwrt/LibWrt)（LibWrt源码）的 OpenWrt 云编译仓库，通过 GitHub Actions 自动构建多设备、多防火墙栈的固件。

## 目录

- [VWrt — OpenWrt 云编译仓库](#vwrt--openwrt-云编译仓库)
  - [目录](#目录)
  - [固件风味](#固件风味)
  - [支持设备](#支持设备)
  - [CI 工作流](#ci-工作流)
    - [预设工作流](#预设工作流)
    - [DEFAULT 工作流参数](#default-工作流参数)
  - [配置组织](#配置组织)
    - [主维护配置文件](#主维护配置文件)
  - [Overlay 系统](#overlay-系统)
    - [内置 Overlay](#内置-overlay)
    - [自定义 Overlay](#自定义-overlay)
  - [固件默认值](#固件默认值)
  - [下载固件](#下载固件)
  - [刷机说明](#刷机说明)
  - [致谢](#致谢)

## 固件风味

| 风味 | 源码 | 分支 | 防火墙 | 说明 |
|------|------|------|--------|------|
| **LWRT** | [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede) | `master` | fw3 | Lean源码，兼容性好 |
| **IWRT** | [VIKINGYFY/immortalwrt](https://github.com/VIKINGYFY/immortalwrt) | `main` / `owrt` | fw4 (nftables) | VIKINGYFY源码，功能更新 |
| **LIBWRT** | [LiBwrt/LibWrt](https://github.com/LiBwrt/LibWrt) | `25.12-nss` | fw4 (nftables) | LibWrt源码，功能丰富 |

**IWRT 分支说明：** GL-MT6000-WIFI 使用 `owrt` 分支，其余设备使用 `main` 分支。

**源码选择机制：** `vwrt` 在高通设备上使用 VIKINGYFY 的 immortalwrt；`libwrt` 在高通设备上使用 `LiBwrt/LibWrt` 的 `25.12-nss` 分支。两者在 MT6000 等非高通设备上均使用官方 `immortalwrt/immortalwrt` 的 `master` 分支。

三种风味共用同一套设备配置和构建脚本，通过 `SOURCE_TYPE`（`lean` / `vwrt` / `libwrt`）和 `WRT_FIREWALL` 参数区分。`vwrt` 与 `libwrt` 都属于 iwrt 配置族，默认使用 fw4；`lean` 默认使用 fw3。

## 支持设备

| 设备 | 架构 | 备注 |
|------|------|------|
| `CMIOT-AX18-NOWIFI` | qualcommax-ipq60xx / aarch64 | 默认无 Wi-Fi |
| `JD-AX1800PRO-WIFI` | qualcommax-ipq60xx / aarch64 | 京东云亚瑟，带 Wi-Fi |
| `JD-AX1800PRO-NOWIFI` | qualcommax-ipq60xx / aarch64 | 京东云亚瑟，无 Wi-Fi |
| `JD-AX6600-WIFI` | qualcommax-ipq60xx / aarch64 | 京东云雅典娜，带 Wi-Fi |
| `GL-MT6000-WIFI` | mediatek-filogic / aarch64 | GL.iNet MT6000，带 Wi-Fi |

如需调整具体机型勾选项，修改对应配置文件中的 `CONFIG_TARGET_DEVICE_*`。

## CI 工作流

[![CUSTOM-LWRT](https://github.com/jw10126121/VWrt/actions/workflows/CUSTOM-LWRT.yml/badge.svg)](https://github.com/jw10126121/VWrt/actions/workflows/CUSTOM-LWRT.yml)
[![CUSTOM-IWRT](https://github.com/jw10126121/VWrt/actions/workflows/CUSTOM-iwrt.yml/badge.svg)](https://github.com/jw10126121/VWrt/actions/workflows/CUSTOM-iwrt.yml)
[![DEFAULT](https://github.com/jw10126121/VWrt/actions/workflows/DEFAULT.yml/badge.svg)](https://github.com/jw10126121/VWrt/actions/workflows/DEFAULT.yml)

### 预设工作流

| 工作流 | 触发方式 | 说明 |
|--------|----------|------|
| **CUSTOM-LWRT** | 定时（每月 2、16 日 03:00 UTC）/ 手动 | 批量构建 fw3 风味的全部设备 |
| **CUSTOM-IWRT** | 定时（每月 1、15 日 03:00 UTC）/ 手动 | 批量构建 fw4 风味的全部设备 |
| **CUSTOM-IWRT-ALL** | 手动 | 四设备批量构建，可选择 `vwrt` / `libwrt`；MT6000 均使用官方 ImmortalWrt |
| **DEFAULT** | 手动触发 | 单设备自定义构建，灵活选择参数 |

`CUSTOM-IWRT-ALL` 包含 AX18 无 Wi-Fi + frps、MT6000 有/无 Wi-Fi、AX6600 有 Wi-Fi，四个任务统一使用外部选择的 `SOURCE_TYPE`。该选项控制高通设备使用 VIKINGYFY 的 immortalwrt（`vwrt`）或 LibWrt `25.12-nss`（`libwrt`）；MT6000 的两种配置始终使用官方 ImmortalWrt `master`。批量入口保持 fw4、APK。源码 HASH 留空时跟随各设备实际源码分支的最新提交；批量任务涉及不同仓库，填写 HASH 时须确保提交适用于全部设备。设备配置、插件脚本、LAN IP 和发布选项保持一致。

### DEFAULT 工作流参数

手动运行 `DEFAULT` 时，可输入以下参数：

| 参数 | 说明 | 示例 |
|------|------|------|
| `WRT_DEVICE` | 设备型号 | `CMIOT-AX18-NOWIFI` |
| `SOURCE_TYPE` | 源码类型 | `lean` / `vwrt` / `libwrt` |
| `WRT_FIREWALL` | 防火墙栈 | `fw3` / `fw4` |
| `WRT_FRP_MODE` | FRP 模式 | `frpc` / `frps` / `frp` / `none` |
| `WRT_USB_MODE` | USB 模式 | `default` / `usb` / `nousb` |
| `WRT_PACKAGE_MANAGER` | 包管理器 overlay | `auto` / `apk` / `ipk` |
| `WRT_OVERLAYS` | 高级兜底差异层，逗号分隔 | `frps,apk` |
| `WRT_LUCI_BRANCH` | LuCI feed 分支 | `openwrt-23.05` |
| `WRT_DIYPackages` | 包脚本选择 | `auto`（默认）/ `Packages.sh` |
| `WRT_SOURCE_HASH_INFO` | 固定 git 提交 | commit hash |

**参数说明：**

- `WRT_LUCI_BRANCH` 留空时使用源码默认 LuCI feed
- `WRT_DIYPackages` 默认 `auto`：优先使用 `Scripts/Packages-<设备名>.sh` 或短名脚本；填 `Packages.sh` 可强制使用通用包脚本
- `WRT_FRP_MODE` 默认 `frpc`；`frp` 表示同时启用 `frpc` 与 `frps`，日常切换不再需要手输 overlay
- `WRT_USB_MODE` 默认 `default`，表示保持设备主配置中的 USB 能力；选 `usb/nousb` 时才额外叠加 overlay
- `WRT_PACKAGE_MANAGER` 默认 `auto`，表示沿用源码默认包管理器；选 `apk/ipk` 时会直接传给构建主流程，不再重复追加到 `WRT_OVERLAYS`
- `WRT_OVERLAYS` 仍保留，作为自定义 overlay 的高级兜底输入；它会追加在结构化选项之后
- overlay 文件可用 `# OVERLAY_GROUP=<组名>` 声明互斥组；同组内按 `WRT_OVERLAYS` 顺序以最后一个为准
- `WRT_SOURCE_HASH_INFO` 留空时使用所选源码分支的最新提交；填写时会在克隆后检出该提交。批量构建涉及不同源码仓库，固定 HASH 时需确保该提交适用于各设备。

**构建缓存：** 工具链缓存按构建环境、仓库/分支、完整源码提交、最终 `.config` 和构建脚本指纹严格匹配，仅在固件编译成功后保存。恢复后仍由 OpenWrt 检查依赖，不保证跳过工具链重建。ccache 按构建环境、仓库/分支及目标平台隔离，在该范围内通过 ccache 自身校验跨提交复用，每次运行保存新键。缓存不包含源码和 feeds；v2 缓存键会自动隔离旧记录，首次构建工具链可能耗时较长。

## 配置组织

配置按以下顺序叠加（后面的覆盖前面的同名项）：

```
Config/GENERAL-<设备名>.txt    # 设备专用通用配置（若不存在则用 GENERAL.txt）
Config/<设备名>-<FW>.txt       # 设备 + 防火墙栈专属配置
Config/device-overlays/<设备名>-<FW>.txt  # 设备差异层（若存在）
Config/overlays/<overlay>.txt  # 自定义差异层（按 WRT_OVERLAYS 顺序叠加）
```

### 主维护配置文件

| 设备 | fw3 配置 | fw4 配置 |
|------|----------|----------|
| CMIOT-AX18 | `Config/cmiot-ax18-wifi-fw3.txt` | `Config/cmiot-ax18-wifi-fw4-iwrt.txt` |
| JD-AX1800PRO | `Config/jd-ax1800pro-wifi-fw3.txt` | `Config/jd-ax1800pro-wifi-fw4-iwrt.txt` |
| GL-MT6000-WIFI | `Config/gl-mt6000-wifi-fw3.txt` | `Config/gl-mt6000-wifi-fw4-iwrt.txt` |
| JD-AX6600-WIFI | `Config/jd-ax6600-wifi-fw3.txt` | `Config/jd-ax6600-wifi-fw4-iwrt.txt` |

`*-nowifi` 构建目标会自动复用对应 `*-wifi` 主配置，并追加 `nowifi-*` overlay。

## Overlay 系统

Overlay 用于在不修改设备主配置的前提下叠加功能差异。

### 内置 Overlay

| Overlay | 说明 |
|---------|------|
| `apk` | APK 包管理器 |
| `ipk` | IPK 包管理器（默认） |
| `frpc` | FRP 内网穿透客户端 |
| `frps` | FRP 内网穿透服务端 |
| `frp` | 同时启用 FRP 客户端与服务端 |
| `usb` | USB 支持 |
| `nousb` | 移除 USB 支持 |
| `nowifi-ipq60xx` | IPQ60XX 设备移除 Wi-Fi |

### 自定义 Overlay

1. 在 `Config/overlays/` 下创建 `.txt` 文件，例如 `Config/overlays/myvpn.txt`
2. 使用时在 `WRT_OVERLAYS` 中填入文件名（不含扩展名），例如 `WRT_OVERLAYS=myvpn`
3. 后面的 overlay 会覆盖前面的同名配置
4. 可通过 `# OVERLAY_GROUP=<组名>` 声明互斥组，同组只保留最后出现的 overlay

## 固件默认值

| 项目 | 默认值 |
|------|--------|
| 主题 | Argon |
| LAN IP | `192.168.0.1` |
| 用户名 | `root` |
| 密码 | 空密码 |

## 下载固件

- **发布页**：[VWrt Releases](https://github.com/jw10126121/VWrt/releases)
- **上游源码**：[coolsnowwolf/lede](https://github.com/coolsnowwolf/lede)（Lean）| [VIKINGYFY/immortalwrt](https://github.com/VIKINGYFY/immortalwrt)（VIKINGYFY）| [LiBwrt/LibWrt](https://github.com/LiBwrt/LibWrt)（LibWrt）

## 刷机说明

适用于当前 lean 固件：

| 刷机方式 | 固件文件 | 说明 |
|----------|----------|------|
| U-Boot 恢复 | `squashfs-recovery.bin` | 适用于 Hugo U-Boot + 原厂 CDT + 双分区 GPT |
| LuCI 在线升级 | `squashfs-sysupgrade.bin` | 在 LuCI 系统升级页面上传 |

---

> ⚠️ 本仓库仅供学习与交流使用，请自行评估刷机风险并遵守相关法律法规。

## 致谢

- [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede) — Lean大佬的 OpenWrt 源码
- [VIKINGYFY/immortalwrt](https://github.com/VIKINGYFY/immortalwrt) — VIKINGYFY大佬的 ImmortalWrt 源码
- [LiBwrt/LibWrt](https://github.com/LiBwrt/LibWrt) — LibWrt大佬的 OpenWrt 源码
- [OpenWrt](https://github.com/openwrt/openwrt) — OpenWrt 官方项目
- 感谢所有上游贡献者和社区用户的支持与反馈
- 本项目大部分功能由AI实现
