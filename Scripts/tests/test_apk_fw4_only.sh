#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT_DIR"

failures=0
check_absent() {
	local pattern="$1"
	local path="$2"
	if rg -n "$pattern" "$path"; then
		echo '【测试】发现已移除的构建入口' >&2
		failures=$((failures + 1))
	fi
}

check_absent '(^|[^[:alnum:]_])(lean|fw3|ipk)([^[:alnum:]_]|$)' .github/workflows/DEFAULT.yml
check_absent '(^|[^[:alnum:]_])(lean|fw3|ipk)([^[:alnum:]_]|$)' Scripts/lib/source_type.sh
check_absent '\.ipk|for ext in ipk' Scripts/Organize_Packages.sh
check_absent '(^|[^[:alnum:]_])(fw3|ipk|lean)([^[:alnum:]_]|$)' Scripts/export_config.sh
check_absent '(^|[^[:alnum:]_])(fw3|ipk|lean)([^[:alnum:]_]|$)' Scripts/ci_collect_final_metadata.sh

if find Config -maxdepth 1 -type f -name '*fw3*' | grep -q .; then
	echo '【测试】Config 目录仍存在 fw3 配置文件' >&2
	failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
	echo "【测试】APK/fw4 统一检查失败：$failures 项" >&2
	exit 1
fi

echo '【测试】APK/fw4 统一检查通过'
