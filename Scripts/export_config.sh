#!/bin/bash

# 说明：
# 1. 导出一份可直接分享的参数化合并配置文件。
# 2. 优先加载设备专用 GENERAL-*.txt，再按需要叠加设备主配置、device-overlay 与 overlays。
# 3. overlay 支持多个同时叠加，按传入顺序覆盖。

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MERGE_SCRIPT="$SCRIPT_DIR/merge_configs.sh"
OVERLAY_UTILS="$SCRIPT_DIR/lib/overlay_utils.sh"
SOURCE_TYPE_LIB="$SCRIPT_DIR/lib/source_type.sh"

. "$OVERLAY_UTILS"
. "$SOURCE_TYPE_LIB"

config_dir='Config'
device=''
fw=''
overlay_list=''
output_config=''
cleanup_files=''
context_output=''

# 导出配置时优先复用当前源码目录判断 SOURCE_TYPE；缺少源码目录时退回 lean，保证离线导出也能工作。
resolve_export_source_type() {
	local requested_type="${SOURCE_TYPE:-lean}"

	if [ "$requested_type" = "auto" ]; then
		if [ -n "${OPENWRT_PATH:-}" ] && [ -d "${OPENWRT_PATH}" ]; then
			resolve_source_type "$requested_type" "$OPENWRT_PATH"
		else
			printf '%s\n' 'lean'
		fi
	else
		resolve_source_type "$requested_type" .
	fi
}

# 根据源码类型和 FW 栈选择设备主配置；nowifi 设备会回退到对应 wifi 主配置，再由 overlay 去掉无线能力。
resolve_device_config() {
	local config_root=$1
	local device_name=$2
	local fw_name=$3
	local source_type
	local source_family
	local fw_lower
	local device_name_lower
	source_type=$(resolve_export_source_type)
	source_family=$(source_config_family "$source_type")
	fw_lower=$(echo "$fw_name" | tr '[:upper:]' '[:lower:]')
	device_name_lower=$(echo "$device_name" | tr '[:upper:]' '[:lower:]')

	# 1. 源码类型专用配置
	#    iwrt/vwrt/libwrt → DEVICE-FW4-iwrt.txt（iwrt 配置族默认 fw4）
	#    lean → DEVICE-FW3.txt（lean 默认 fw3）
	if [ "$source_family" = "iwrt" ] || [ "$fw_lower" = "fw4" ]; then
		# iwrt 配置族优先查找 fw4-iwrt 配置，如果不存在则查找 fw3 配置
		if [ -f "$config_root/${device_name_lower}-fw4-iwrt.txt" ]; then
			printf '%s\n' "${device_name_lower}-fw4-iwrt.txt"
			return 0
		elif [ -f "$config_root/${device_name_lower}-fw3.txt" ]; then
			printf '%s\n' "${device_name_lower}-fw3.txt"
			return 0
		fi
	else
		if [ -f "$config_root/${device_name_lower}-fw3.txt" ]; then
			printf '%s\n' "${device_name_lower}-fw3.txt"
			return 0
		fi
	fi

	# 2. 兼容旧文件名（过渡期，迁移完成后可移除）
	if [ -f "$config_root/${device_name_lower}.txt" ]; then
		printf '%s\n' "${device_name_lower}.txt"
		return 0
	fi

	# 3. NOWIFI 设备回退到基础设备配置（NOWIFI 语义由 overlay 处理）
	case "$device_name_lower" in
		*-nowifi)
			local short_name=${device_name_lower%-nowifi}
			local wifi_name="${short_name}-wifi"
			if [ "$source_family" = "iwrt" ] || [ "$fw_lower" = "fw4" ]; then
				if [ -f "$config_root/${wifi_name}-fw4-iwrt.txt" ]; then
					printf '%s\n' "${wifi_name}-fw4-iwrt.txt"
					return 0
				elif [ -f "$config_root/${wifi_name}-fw3.txt" ]; then
					printf '%s\n' "${wifi_name}-fw3.txt"
					return 0
				fi
			else
				if [ -f "$config_root/${wifi_name}-fw3.txt" ]; then
					printf '%s\n' "${wifi_name}-fw3.txt"
					return 0
				fi
			fi
			if [ -f "$config_root/${wifi_name}.txt" ]; then
				printf '%s\n' "${wifi_name}.txt"
				return 0
			fi
			if [ -f "$config_root/${short_name}.txt" ]; then
				printf '%s\n' "${short_name}.txt"
				return 0
			fi
			;;
	esac

	return 1
}

