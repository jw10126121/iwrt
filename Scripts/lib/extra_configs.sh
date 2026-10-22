#!/bin/bash

# 归一化单条附加配置，兼容 luci-app-xxx、luci-app-xxx=y 及完整 CONFIG_ 写法。
normalize_extra_config_entry() {
	local raw_entry trimmed name state

	trimmed=$(printf '%s' "${1:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	[ -n "$trimmed" ] || return 0

	case "$trimmed" in
		CONFIG_*=y|CONFIG_*=m|CONFIG_*=n)
			printf '%s\n' "$trimmed"
			return 0
			;;
		*=y|*=m|*=n)
			name=${trimmed%=*}
			state=${trimmed##*=}
			printf 'CONFIG_PACKAGE_%s=%s\n' "$name" "$state"
			return 0
			;;
		*=*)
			echo "非法附加配置项：$trimmed" >&2
			return 1
			;;
		*)
			printf 'CONFIG_PACKAGE_%s=y\n' "$trimmed"
			return 0
			;;
	esac
}

# 将 Actions 输入里的空白、半角逗号、中文逗号统一拆成逐行配置，并逐条走归一化逻辑。
normalize_extra_config_stream() {
	sed 's/[，,]/ /g' | tr '\r\t' '\n ' | while IFS= read -r line; do
		for entry in $line; do
			normalize_extra_config_entry "$entry"
		done
	done
}
