# iwrt

`iwrt` 是基于 ImmortalWrt 与 LiBwrt/LibWrt 的 OpenWrt 固件构建仓库，通过 GitHub Actions 为多种设备生成固件。所有构建统一使用 **fw4（nftables）** 和 **APK**。

## 支持的源码

| `SOURCE_TYPE` | 上游源码 | 用途 |
|---|---|---|
| `vwrt` | [VIKINGYFY/immortalwrt](https://github.com/VIKINGYFY/immortalwrt) 或官方 ImmortalWrt | 默认源码；高通设备使用 VIKINGYFY 源，其他设备使用官方源 |
| `libwrt` | [LiBwrt/LibWrt](https://github.com/LiBwrt/LibWrt) | 高通设备的 NSS 源码 |

Lean 源码、fw3 防火墙和 IPK 包格式已不再支持。手动构建入口为 `.github/workflows/DEFAULT.yml`，设备配置位于 `Config/`，构建脚本位于 `Scripts/`。

## 构建

在 GitHub Actions 手动运行 `DEFAULT`，选择设备与源码类型。防火墙和包管理器固定为 fw4/APK。可用参数包括 FRP、USB、overlays、临时附加包、LuCI 分支和默认 LAN 地址。

设备配置由 `Config/*-fw4-iwrt.txt` 与 `Config/general-iwrt.txt` 合并。`Config/overlays/` 中的配置按设备和构建选项叠加。

## APK 软件源

软件源自动收集最终 `.config` 中所有 `CONFIG_PACKAGE_*=m` 的包；将包配置为 `=m` 即可纳入软件源，`=y` 的固件内置包不会重复收集。成功构建后，Actions 会单独上传 `<构建名>-apk-feed` artifact，其中包含用户态 APK 索引和对应 target 的内核模块索引；内核模块目录同时带有 `vermagic`。

固件使用工作流输入 `WRT_FEED_HOST` 指定的 APK 软件源主机域名。构建成功后，Actions 会把对应源码短哈希目录自动部署到 Cloudflare Pages 的同名项目分支，并同时上传 `<构建名>-apk-feed` artifact。仓库需配置 `CLOUDFLARE_ACCOUNT_ID` 与 `CLOUDFLARE_API_TOKEN` 两项 Actions secrets；缺少任一项时会跳过 Pages 发布并在日志中说明。

```text
https://<源码短哈希>.<软件源域名>/packages/<架构>/packages.adb
https://<源码短哈希>.<软件源域名>/kmods/<子目标>/packages.adb
```

自动部署后，应能通过 `<源码短哈希>.<软件源域名>` 访问这些路径。未修改 `WRT_FEED_HOST` 时，固件会使用工作流默认主机域名写入这两条自定义源。

设备启动后可执行：

```sh
apk update
apk add <软件包名>
```

软件源与固件必须来自同一源码提交、相同 target/subtarget 和内核 ABI。更换固件后应使用对应构建的源目录。

## GitHub Actions 工作流

- `DEFAULT.yml`：单设备手动构建入口。
- `CUSTOM-iwrt.yml`、`CUSTOM-iwrt-all.yml`：批量构建 ImmortalWrt/LibWrt 设备。
- `CORE-ALL.yml`：通用克隆、配置、编译、整理和上传逻辑。
- `ForCache.yml`：定时预热构建缓存。

所有 workflow 注释、README 和脚本提示以简体中文维护。构建产物会分别上传固件、分类 APK 包和可选 APK 软件源。
