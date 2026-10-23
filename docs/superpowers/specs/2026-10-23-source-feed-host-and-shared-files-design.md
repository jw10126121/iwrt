# 工作流统一整理固件与发布 APK 软件源设计

## 目标

2026-10-23 用户补充确认：启用一次 CUSTOM 工作流，不论内部有多少 CORE、多少源码和平台，只部署一个 Pages 项目。汇总这次编译所有设备的 `=m` 包、递归依赖和实际编译的内核包，所有固件使用同一个站点中与自身兼容的目录。

2026-10-23 用户进一步明确：一个 CUSTOM YAML 就是一个工作流，可以编译一个或多个型号。固件按型号整理，插件包按平台汇总，软件源归属于这个工作流；最终整理和发布均由入口统一组织，不放在 CORE 中。

此要求替代本文原先“按源码类型分别选择三个 Pages 主机”的提案。工作流继续保留 `WRT_FEED_HOST`，默认 `lin-iwrt.pages.dev`，不按源码自动切换部署项目。直接修改 iwrt 的 main，不创建分支、不推送；OpenWrt-Actions 只作参考。

## 行为设计

- CORE 只编译和交付 `<构建名>-build-output` 原始产物（保留 1 天）：firmware.tar 保存原始固件与配置，build.json 保存构建元数据，feed/ 保存软件源、离线包和 host apk 工具；不生成最终固件目录、不上传最终固件 Artifact、不发布 Release、不部署 Pages。
- CUSTOM 和 DEFAULT 在所有 CORE 成功后调用一次 PUBLISH-OUTPUTS；该任务完整下载各设备原始 artifact 一次，校验运行 ID、重跑次数和产物数量，按型号整理固件，按平台合并插件并生成软件源。最终上传 firmware 与 apk-packages 两份 Artifact，再执行一次 Pages 部署，并按需发布机型固件 Release。
- firmware 内按 `<设备型号>/<构建名>/` 保存镜像、配置和说明；Release 沿用构建名前缀作为标签，只包含该机型的固件与配置说明。无论是否开启 Release，都不再生成机型专属 Packages ZIP。
- apk-packages 内按源码、源码短 hash、target/subtarget、架构生成平台 ZIP。同平台多个机型合并，ZIP 包含本次所有 =y、=m、依赖与内核包；feed/ 保存可发布的模块包、递归依赖、全部已编译 kmod 及索引，offline/ 保存其他内置包及 CF 超限包。重复包只保留一份；关闭 CF 域名仍汇总归档。
- 大小 >=25 MiB 的 APK 只排除 CF 文件及索引，归档完整保留，生成 excluded-packages.json 清单；其他包正常发布。
- 每次编译共用 `build-<run_id>-<run_attempt>` 部署分支，固件 URL 固定指向本次分支，避免后续编译覆盖其他运行的源。
- 用户态源目录为 `<最终源码类型>/<源码短哈希>/packages/<target>/<subtarget>/<架构>/`。相同源码、平台和架构共用包并集；即使 CPU 架构名称相同，不同源码的库也不混用。
- 内核模块目录为 `<最终源码类型>/<源码短哈希>/kmods/<target>/<subtarget>/<最终配置摘要>/`。固件打包前保存配置摘要，收集时复用并记录实际 vermagic，防止不同设备配置的内核模块混用。
- 不直接覆盖各设备旧的 packages.adb，而使用构建树导出的 host apk 为合并后的包并集重建索引。
- 同目录同名包内容冲突、同类型源码提交不一致、内核 ABI 不匹配或产物缺失时停止发布，避免部署不完整站点。缺少 Cloudflare 凭据时保留 firmware 和完整平台包归档，并提示跳过部署。

## 文件职责与范围

- `Scripts/apk_feed.sh`：收集包、配置固件 URL、输出软件源 manifest。
- `Scripts/collect_apk_packages.py`：读取真实索引元数据，收集模块与内核包的依赖闭包，其他已编译包保留离线。
- `Scripts/bundle_apk_tool.sh`：导出 host apk 及动态运行库，不将工具部署到 Pages。
- `Scripts/merge_apk_feeds.py`：校验 manifest、合并包、检测冲突、重建索引并生成站点首页。
- `Scripts/ci_build_outputs.py`：CORE 原始产物封装、入口侧校验与恢复、按机型整理及 Release 发布。
- `Scripts/ci_organize_outputs.sh`：由发布任务生成固件说明、导出配置和重命名镜像，不分类或压缩插件包。
- `.github/workflows/PUBLISH-OUTPUTS.yml`：下载本工作流产物，统一整理固件和插件，上传最终 Artifact、单次部署软件源并按需发布固件。
- CUSTOM 和 DEFAULT：列出编译依赖以及预期构建产物数量；增减设备时同步修改发布任务。
- `Scripts/tests/` 和 `README.md`：覆盖行为、解释路径和运行限制，保留现有配置和脚本入口。

## 验证

运行离线软件源收集与合并测试、工作流依赖测试、APK/fw4 回归检查、Bash 语法检查和 Actions 静态检查。核心场景为四份产物混合 IPQ/MTK、两种源码和不同内核配置，合并成一个站点并为同源同平台同架构的插件生成并集索引。完整固件与 Cloudflare 发布需要 GitHub Actions 实跑，本地离线结果不代表在线部署成功。

## 非目标

- 不创建、修改或在线部署用户的 Cloudflare 项目和凭据。
- 不改动与软件源汇总发布无关的设备、插件和固件功能。
- 不推送远端，不变更 OpenWrt-Actions 仓库。