# 通用配置按“设备专用 > 设备简写 > 源码类型/配置族 > 通用基线”的优先级解析。
resolve_general_configs() {
	local config_root=$1
	local device_name=$2
	local fw_name=$3
	local short_device_name=''
	local source_type
	local source_family
	local fw_lower
	local family_reason=''
	source_type=$(resolve_export_source_type)
	source_family=$(source_config_family "$source_type")
	fw_lower=$(echo "$fw_name" | tr '[:upper:]' '[:lower:]')
	if [ "$fw_lower" = "fw4" ]; then
		source_family='iwrt'
		family_reason='fw4'
	fi
	local device_name_lower
	device_name_lower=$(echo "$device_name" | tr '[:upper:]' '[:lower:]')
	local general_file='general.txt'
	local source_type_file="general-${source_type}.txt"
	local source_family_file="general-${source_family}.txt"

	# 1. 设备专用配置（最高优先）
	if [ -f "$config_root/general-${device_name_lower}.txt" ]; then
		echo "【Lin】加载通用配置：general-${device_name_lower}.txt（设备专用）" >&2
		printf '%s\n' "general-${device_name_lower}.txt"
		return 0
	fi

	case "$device_name_lower" in
		*-wifi)
			short_device_name=${device_name_lower%-wifi}
			;;
		*-nowifi)
			short_device_name=${device_name_lower%-nowifi}
			;;
	esac

	if [ -n "$short_device_name" ] && [ -f "$config_root/general-${short_device_name}.txt" ]; then
		echo "【Lin】加载通用配置：general-${short_device_name}.txt（设备简写）" >&2
		printf '%s\n' "general-${short_device_name}.txt"
		return 0
	fi

	# 2. 源码类型专用配置（独立使用，不加载通用基线）
	# iwrt/vwrt/libwrt 继承 iwrt 的配置
	if [ -f "$config_root/$source_type_file" ]; then
		echo "【Lin】加载通用配置：${source_type_file}（源码类型 ${source_type}）" >&2
		printf '%s\n' "$source_type_file"
		return 0
	elif [ "$source_family" = "iwrt" ] && [ -f "$config_root/$source_family_file" ]; then
		if [ -n "$family_reason" ]; then
			echo "【Lin】加载通用配置：${source_family_file}（${family_reason} 配置族）" >&2
		else
			echo "【Lin】加载通用配置：${source_family_file}（${source_type} 继承）" >&2
		fi
		printf '%s\n' "$source_family_file"
		return 0
	fi

	# 3. 通用基线（兜底）
	echo "【Lin】加载通用配置：${general_file}（通用基线）" >&2
	printf '%s\n' "$general_file"
}

cleanup() {
	if [ -n "$cleanup_files" ]; then
		rm -f $cleanup_files
	fi
}

device_config_embeds_fw_stack() {
	local config_path=$1

	grep -Eq '^# >>> FW[34]-BEGIN$' "$config_path"
}

device_config_embeds_service_layer() {
	local config_path=$1

	grep -Eq '^# >>> SERVICE-BEGIN$' "$config_path"
}

preprocess_device_config() {
	local input_config=$1
	local fw_name=$2
	local output_config_path=$3
	local current_block=''
	local fw_upper line

	fw_upper=$(printf '%s' "$fw_name" | tr '[:lower:]' '[:upper:]')
	: > "$output_config_path"

	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			'# >>> FW3-BEGIN')
				current_block='FW3'
				continue
				;;
			'# <<< FW3-END')
				current_block=''
				continue
				;;
			'# >>> SERVICE-BEGIN')
				current_block='SERVICE'
				continue
				;;
			'# <<< SERVICE-END')
				current_block=''
				continue
				;;
			'# >>> FW4-BEGIN')
				current_block='FW4'
				continue
				;;
			'# <<< FW4-END')
				current_block=''
				continue
				;;
		esac

		case "$current_block" in
			'')
				printf '%s\n' "$line" >> "$output_config_path"
				;;
			SERVICE)
				printf '%s\n' "$line" >> "$output_config_path"
				;;
			FW3)
				if [ "$fw_upper" = 'FW3' ]; then
					printf '%s\n' "$line" >> "$output_config_path"
				fi
				;;
			FW4)
				if [ "$fw_upper" = 'FW4' ]; then
					case "$line" in
						\#[[:space:]]*CONFIG_*=*)
							printf '%s\n' "$(printf '%s' "$line" | sed 's/^#[[:space:]]*//')" >> "$output_config_path"
							;;
						*)
							printf '%s\n' "$line" >> "$output_config_path"
							;;
					esac
				fi
				;;
		esac
	done < "$input_config"
}

