#!/bin/bash

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEVICE_REGISTRY="${LIB_DIR}/device_registry.sh"

. "$DEVICE_REGISTRY"

# 统一 overlay 名称格式，避免 workflow / 本地脚本因大小写或空格产生重复项。
normalize_overlay_name() {
	local overlay_name=${1:-}

	printf '%s' "$overlay_name" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# 根据标准目录规则定位 overlay 文件，供导出脚本和 workflow 复用同一套解析方式。
resolve_overlay_file() {
	local config_root=$1
	local overlay_name=$2

	printf '%s/overlays/%s.txt\n' "$config_root" "$(printf '%s' "$overlay_name" | tr '[:upper:]' '[:lower:]')"
}

# 读取 overlay 的互斥组；同组 overlay 在归一化时只保留最后出现的一项。
read_overlay_group() {
	local overlay_file=$1
	local overlay_group

	overlay_group=$(sed -n 's/^#[[:space:]]*OVERLAY_GROUP[[:space:]]*=[[:space:]]*\([^[:space:]]\{1,\}\)[[:space:]]*$/\1/p' "$overlay_file" | sed -n '1p')
	printf '%s' "$overlay_group" | tr '[:upper:]' '[:lower:]'
}

# 归一化 overlay 列表并处理同组覆盖，确保自动补全和手动输入最终只保留一份生效结果。
normalize_overlay_list() {
	local config_root=$1
	local overlay_csv=${2:-}
	local old_ifs overlay_name overlay_file overlay_group existing_name existing_group joined_list
	local i
	local -a normalized_names=()
	local -a normalized_groups=()
	local -a kept_names=()
	local -a kept_groups=()

	[ -n "$overlay_csv" ] || {
		printf '\n'
		return 0
	}

	old_ifs=$IFS
	IFS=','
	set -- $overlay_csv
	IFS=$old_ifs

	for overlay_name in "$@"; do
		overlay_name=$(normalize_overlay_name "$overlay_name")
		[ -n "$overlay_name" ] || continue

		overlay_file=$(resolve_overlay_file "$config_root" "$overlay_name")
		if [ ! -f "$overlay_file" ]; then
			echo "缺少 overlay 配置：$overlay_file" >&2
			return 1
		fi

		overlay_group=$(read_overlay_group "$overlay_file")
		if [ -n "$overlay_group" ]; then
			kept_names=()
			kept_groups=()
			i=0
			if [ ${#normalized_names[@]} -gt 0 ]; then
				for existing_name in "${normalized_names[@]}"; do
					existing_group=${normalized_groups[$i]}
					if [ "$existing_group" != "$overlay_group" ]; then
						kept_names+=("$existing_name")
						kept_groups+=("$existing_group")
					fi
					i=$((i + 1))
				done
			fi
			if [ ${#kept_names[@]} -gt 0 ]; then
				normalized_names=("${kept_names[@]}")
				normalized_groups=("${kept_groups[@]}")
			else
				normalized_names=()
				normalized_groups=()
			fi
		fi

		normalized_names+=("$overlay_name")
		normalized_groups+=("$overlay_group")
	done

	joined_list=''
	if [ ${#normalized_names[@]} -gt 0 ]; then
		for overlay_name in "${normalized_names[@]}"; do
			if [ -n "$joined_list" ]; then
				joined_list="${joined_list},${overlay_name}"
			else
				joined_list=$overlay_name
			fi
		done
	fi

	printf '%s\n' "$joined_list"
}

# 根据逻辑设备名自动补全默认 overlay，例如 *-nowifi 自动追加 nowifi-ipq60xx。
infer_default_overlays_for_device() {
	local config_root=$1
	local device_name=${2:-}
	local fw_name=${3:-}
	local overlay_name

	overlay_name=$(default_nowifi_overlay_for_device "$device_name")
	printf '%s\n' "$overlay_name"
}

# 合并自动推导和手动传入的 overlay，再统一走互斥组去重逻辑。
merge_overlay_csv_lists() {
	local config_root=$1
	local auto_csv=${2:-}
	local manual_csv=${3:-}
	local merged_csv=''

	if [ -n "$auto_csv" ] && [ -n "$manual_csv" ]; then
		merged_csv="${auto_csv},${manual_csv}"
	elif [ -n "$auto_csv" ]; then
		merged_csv=$auto_csv
	else
		merged_csv=$manual_csv
	fi

	normalize_overlay_list "$config_root" "$merged_csv"
}
