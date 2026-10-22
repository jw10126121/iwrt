#!/bin/bash

# 归一化 LuCI feed 分支标识，兼容 openwrt-24.10 / 24.10 / 2410 等写法。
canonicalize_luci_feed_branch_token() {
	local token

	token=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	case "${token}" in
		openwrt-23.05|23.05|2305)
			printf '%s\n' 'openwrt-23.05'
			;;
		openwrt-24.10|24.10|2410)
			printf '%s\n' 'openwrt-24.10'
			;;
		openwrt-25.12|25.12|2512)
			printf '%s\n' 'openwrt-25.12'
			;;
		*)
			return 1
			;;
	esac
}

# 从 feeds.conf.default 中解析 luci feed 实际分支，并尽量映射成统一版本标识。
resolve_luci_feed_branch() {
	local feeds_file="${1:-./feeds.conf.default}"
	local line
	local branch
	local canonical_branch

	[ -f "${feeds_file}" ] || {
		printf '%s\n' 'unknown'
		return 0
	}

	line=$(grep -E '^[[:space:]]*src-git[[:space:]]+luci[[:space:]]+' "${feeds_file}" | head -n 1)
	[ -n "${line}" ] || {
		printf '%s\n' 'unknown'
		return 0
	}

	branch=$(printf '%s\n' "${line}" | sed -n 's#.*;\([^;[:space:]]*\)[[:space:]]*$#\1#p')
	if [ -n "${branch}" ]; then
		if canonical_branch="$(canonicalize_luci_feed_branch_token "${branch}")"; then
			printf '%s\n' "${canonical_branch}"
		else
			printf '%s\n' "${branch}"
		fi
	else
		printf '%s\n' 'default'
	fi
}

# 判断当前 luci feed 是否为 25.12 分支，供兼容逻辑做条件分支。
is_luci_feed_25_12() {
	[ "$(resolve_luci_feed_branch "${1:-./feeds.conf.default}")" = "openwrt-25.12" ]
}

# 保留 lean 侧旧函数名，内部仍复用统一判断，避免调用方重复改名。
is_lean_luci_feed_25_12() {
	is_luci_feed_25_12 "${1:-./feeds.conf.default}"
}