dedupe_config_assignments() {
	local config_path=$1
	local deduped_config

	deduped_config=$(mktemp)
	awk '
		function active_config_key(line, normalized, parts) {
			normalized = line
			sub(/^[ \t]+/, "", normalized)
			if (normalized ~ /^CONFIG_[^=[:space:]]+=/) {
				split(normalized, parts, "=")
				return parts[1]
			}
			return ""
		}

		{
			lines[NR] = $0
			keys[NR] = active_config_key($0)
			if (keys[NR] != "") {
				last_seen[keys[NR]] = NR
			}
		}

		END {
			for (line_no = 1; line_no <= NR; line_no++) {
				if (keys[line_no] == "" || last_seen[keys[line_no]] == line_no) {
					print lines[line_no]
				}
			}
		}
	' "$config_path" > "$deduped_config"
	mv "$deduped_config" "$config_path"
}

overlay_csv_to_file_paths() {
	local config_root=$1
	local overlay_csv=${2:-}
	local old_ifs overlay_name joined_paths

	[ -n "$overlay_csv" ] || {
		printf '\n'
		return 0
	}

	old_ifs=$IFS
	IFS=','
	set -- $overlay_csv
	IFS=$old_ifs

	joined_paths=''
	for overlay_name in "$@"; do
		overlay_name=$(normalize_overlay_name "$overlay_name")
		[ -n "$overlay_name" ] || continue
		if [ -n "$joined_paths" ]; then
			joined_paths="${joined_paths} $(resolve_overlay_file "$config_root" "$overlay_name")"
		else
			joined_paths=$(resolve_overlay_file "$config_root" "$overlay_name")
		fi
	done

	printf '%s\n' "$joined_paths"
}

context_config_root_label() {
	local config_root=$1

	case "$config_root" in
		*/Config|Config)
			printf '%s\n' 'Config'
			;;
		*)
			printf '%s\n' "$config_root"
			;;
	esac
}

write_context_assignment() {
	local key=$1
	local value=${2-}

	printf '%s=' "$key"
	printf '%q' "$value"
	printf '\n'
}

general_config_list_to_paths() {
	local config_root=$1
	local general_list=${2:-}
	local old_ifs general_name joined_paths
	local config_root_label

	config_root_label=$(context_config_root_label "$config_root")

	[ -n "$general_list" ] || {
		printf '\n'
		return 0
	}

	old_ifs=$IFS
	IFS=' '
	set -- $general_list
	IFS=$old_ifs

	joined_paths=''
	for general_name in "$@"; do
		[ -n "$general_name" ] || continue
		if [ -n "$joined_paths" ]; then
			joined_paths="${joined_paths} ${config_root_label}/${general_name}"
		else
			joined_paths="${config_root_label}/${general_name}"
		fi
	done

	printf '%s\n' "$joined_paths"
}

show_help() {
	cat <<'EOF'
用法：
  bash Scripts/export_config.sh --device 设备名 --fw fw3|fw4 --output 输出文件 [--overlay 列表] [--config-dir 目录]

示例：
  bash Scripts/export_config.sh \
    --device cmiot-ax18-nowifi \
    --fw fw3 \
    --overlay frps,nousb \
    --output /tmp/cmiot-ax18-nowifi-fw3-frps-nousb.txt

参数：
  --device      设备名，例如 cmiot-ax18-nowifi、jd-ax1800pro-wifi
  --fw          防火墙栈，fw3 或 fw4
  --overlay     可选 overlay 列表，逗号分隔，例如 frps,nousb
                同一 OVERLAY_GROUP 内按传入顺序以最后一个为准
	  --output      输出文件路径
	  --config-dir  配置目录，默认 Config
	  --context-output  可选，输出解析后的配置上下文变量
	  -h, --help    显示帮助
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--device)
			device=${2:?missing value for --device}
			shift 2
			;;
		--fw)
			fw=${2:?missing value for --fw}
			shift 2
			;;
		--overlay)
			overlay_list=${2:?missing value for --overlay}
			shift 2
			;;
		--output)
			output_config=${2:?missing value for --output}
			shift 2
			;;
		--config-dir)
			config_dir=${2:?missing value for --config-dir}
			shift 2
			;;
		--context-output)
			context_output=${2:?missing value for --context-output}
			shift 2
			;;
		-h|--help)
			show_help
			exit 0
			;;
		*)
			echo "未知参数：$1" >&2
			show_help >&2
			exit 1
			;;
	esac
