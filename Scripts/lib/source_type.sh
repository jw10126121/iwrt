#!/bin/sh

# SOURCE_TYPE 描述当前使用的上游源码类型，配置统一使用 iwrt 配置集。

# 归一化源码类型输入，兼容常见别名。
normalize_source_type() {
	local source_type=${1:-auto}

	case "$source_type" in
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

# 所有受支持源码都使用 iwrt 配置集。
source_config_family() {
	printf '%s\n' 'iwrt'
}

# 自动模式按源码仓库地址特征识别源码类型，未知来源归为 vwrt 配置族。
detect_source_type_from_tree() {
	local source_root=${1:-.}
	local remote_url

	remote_url=$(git -C "$source_root" config --get remote.origin.url 2>/dev/null || true)
	case "$remote_url" in
		*LiBwrt/LibWrt*) printf '%s\n' 'libwrt' ;;
		*) printf '%s\n' 'vwrt' ;;
	esac
}

# 综合显式输入与源码仓库信息，得到最终源码类型。
resolve_source_type() {
	local requested_type
	local source_root=${2:-.}
	requested_type=$(normalize_source_type "${1:-auto}")

	if [ "$requested_type" = 'auto' ]; then
		detect_source_type_from_tree "$source_root"
	else
		printf '%s\n' "$requested_type"
	fi
}
