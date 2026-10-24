#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
makefile="$TMP_ROOT/Makefile"
printf 'PKG_VERSION:=1.19.32\nPKG_BUILD_TIME:=$(shell date -u -Iseconds)\n' > "$makefile"

bash "$ROOT_DIR/Scripts/lib/fix_mihomo_build_time.sh" "$makefile"
grep -Fxq "PKG_BUILD_TIME:=\$(shell date -u -d '@\$(SOURCE_DATE_EPOCH)' -Iseconds)" "$makefile"
# 重复执行保持幂等，避免未来脚本调整时改变定义。
bash "$ROOT_DIR/Scripts/lib/fix_mihomo_build_time.sh" "$makefile"
test "$(grep -c '^PKG_BUILD_TIME:=' "$makefile")" -eq 1

printf 'PKG_BUILD_TIME:=one\nPKG_BUILD_TIME:=two\n' > "$makefile"
if bash "$ROOT_DIR/Scripts/lib/fix_mihomo_build_time.sh" "$makefile"; then
    echo '【测试】重复定义应报错' >&2
    exit 1
fi
echo '【测试】mihomo-meta 构建时间固定与异常定义检查通过'
