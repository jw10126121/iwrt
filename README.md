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

CUSTOM 和 DEFAULT 在全部编译任务成功后，统一调用一次 `PUBLISH-OUTPUTS.yml`。发布任务把各设备 feed 中间包合并并重建索引，只部署一次 Pages；另把平台 APK 包单独整理为 Release/Artifact 下载归档。各 CORE 已上传的固件信息包直接作为逐设备 Artifact，PUBLISH 不重复上传汇总固件 Artifact。Pages feed 和下载归档是两个独立输出。

固件在 `firmware/<设备型号>/<构建名>/` 下保存镜像、配置和说明，WiFi/无 WiFi 及其他构建变体分别保留。启用 `WRT_RELEASE_FIRMWARE` 时，由同一发布任务按构建名发布各机型 Release；Release 仅包含固件与配置说明，插件包统一从平台归档下载，不再为机型重复生成 Packages ZIP。

软件源自动收集每台设备最终 `.config` 中所有 `CONFIG_PACKAGE_*=m` 的包、递归依赖（即使依赖是 `=y`），以及本次实际编译生成的全部 `kmod-*` 包及其依赖。其他实际编译的内置包只留在短期内部中间产物中，不进入最终 `apk-packages` 或 Release。

`apk-packages` 汇总 Artifact（由 `WRT_UPLOAD_PACKAGES_ARTIFACT` 控制）内部按「源码 + 源码短 hash + target/subtarget + 架构」保存平台 ZIP，例如 `libwrt-abc1234-qualcommax-ipq60xx-aarch64_cortex-a53-packages.zip`。同源同平台多个机型的插件包合并为一份，IPQ60xx 与 Filogic（MT6000）各有自己的归档。同平台同插件不同版本全部保留；同版本的重复文件名只留按构建 artifact 名排序后的首份。平台 ZIP 由 `ci_organize_apk_packages.py` 从合并后的 feed 包另行整理，面向下载保存，和 Pages 的 feed 目录分开。

下载 ZIP 内，用户态 APK 位于 `packages/<架构>/`，内核 APK 和 `vermagic` 位于 `kmods/<kernel_id>/`，另含 `平台信息.json`、`说明.txt`、`excluded-packages.json`。该 ZIP 不含软件源索引，不能作为设备 feed 直接使用；设备在线安装使用 Pages 发布目录。ZIP 同样不包含 `offline/` 包。

Pages 项目由入口的 `WRT_FEED_HOST` 指定，默认是 `lin-iwrt.pages.dev`。即使同次编译同时包含 LibWrt/VIKINGYFY 的 IPQ 设备与官方 ImmortalWrt 的 MTK 设备，仍然发布到这同一个项目；源码类型、源码提交、target/subtarget 和软件包架构在站点内部用目录区分。同源码、同平台、同架构的设备共用用户态软件包并集，不为每个机型创建独立用户态源。内核模块另按 target/subtarget 和最终配置摘要隔离，并记录实际 `vermagic`，避免 WiFi/无 WiFi 等配置的内核模块互相覆盖。

每次运行使用独立的 `build-<run_id>-<run_attempt>` Pages 预览分支；固件写入该分支域名以及自己对应的源码、架构和内核目录，因此后续其他编译不会把旧固件的源切换成新一批包。仓库需配置 `CLOUDFLARE_ACCOUNT_ID` 与 `CLOUDFLARE_API_TOKEN` 两项 Actions secrets；缺少凭据时仍生成完整的 `apk-packages` artifact，但跳过在线部署，设备端源在完成部署后才可使用。

```text
https://build-<run_id>-<run_attempt>.<软件源域名>/<源码类型>/<源码短哈希>/packages/<target>/<subtarget>/<架构>/packages.adb
https://build-<run_id>-<run_attempt>.<软件源域名>/<源码类型>/<源码短哈希>/kmods/<target>/<subtarget>/<配置摘要>/packages.adb
```

`WRT_FEED_HOST` 使用 `<项目名>.pages.dev` 格式，该 Pages 项目必须事先创建，且应允许 `build-*` 预览分支。保留默认值时，只需要准备 `lin-iwrt` 项目。留空则不写入固件自定义源，也不部署站点，但仍汇总并保存 `apk-packages`。

合并时检查产物数量、发布标识、同类源码的提交以及内核 ABI。同路径相同包名和版本按稳定顺序保留一份；不同版本使用不同文件名并一起进入索引。为保证本次站点完整，任何设备失败都会阻止统一发布；重跑时请选择整个工作流，避免混入不同 `run_attempt` 的固件地址。构建用 host apk 及其运行库只包含在短期中间 artifact 中，不会保存到最终归档或部署到站点。APK 大小达到或超过 25 MiB（26,214,400 字节）时会从 feed 和索引中排除，并记录清单；由于其不在 `apk-packages` 中，超限包需自行从构建产物外获取。依赖缺失或版本不兼容会明确报错，不会静默生成缺依赖的软件源。

`WRT_RELEASE_FIRMWARE` 控制是否发布逐设备固件 Release；`WRT_RELEASE_PACKAGES` 独立控制是否创建一个 `apk-packages-build-<run_id>-<run_attempt>` Release，里面是本次各平台下载 ZIP。`WRT_UPLOAD_PACKAGES_ARTIFACT` 控制是否保存汇总的 `apk-packages` Artifact。CORE 的逐设备固件信息包作为 `<构建名>-firmware` Artifact 直接上传；PUBLISH 下载它们用于可选的逐设备 Release，不再创建重复的汇总 `firmware` Artifact。固件 Release 只包含对应设备的固件、配置和说明；插件包 Release 只包含单独整理的按平台 ZIP。

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

所有 workflow 注释、README 和脚本提示以简体中文维护。最终 Artifacts 包括各 CORE 上传的 `<构建名>-firmware` 单设备包，以及可选的一份 `apk-packages` 汇总 Artifact（内含带源码短 hash 的各平台 ZIP）。

## 本地验证

```sh
bash Scripts/tests/test_apk_feed.sh
bash Scripts/tests/test_apk_fw4_only.sh
python3 -m pip install -r Scripts/tests/requirements.txt
python3 -m unittest discover -s Scripts/tests -p 'test_*.py' -v
actionlint -shellcheck= .github/workflows/*.yml
```

这些验证覆盖离线收集、合并、URL 和工作流依赖；完整固件编译及在线部署仍需要在 GitHub Actions 实跑。
