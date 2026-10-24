# iwrt

`iwrt` 是基于 ImmortalWrt 与 LiBwrt/LibWrt 的 OpenWrt 固件构建仓库，通过 GitHub Actions 为多种设备生成固件。所有构建统一使用 **fw4（nftables）** 和 **APK**。

## 支持的源码

| `SOURCE_TYPE` | 上游源码 | 用途 |
|---|---|---|
| `VIKINGYFY` | [VIKINGYFY/immortalwrt](https://github.com/VIKINGYFY/immortalwrt) | 高通设备的 VIKINGYFY ImmortalWrt fork |
| `libwrt` | [LiBwrt/LibWrt](https://github.com/LiBwrt/LibWrt) | 高通设备的 NSS 源码 |

手动选择只提供 `VIKINGYFY` 和 `libwrt`。非 IPQ 设备（例如 MT6000）会自动使用 [官方 ImmortalWrt](https://github.com/immortalwrt/immortalwrt)，内部源码风味记为 `immortalwrt`；旧调用传入的 `vwrt` 仍保留兼容处理。

Lean 源码、fw3 防火墙和 IPK 包格式已不再支持。手动构建入口为 `.github/workflows/DEFAULT.yml`，设备配置位于 `Config/`，构建脚本位于 `Scripts/`。

## 构建

在 GitHub Actions 手动运行 `DEFAULT`，选择设备与源码类型。防火墙和包管理器固定为 fw4/APK。可用参数包括 FRP、USB、overlays、临时附加包、LuCI 分支和默认 LAN 地址。

设备配置由 `Config/*-fw4-iwrt.txt` 与 `Config/general-iwrt.txt` 合并。`Config/overlays/` 中的配置按设备和构建选项叠加。

## APK 软件源

一个 CUSTOM YAML 入口代表一个工作流，可以编译一个或多个设备。`CORE-ALL.yml` 是单设备子任务，完成编译后上传 `<构建名>-firmware` 单固件信息 ZIP（固件、配置、说明等）以及短期 `<构建名>-feed` 中间 artifact（为 Pages feed 提供该设备的 APK 和索引）。CORE 不负责合并软件源或发布 Release。

CUSTOM 和 DEFAULT 在全部编译任务成功后，统一调用一次 `PUBLISH-OUTPUTS.yml`。发布任务把各设备 feed 中间包合并并重建索引，只部署一次 Pages；同时按平台整理固件 ZIP 和 APK 插件 ZIP。启用 Release 时，两类 ZIP 按平台成对作为同一个 run 级 Release 的附件。各 CORE 已上传的单设备固件信息包仍作为内部 Artifact，Pages feed 和 Release 下载包是独立输出。

固件在 `firmware/<设备型号>/<构建名>/` 下保存镜像、配置和说明，WiFi/无 WiFi 及其他构建变体分别保留。Release 固件 ZIP 按源码版本、target/subtarget 和架构合并同平台设备，ZIP 内以 `devices/<构建前缀>/` 分别保存固件、配置和说明。

软件源自动收集每台设备最终 `.config` 中所有 `CONFIG_PACKAGE_*=m` 的包、递归依赖（即使依赖是 `=y`），以及本次实际编译生成的全部 `kmod-*` 包及其依赖。其他实际编译的内置包只留在短期内部中间产物中，不进入最终 `apk-packages` 或 Release。

`apk-packages` 汇总 Artifact（由 `WRT_UPLOAD_PACKAGES_ARTIFACT` 控制）内部按「源码 + 源码短 hash + target/subtarget + 架构」分目录，例如 `libwrt-abc1234-qualcommax-ipq60xx-aarch64_cortex-a53-plugins/`。每个平台目录直接包含用户态 APK、`kmods/`、平台信息、Pages 超限包清单和说明，不包含软件源索引或嵌套的 `*-plugins.zip`。下载 Artifact 并解压一层后，就能直接看到每个平台整理好的文件。同源同平台多个机型的插件包合并为一份，IPQ60xx 与 Filogic（MT6000）各有自己的目录。同平台同插件不同版本全部保留；同版本的重复文件名只留按构建 artifact 名排序后的首份。Artifact 文件由 `ci_organize_apk_packages.py` 从独立的完整 APK 包池整理，面向下载保存，和 Pages 的 feed 目录分开。

这些手工插件目录只出现在 `apk-packages` Artifact 和 Release ZIP 中，不会写入 Pages 软件源。Pages feed 按源码、target/subtarget 和架构分别保留 APK 仓库目录，包文件与 `packages.adb` 索引位于同一层，供固件的软件源配置在线安装。

下载归档还会参照 `Scripts/Organize_Packages.sh`，为每个 `luci-app-*` 和 `luci-theme-*` 建同名子目录。脚本读取 APK 控制信息并递归收集可分发的运行依赖，也会放入对应 `luci-i18n-*-zh-cn`（如果 feed 中有）。复制插件目录到路由器后，可用 `apk add /路径/luci-app-socat/*.apk` 一起安装用户态包。内核模块依赖放在插件目录的 `kmods/<kernel_id>/` 下；需选择与设备当前 `kernel_id`/vermagic 匹配的目录，将其中的 `.apk` 一并传给 `apk add`。固件内置依赖由系统提供，无需重复安装。

下载 ZIP 内，用户态 APK 位于 `packages/<架构>/`，内核 APK 和 `vermagic` 位于 `kmods/<kernel_id>/`，另含 `平台信息.json`、`说明.txt`、`excluded-packages.json`。清单记录仅从 Pages feed 排除的超限 APK，这些 APK 仍包含在插件 ZIP 中。该 ZIP 不含软件源索引，不能作为设备 feed 直接使用；设备在线安装使用 Pages 发布目录。ZIP 同样不包含 `offline/` 包。

Pages 项目由入口的 `WRT_FEED_HOST` 指定，默认是 `lin-iwrt.pages.dev`。即使同次编译同时包含 LibWrt/VIKINGYFY 的 IPQ 设备与官方 ImmortalWrt 的 MTK 设备，仍然发布到这同一个项目；源码类型、源码提交、target/subtarget 和软件包架构在站点内部用目录区分。同源码、同平台、同架构的设备共用用户态软件包并集，不为每个机型创建独立用户态源。内核模块另按 target/subtarget 和最终配置摘要隔离，并记录实际 `vermagic`，避免 WiFi/无 WiFi 等配置的内核模块互相覆盖。

源码短 Hash 作为 Cloudflare Pages 预览分支名。单源码工作流部署到一个短 Hash 分支；混合源码工作流会把完整站点分别部署到涉及的每个唯一短 Hash 分支，固件只连接自己源码对应的分支。相同短 Hash 的后续运行会更新该分支，已有同 Hash 固件也会使用该分支最新的软件源。仓库需配置 `CLOUDFLARE_ACCOUNT_ID` 与 `CLOUDFLARE_API_TOKEN` 两项 Actions secrets；缺少凭据时仍生成完整的 `apk-packages` Artifact，但跳过在线部署，设备端源在完成部署后才可使用。

```text
https://<源码短哈希>.<软件源域名>/<源码类型>/<源码短哈希>/packages/<target>/<subtarget>/<架构>/packages.adb
https://<源码短哈希>.<软件源域名>/<源码类型>/<源码短哈希>/kmods/<target>/<subtarget>/<配置摘要>/packages.adb
```

`WRT_FEED_HOST` 使用 `<项目名>.pages.dev` 格式，该 Pages 项目必须事先创建，且应允许源码短 Hash 对应的预览分支。保留默认值时，只需要准备 `lin-iwrt` 项目。留空则不写入固件自定义源，也不部署站点，但仍汇总并保存 `apk-packages`。

合并时检查产物数量、源码短 Hash、同类源码的提交以及内核 ABI。同路径相同包名和版本按稳定顺序保留一份；不同版本使用不同文件名并一起进入索引。为保证本次站点完整，任何设备失败都会阻止统一发布；同一源码短 Hash 的重跑会更新对应 Pages 分支，因此该分支上的软件源也随之更新。构建用 host apk 及其运行库只包含在短期中间 artifact 中，不会保存到最终归档或部署到站点。APK 大小达到或超过 25 MiB（26,214,400 字节）时会从 Pages feed 和索引中排除并记录清单，但仍保留在独立插件包 Artifact 和 Release ZIP 中。依赖缺失或版本不兼容会明确报错，不会静默生成缺依赖的软件源。

`WRT_RELEASE_FIRMWARE` 控制是否把各平台固件 ZIP 加入 Release；`WRT_RELEASE_PACKAGES` 控制是否把各平台插件 ZIP 加入 Release。任一开关打开都会创建同一个 `build-outputs-<run_id>-<run_attempt>` Release；两者都打开时，每个平台各有一份 `*-firmware.zip` 和一份 `*-plugins.zip`。固件 ZIP 内按 `devices/<构建前缀>/` 保存平台下的设备和配置变体；插件 ZIP 含该平台可分发的用户态 APK、kmod 与 `vermagic`，不含 `packages.adb` 软件源索引或 `offline/` 包。`WRT_UPLOAD_PACKAGES_ARTIFACT` 独立控制 Actions 中的 `apk-packages` Artifact；CORE 上传的 `<构建名>-firmware` 仍是短期内部 Artifact，不单独创建逐设备 Release。

设备启动后可执行：

```sh
apk update
apk add <软件包名>
```

软件源与固件必须来自同一源码提交、相同 target/subtarget 和内核 ABI。更换固件后应使用对应构建的源目录。

## GitHub Actions 工作流

- `DEFAULT.yml`：单设备手动构建入口。
- `CUSTOM-iwrt.yml`、`CUSTOM-iwrt-all.yml`：批量构建 ImmortalWrt/LibWrt 设备。
- `CORE-ALL.yml`：单设备克隆、配置、编译并上传固件信息 ZIP 与 feed 中间产物。
- `PUBLISH-OUTPUTS.yml`：由入口统一调用，下载并整理各型号固件信息包供可选 Release，部署合并后的软件源，单独整理平台 APK 下载包并按开关保存 Artifact 或发布 Release。

所有 workflow 注释、README 和脚本提示以简体中文维护。最终 Artifacts 包括各 CORE 上传的 `<构建名>-firmware` 单设备包，以及可选的一份 `apk-packages` 汇总 Artifact（内含按源码短 hash、target/subtarget 和架构分开的整理目录，不含平台 ZIP 文件）。

## 本地验证

```sh
bash Scripts/tests/test_apk_feed.sh
bash Scripts/tests/test_apk_fw4_only.sh
python3 -m pip install -r Scripts/tests/requirements.txt
python3 -m unittest discover -s Scripts/tests -p 'test_*.py' -v
actionlint -shellcheck= .github/workflows/*.yml
```

这些验证覆盖离线收集、合并、URL 和工作流依赖；完整固件编译及在线部署仍需要在 GitHub Actions 实跑。
