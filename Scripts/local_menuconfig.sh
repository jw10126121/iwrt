#!/bin/bash

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
SCRIPT_ROOT="${REPO_ROOT}/Scripts"
CONFIG_ROOT="${REPO_ROOT}/Config"
OVERLAY_UTILS="${SCRIPT_ROOT}/lib/overlay_utils.sh"
SOURCE_TYPE_LIB="${SCRIPT_ROOT}/lib/source_type.sh"
LOCAL_COMPAT_DIR=''

show_help() {
	cat <<'EOF'
用法：
  直接通过环境变量传参后执行脚本，例如：

  WRT_DEVICE=cmiot-ax18-nowifi \
  WRT_FRP_MODE=frps \
  WRT_USB_MODE=usb \
  WRT_PACKAGE_MANAGER=ipk \
  bash Scripts/local_menuconfig.sh

主要参数（尽量对齐 DEFAULT.yml）：
  OPENWRT_PATH           本地 OpenWrt 源码目录，默认 /Volumes/OpenWrt/lede
  WRT_DEVICE             设备名，必填，例如 cmiot-ax18-nowifi、jd-ax1800pro-wifi
  WRT_FIREWALL           防火墙栈，默认 auto；支持 auto、fw3、fw4
  WRT_FRP_MODE           FRP 模式，默认 none；支持 frpc、frps、frp、none
  WRT_USB_MODE           USB 模式，默认 default；支持 default、usb、nousb
  WRT_PACKAGE_MANAGER    包管理器，默认 auto；支持 auto、apk、ipk
  WRT_OVERLAYS           可选 overlays，逗号分隔，例如 lucky
                         同一 OVERLAY_GROUP 内按传入顺序以最后一个为准
  WRT_LUCI_BRANCH        可选 LuCI 分支，例如 openwrt-23.05
  WRT_DIY_SETTING        自定义设置脚本，默认 diy_config.sh
  WRT_DIYPackages        自定义包脚本，默认 Packages.sh
  WRT_DIY_FEEDS          自定义 feeds 脚本，默认 diy_feeds.sh
  WRT_DEFAULT_LANIP      默认 LAN IP，默认 192.168.0.1
  WRT_SOURCE_HASH_INFO   可选源码 commit hash
  SOURCE_TYPE            源码类型，默认 auto；支持 lean、vwrt、libwrt

本地辅助参数：
  WRT_THEME_NAME         默认 auto（lean 使用 argon，其它源码使用 aurora）
  IS_RESET_PASSWORD      默认 true
  LOCAL_SKIP_MENUCONFIG  true 时跳过 make menuconfig，默认 false
EOF
}

# 本地 menuconfig 会改写临时文件，先校验关键脚本存在，避免运行到一半才发现入口缺失。
require_file() {
	local file_path=$1

	[ -f "$file_path" ] || {
		echo "缺少文件：$file_path" >&2
		exit 1
	}
}

# 与 require_file 配套，提前校验源码目录和配置目录是否齐备。
require_dir() {
	local dir_path=$1

	[ -d "$dir_path" ] || {
		echo "缺少目录：$dir_path" >&2
		exit 1
	}
}

cleanup() {
	if [ -n "$LOCAL_COMPAT_DIR" ] && [ -d "$LOCAL_COMPAT_DIR" ]; then
		rm -rf "$LOCAL_COMPAT_DIR"
	fi
}