done

trap cleanup EXIT

[ -n "$device" ] || {
	echo "缺少设备参数，请使用 --device。" >&2
	exit 1
}

[ -n "$output_config" ] || {
	echo "缺少输出路径，请使用 --output。" >&2
	exit 1
}

[ -n "$fw" ] || {
	echo "缺少防火墙参数，请使用 --fw。" >&2
	exit 1
}

case "${fw}" in
	fw3|fw4|FW3|FW4)
		;;
	*)
		echo "fw 参数只支持 fw3 或 fw4" >&2
		exit 1
		;;
esac

manual_overlay_list=$overlay_list
auto_overlay_list=$(infer_default_overlays_for_device "$config_dir" "$device" "$fw")
overlay_list=$(merge_overlay_csv_lists "$config_dir" "$auto_overlay_list" "$overlay_list")
final_overlay_file_paths=$(overlay_csv_to_file_paths "$config_dir" "$overlay_list")

device_config=$(resolve_device_config "$config_dir" "$device" "$fw" || true)
if [ -z "$device_config" ]; then
	echo "缺少设备配置：$config_dir/${device}.txt、$config_dir/${device}-fw3.txt 或 $config_dir/${device}-fw4-iwrt.txt" >&2
	exit 1
fi

resolved_general_configs=$(resolve_general_configs "$config_dir" "$device" "$fw")
device_config_path="$config_dir/$device_config"
processed_device_config="$device_config_path"
embeds_fw_stack=false
embeds_service_layer=false

if device_config_embeds_fw_stack "$device_config_path"; then
	embeds_fw_stack=true
fi

if device_config_embeds_service_layer "$device_config_path"; then
	embeds_service_layer=true
fi

if [ "$embeds_fw_stack" = true ] || [ "$embeds_service_layer" = true ]; then
	processed_device_config=$(mktemp)
	cleanup_files="$processed_device_config"
	preprocess_device_config "$device_config_path" "$fw" "$processed_device_config"
fi

device_overlay_config="device-overlays/${device}-$(printf '%s' "$fw" | tr '[:lower:]' '[:upper:]').txt"

bash "$MERGE_SCRIPT" \
	"$config_dir" \
	"$resolved_general_configs" \
	"$processed_device_config" \
	"$output_config"

if [ -f "$config_dir/$device_overlay_config" ]; then
	cat "$config_dir/$device_overlay_config" >> "$output_config"
fi

if [ -n "$overlay_list" ]; then
	OLD_IFS=$IFS
	IFS=','
	set -- $overlay_list
	IFS=$OLD_IFS
	for overlay_name in "$@"; do
		overlay_name=$(normalize_overlay_name "$overlay_name")
		[ -n "$overlay_name" ] || continue
		cat "$(resolve_overlay_file "$config_dir" "$overlay_name")" >> "$output_config"
	done
fi

dedupe_config_assignments "$output_config"

if [ -n "$context_output" ]; then
	context_config_root=$(context_config_root_label "$config_dir")
	{
		write_context_assignment 'RESOLVED_DEVICE_CONFIG' "$device_config"
		write_context_assignment 'RESOLVED_DEVICE_CONFIG_PATH' "${context_config_root}/${device_config}"
		write_context_assignment 'RESOLVED_GENERAL_CONFIGS' "$resolved_general_configs"
		write_context_assignment 'RESOLVED_GENERAL_CONFIG_PATHS' "$(general_config_list_to_paths "$config_dir" "$resolved_general_configs")"
		write_context_assignment 'RESOLVED_AUTO_OVERLAYS' "$auto_overlay_list"
		write_context_assignment 'RESOLVED_MANUAL_OVERLAYS' "$manual_overlay_list"
		write_context_assignment 'RESOLVED_FINAL_OVERLAYS' "$overlay_list"
		write_context_assignment 'RESOLVED_FINAL_OVERLAY_FILES' "$(printf '%s' "$final_overlay_file_paths" | sed "s#${config_dir}/overlays#${context_config_root}/overlays#g")"
	} > "$context_output"
fi

echo "导出完成：$output_config"
