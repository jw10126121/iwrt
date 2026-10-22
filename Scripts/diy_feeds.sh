#!/bin/bash
#=================================================
# Description: DIY feeds script
# Lisence: MIT
#=================================================
#
# 用途：
# 1. 启用 feeds.conf.default 中默认注释掉的 helloworld feed。
# 2. 按需切换 lean 源码使用的 LuCI feed 分支。
# 3. 清理已停用的第三方 feed。

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/lib/luci_feed_compat.sh"

feed_config_name='feeds.conf.default'
luci_branch_input="${WRT_LUCI_BRANCH:-}"

has_active_feed() {
	local feed_name="$1"
	grep -Eq "^[[:space:]]*src-[^[:space:]]+[[:space:]]+${feed_name}([[:space:]]|$)" "$feed_config_name"
}

append_feed_if_missing() {
	local feed_name="$1"
	local feed_line="$2"

	if ! has_active_feed "$feed_name"; then
		echo "$feed_line" >> "$feed_config_name"
	fi
}

dedupe_active_feeds() {
	local tmp_file
	tmp_file="$(mktemp)"

	awk '
	/^[[:space:]]*src-[^[:space:]]+[[:space:]]+/ {
		feed_name = $2
		# 插件已停用且仓库不可公开访问，旧配置也不能继续拉取。
		if (feed_name == "miaomiaowu") {
			next
		}
		if (seen[feed_name]++) {
			next
		}
	}
	{ print }
	' "$feed_config_name" > "$tmp_file"

	mv "$tmp_file" "$feed_config_name"
}

resolve_luci_branch_override() {
	local canonical_branch

	if canonical_branch="$(canonicalize_luci_feed_branch_token "$luci_branch_input")"; then
		printf '%s\n' "$canonical_branch"
		return 0
	fi

	return 1
}

apply_luci_branch_override() {
	local target_branch=$1

	sed -i "s#https://github.com/coolsnowwolf/luci\\.git;[^[:space:]]*#https://github.com/coolsnowwolf/luci.git;${target_branch}#" "$feed_config_name"
}

# 默认启用 helloworld feed。
sed -i "s/#src-git helloworld/src-git helloworld/g" "$feed_config_name"

# 仅在 WRT_LUCI_BRANCH 能识别为已知版本线时才覆盖 LuCI feed；
# 未识别时保留 feeds.conf.default 原始分支不动。
if target_luci_branch="$(resolve_luci_branch_override)"; then
	apply_luci_branch_override "$target_luci_branch"
fi

dedupe_active_feeds

# 添加istore
append_feed_if_missing "istore" "src-git istore https://github.com/linkease/istore;main"
# 添加sqm_scripts_nss
append_feed_if_missing "sqm_scripts_nss" "src-git sqm_scripts_nss https://github.com/qosmio/sqm-scripts-nss.git"
# append_feed_if_missing "sqm_scripts_nss" "src-git sqm_scripts_nss https://github.com/openwrt-ipq60xx/sqm-scripts-nss.git"

# 添加sqm_scripts_nss，这个目前只支持 ipq807x，不支持ipq60xx，等更新
# append_feed_if_missing "sqm_scripts_nss" "src-git sqm_scripts_nss https://github.com/JuliusBairaktaris/sqm-scripts-nss.git"