# macOS 自带 sed 的 -i 参数与 GNU sed 不兼容，这里用临时 shim 统一本地 menuconfig 体验。
setup_local_compat_bin() {
	LOCAL_COMPAT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/local-menuconfig.XXXXXX")
	trap cleanup EXIT

	cat > "${LOCAL_COMPAT_DIR}/sed" <<'EOF'
#!/bin/bash
set -eu

if [ $# -ge 1 ] && [ "$1" = "-i" ]; then
	shift
	exec /usr/bin/sed -i "" "$@"
fi

exec /usr/bin/sed "$@"
EOF
	chmod +x "${LOCAL_COMPAT_DIR}/sed"
	PATH="${LOCAL_COMPAT_DIR}:$PATH"
	export PATH
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	show_help
	exit 0
fi

OPENWRT_PATH=${OPENWRT_PATH:-/Volumes/OpenWrt/lede}
WRT_DEVICE=${WRT_DEVICE:-}
WRT_FIREWALL=${WRT_FIREWALL:-auto}
WRT_OVERLAYS=${WRT_OVERLAYS:-}
WRT_FRP_MODE=${WRT_FRP_MODE:-none}
WRT_USB_MODE=${WRT_USB_MODE:-default}
WRT_PACKAGE_MANAGER=${WRT_PACKAGE_MANAGER:-auto}
WRT_LUCI_BRANCH=${WRT_LUCI_BRANCH:-}
WRT_DIY_SETTING=${WRT_DIY_SETTING:-diy_config.sh}
WRT_DIYPackages=${WRT_DIYPackages:-auto}
WRT_DIY_FEEDS=${WRT_DIY_FEEDS:-diy_feeds.sh}
WRT_DEFAULT_LANIP=${WRT_DEFAULT_LANIP:-192.168.0.1}
WRT_SOURCE_HASH_INFO=${WRT_SOURCE_HASH_INFO:-}
WRT_THEME_NAME=${WRT_THEME_NAME:-auto}
IS_RESET_PASSWORD=${IS_RESET_PASSWORD:-true}
LOCAL_SKIP_MENUCONFIG=${LOCAL_SKIP_MENUCONFIG:-false}
LOCAL_CLEAN_GENERATED=${LOCAL_CLEAN_GENERATED:-true}

# 将设备名转换为小写
WRT_DEVICE="${WRT_DEVICE,,}"

[ -n "$WRT_DEVICE" ] || {
	echo "缺少 WRT_DEVICE，例如 cmiot-ax18-nowifi" >&2
	exit 1
}

case "$WRT_FIREWALL" in
	auto|fw3|fw4)
		;;
	*)
		echo "WRT_FIREWALL 只支持 auto、fw3 或 fw4" >&2
		exit 1
		;;
esac

require_dir "$OPENWRT_PATH"
require_dir "$CONFIG_ROOT"
require_file "$SCRIPT_ROOT/$WRT_DIY_FEEDS"
require_file "$SCRIPT_ROOT/$WRT_DIY_SETTING"
require_file "$SCRIPT_ROOT/export_config.sh"
require_file "$SCRIPT_ROOT/resolve_device_script.sh"
require_file "$SCRIPT_ROOT/diy_after_defconfig.sh"
require_file "$OVERLAY_UTILS"
require_file "$SOURCE_TYPE_LIB"

. "$OVERLAY_UTILS"
. "$SOURCE_TYPE_LIB"

WRT_CONFIG_LABEL="${WRT_DEVICE}-${WRT_FIREWALL}"

export OPENWRT_PATH
export WRT_LUCI_BRANCH

setup_local_compat_bin

cd "$OPENWRT_PATH"

require_dir .git
require_file ./scripts/feeds
require_file ./scripts/diffconfig.sh
require_file ./Makefile

SOURCE_TYPE=$(resolve_source_type "${SOURCE_TYPE:-auto}" "$OPENWRT_PATH")
SOURCE_CONFIG_FAMILY=$(source_config_family "$SOURCE_TYPE")
export SOURCE_TYPE
echo "【Lin】源码类型：$SOURCE_TYPE"
echo "【Lin】配置族：$SOURCE_CONFIG_FAMILY"

if [ "$WRT_FIREWALL" = "auto" ]; then
	if [ "$SOURCE_CONFIG_FAMILY" = "lean" ]; then
		WRT_FIREWALL="fw3"
	else
		WRT_FIREWALL="fw4"
	fi
elif [ "$SOURCE_CONFIG_FAMILY" = "iwrt" ] && [ "$WRT_FIREWALL" = "fw3" ]; then
	echo "【Lin】警告：${SOURCE_TYPE} 使用 iwrt 配置族，已将 fw3 自动切换为 fw4"
	WRT_FIREWALL="fw4"
fi

auto_overlays=$(infer_default_overlays_for_device "$CONFIG_ROOT" "$WRT_DEVICE" "$WRT_FIREWALL")
manual_overlays=${WRT_OVERLAYS:-}
frp_overlays=''
usb_overlays=''
combined_overlays=''

case "$WRT_FRP_MODE" in
	frpc|frps|frp)
		frp_overlays="$WRT_FRP_MODE"
		;;
esac

case "$WRT_USB_MODE" in
	usb|nousb)
		usb_overlays="$WRT_USB_MODE"
		;;
esac

combined_overlays="$frp_overlays"
if [ -n "$usb_overlays" ]; then
	if [ -n "$combined_overlays" ]; then
		combined_overlays="${combined_overlays},${usb_overlays}"
	else
		combined_overlays="$usb_overlays"
	fi
