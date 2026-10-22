#!/bin/bash

# 统一维护逻辑设备名、展示别名和自动 overlay 的映射，避免多个脚本各写一套判断。

# 归一化设备名输入，统一为小写并去掉首尾空白，避免 workflow 参数格式不一致。
normalize_device_name() {
	printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# 从逻辑设备名中剥离 -wifi / -nowifi 后缀，得到机型基础名，供映射和推导复用。
device_base_name_from_logical_name() {
	local normalized_name

	normalized_name=$(normalize_device_name "${1:-}")
	case "${normalized_name}" in
		*-wifi)
			printf '%s\n' "${normalized_name%-wifi}"
			;;
		*-nowifi)
			printf '%s\n' "${normalized_name%-nowifi}"
			;;
		*)
			printf '%s\n' "${normalized_name}"
			;;
	esac
}

# 将 OpenWrt profile 名映射为仓库内更易读的展示别名，主要用于 metadata 和日志输出。
device_alias_from_profile_name() {
	local profile_name=$1

	case "${profile_name}" in
		jdcloud_re-ss-01|jdcloud_ax1800pro)
			printf '%s\n' 'jd_ax1800pro'
			;;
		jdcloud_re-cs-02)
			printf '%s\n' 'jd_ax6600'
			;;
		glinet_gl-mt6000)
			printf '%s\n' 'mt6000'
			;;
		*)
			printf '%s\n' "${profile_name}"
			;;
	esac
}

# 将仓库内逻辑设备名映射为统一别名，保证 workflow、metadata 与输出前缀可读且稳定。
device_alias_from_logical_name() {
	local logical_name

	logical_name=$(normalize_device_name "${1:-}")
	[ -n "${logical_name}" ] || {
		printf '\n'
		return 0
	}

	case "${logical_name}" in
		cmiot-ax18|cmiot-ax18-wifi)
			printf '%s\n' 'cmiot_ax18'
			;;
		cmiot-ax18-nowifi)
			printf '%s\n' 'cmiot_ax18_nowifi'
			;;
		jd-ax1800pro|jd-ax1800pro-wifi)
			printf '%s\n' 'jd_ax1800pro'
			;;
		jd-ax1800pro-nowifi)
			printf '%s\n' 'jd_ax1800pro_nowifi'
			;;
		jd-ax6600|jd-ax6600-wifi)
			printf '%s\n' 'jd_ax6600'
			;;
		jd-ax6600-nowifi)
			printf '%s\n' 'jd_ax6600_nowifi'
			;;
		gl-mt6000|gl-mt6000-wifi)
			printf '%s\n' 'mt6000'
			;;
		gl-mt6000-nowifi)
			printf '%s\n' 'mt6000_nowifi'
			;;
		*)
			printf '%s\n' "$(printf '%s' "${logical_name}" | tr '-' '_')"
			;;
	esac
}

# 为 *-nowifi 设备推导默认 overlay，集中维护“哪个机型使用哪个 nowifi 配置”的规则。
default_nowifi_overlay_for_device() {
	local normalized_name
	local base_name

	normalized_name=$(normalize_device_name "${1:-}")
	case "${normalized_name}" in
		*-nowifi)
			;;
		*)
			printf '\n'
			return 0
			;;
	esac

	base_name=$(device_base_name_from_logical_name "${1:-}")
	case "${base_name}" in
		cmiot-ax18|jd-ax1800pro|jd-ax6600)
			printf '%s\n' 'nowifi-ipq60xx'
			;;
		gl-mt6000)
			printf '%s\n' 'nowifi-filogic'
			;;
		*)
			printf '\n'
			;;
	esac
}
