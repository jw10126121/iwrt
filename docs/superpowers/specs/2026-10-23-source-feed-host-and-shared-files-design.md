# 源码默认 feed 地址与共享文件整理设计

## 目标

构建固件时不再要求用户手动传入 APK feed 主机名。系统根据最终生效的源码类型自动选择 feed 地址，并把源码类型与 feed 地址的共用映射集中维护。整理范围遵循仓库已有目录边界，不改变 GitHub Actions 工作流入口和稳定脚本路径。

## 行为设计

feed 主机名由最终源码类型决定：

| 最终源码类型 | feed 主机名 |
| --- | --- |
| `vikingyfy` | `lin-vikingyfy.pages.dev` |
| `libwrt` | `lin-libwrt.pages.dev` |
| 其他类型或未识别类型 | `lin-iwrt.pages.dev` |

工作流会因设备和仓库选择将 `SOURCE_TYPE` 回退为官方 ImmortalWrt。feed 地址必须使用这个最终类型，不能使用回退前用户选择的类型。固件仓库 URL 仍沿用现有清洗逻辑，生成 `https://<源码短哈希>.<feed主机名>/...` 格式的软件源地址。

用户不可再通过 `WRT_FEED_HOST` 覆盖默认映射。`apk_feed.sh firmware` 根据 `SOURCE_TYPE` 选择主机名；对于本地运行或缺少 `SOURCE_TYPE` 的情况，使用现有源码类型解析逻辑识别源码，不能把 feed 配置留空而静默跳过。Cloudflare Pages 项目名称也从同一映射结果导出，确保固件配置的软件源域名与部署目标一致。

## 文件职责与范围

- 在 `Scripts/lib/` 放置可复用的源码类型到 feed 主机名映射逻辑，供 `apk_feed.sh` 调用。
- Cloudflare Pages 项目解析步骤复用同一映射逻辑，按源码类型部署至匹配的 Pages 项目。
- `Scripts/apk_feed.sh` 继续作为稳定入口，负责生成软件源仓库配置并调用共享映射逻辑。
- 从 `.github/workflows/` 的手动输入、可复用工作流参数、环境变量和调用转发中移除 `WRT_FEED_HOST`，避免残留无效输入。
- 更新 `README.md`，说明地址按最终源码类型自动选择，并列出三种映射。
- 在 `Scripts/tests/` 更新软件源测试，覆盖默认类型、VIKINGYFY、LibWrt、官方 ImmortalWrt 回退及显式环境值不再作为用户接口的行为。
- 保留工作流入口路径、`Scripts/apk_feed.sh` 路径、`Config/overlays/` 结构及现有设备/源码配置文件位置。共享功能继续归入 `Scripts/lib/`，测试继续归入 `Scripts/tests/`；不进行无关的大范围搬移。

## 验证

运行 `Scripts/tests/test_apk_feed.sh` 及相关 APK 测试。用仓库搜索确认 `.github/workflows/` 不再声明或转发 `WRT_FEED_HOST`，README 不再描述用户手动设置主机名。检查 YAML 结构和改动范围，确认所有地址选择都基于最终 `SOURCE_TYPE`。

## 非目标

- 不调整 Cloudflare Pages 项目、部署凭据或发布流程。
- 不改动 feed 路径结构、源码哈希格式、包索引生成和上传方式。
- 不把设备工作流、脚本入口或配置文件批量迁移到新目录。