fi
if [ -n "$manual_overlays" ]; then
	if [ -n "$combined_overlays" ]; then
		combined_overlays="${combined_overlays},${manual_overlays}"
	else
		combined_overlays="$manual_overlays"
	fi
fi

WRT_OVERLAYS=$(merge_overlay_csv_lists "$CONFIG_ROOT" "$auto_overlays" "$combined_overlays")

package_manager="$WRT_PACKAGE_MANAGER"
if [ "$package_manager" = "auto" ]; then
	if [ "$SOURCE_TYPE" = "vwrt" ]; then
		package_manager=apk
	else
		package_manager=ipk
	fi
fi

if [ "$LOCAL_CLEAN_GENERATED" = 'true' ]; then
	echo "【Lin】清理本地生成物，避免旧缓存污染 feeds / defconfig"
	rm -rf ./staging_dir ./tmp ./logs ./package/feeds ./bin ./build_dir ./toolchain ./feeds
	rm -f ./.config ./.config.old
	mkdir -p ./feeds
	rm -f ./scripts/config/conf ./scripts/config/*.o
fi

echo "【Lin】本地 menuconfig 入口"
echo "【Lin】源码目录：$OPENWRT_PATH"
echo "【Lin】设备：$WRT_DEVICE"
echo "【Lin】防火墙：$WRT_FIREWALL"
echo "【Lin】FRP 模式：$WRT_FRP_MODE"
echo "【Lin】USB 模式：$WRT_USB_MODE"
echo "【Lin】包管理器：$package_manager"
echo "【Lin】overlays：${WRT_OVERLAYS:-无}"
echo "【Lin】LuCI 分支：${WRT_LUCI_BRANCH:-源码默认}"

if [ -n "${WRT_SOURCE_HASH_INFO}" ]; then
	echo "【Lin】检出指定源码提交：${WRT_SOURCE_HASH_INFO}"
	git fetch --depth=1 origin "${WRT_SOURCE_HASH_INFO}"
	git checkout "${WRT_SOURCE_HASH_INFO}"
fi

echo "【Lin】执行 feeds 定制"
bash "$SCRIPT_ROOT/$WRT_DIY_FEEDS"

echo "【Lin】更新并安装 feeds"
perl ./scripts/feeds update -a
perl ./scripts/feeds install -a

echo "【Lin】执行自定义包脚本：$WRT_DIYPackages"
cd ./package
WRT_RESOLVED_DIY_PACKAGES=$(
	bash "$SCRIPT_ROOT/resolve_device_script.sh" \
		"$SCRIPT_ROOT" \
		"$WRT_DIYPackages" \
		"$WRT_DEVICE"
)
require_file "$SCRIPT_ROOT/$WRT_RESOLVED_DIY_PACKAGES"
echo "【Lin】实际自定义包脚本：$WRT_RESOLVED_DIY_PACKAGES"
bash "$SCRIPT_ROOT/$WRT_RESOLVED_DIY_PACKAGES"
cd "$OPENWRT_PATH"

echo "【Lin】导出参数化配置"
rm -f .config
EXPORT_ARGS=(
	--config-dir "$CONFIG_ROOT"
	--device "$WRT_DEVICE"
	--fw "$WRT_FIREWALL"
	--output ".config"
)
if [ -n "$WRT_OVERLAYS" ]; then
	EXPORT_ARGS+=(--overlay "$WRT_OVERLAYS")
fi
bash "$SCRIPT_ROOT/export_config.sh" "${EXPORT_ARGS[@]}"

echo "【Lin】加载自定义系统设置"
bash "$SCRIPT_ROOT/$WRT_DIY_SETTING" \
	-n "Linjw" \
	-i "$WRT_DEFAULT_LANIP" \
	-p "$IS_RESET_PASSWORD" \
	-t "$WRT_THEME_NAME" \
	-m "$package_manager" \
	-c "$WRT_CONFIG_LABEL"

echo "【Lin】首次 defconfig"
make defconfig

echo "【Lin】执行 defconfig 后修正"
bash "$SCRIPT_ROOT/diy_after_defconfig.sh"

if [ "$LOCAL_SKIP_MENUCONFIG" != 'true' ]; then
	echo "【Lin】进入 menuconfig"
	make menuconfig
else
	echo "【Lin】按要求跳过 menuconfig"
fi

echo "【Lin】刷新 defconfig 并导出 seed.config"
make defconfig
bash ./scripts/diffconfig.sh > seed.config
echo "【Lin】已生成：$OPENWRT_PATH/seed.config"
