#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/openwrt"
printf 'CONFIG_PACKAGE_luci-app-example=m\n' > "$TMP_ROOT/openwrt/.config"

GITHUB_ENV="$TMP_ROOT/env" \
GITHUB_OUTPUT="$TMP_ROOT/output" \
GITHUB_WORKSPACE="$ROOT_DIR" \
WRT_DIR_SCRIPTS=Scripts \
OPENWRT_PATH="$TMP_ROOT/openwrt" \
START_TIME=now \
DEVICE_SUBTARGET=filogic \
GITHUB_REPOSITORY=owner/repo \
GITHUB_RUN_ID=123 \
COMPILE_STATUS=success \
END_TIME=done \
system_content='设备说明' \
bash "$ROOT_DIR/Scripts/ci_create_notifications.sh"

grep -Fq '#### --- 安装包插件 --- ####' "$TMP_ROOT/env"
grep -Fq 'luci-app-example' "$TMP_ROOT/env"
grep -Fq '设备说明' "$TMP_ROOT/env"
grep -Fq 'luci-app-example' "$TMP_ROOT/output"
echo '【测试】编译结果通知包含最终配置中的插件列表'
