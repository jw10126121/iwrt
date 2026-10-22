#!/bin/sh

# SOURCE_TYPE describes the selected upstream flavor; config family describes
# which config set should be applied by this repository.

# 归一化源码类型输入，兼容常见别名并输出仓库内部使用的标准值。
normalize_source_type() {
	local source_type=${1:-auto}

	case "$source_type" in
		lean|lede|lwrt)
			printf '%s\n' 'lean'
			;;
		iwrt|vwrt|immortalwrt|vikingyfy)
			printf '%s\n' 'vwrt'
			;;
		libwrt)
			printf '%s\n' 'libwrt'
			;;
		auto|'')
			printf '%s\n' 'auto'
			;;
		*)
			printf '%s\n' "$source_type"
			;;
	esac
}

# 根据源码类型选择配置家族，目前 lean 走 lean，其余统一走 iwrt 配置集。
source_config_family() {
	local source_type
	source_type=$(normalize_source_type "${1:-auto}")

	case "$source_type" in
		lean)
			printf '%s\n' 'lean'
			;;
		*)
			printf '%s\n' 'iwrt'
			;;
	esac
}

# 在未显式指定时，根据源码树特征判断当前是 lean 还是 vwrt。
detect_source_type_from_tree() {
	local source_root=${1:-.}

	if [ -f "$source_root/package/lean/default-settings/files/zzz-default-settings" ] || \
		[ -f "$source_root/package/lean/default-settings/Makefile" ]; then
		printf '%s\n' 'lean'
	else
		printf '%s\n' 'vwrt'
	fi
}

# 综合用户输入与源码树探测结果，得到最终生效的源码类型。
resolve_source_type() {
	local requested_type
	local source_root=${2:-.}
	requested_type=$(normalize_source_type "${1:-auto}")

	if [ "$requested_type" = "auto" ]; then
		detect_source_type_from_tree "$source_root"
	else
		printf '%s\n' "$requested_type"
	fi
}
