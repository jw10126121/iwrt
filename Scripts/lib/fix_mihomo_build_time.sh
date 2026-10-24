#!/usr/bin/env bash
set -euo pipefail

makefile="${1:?用法：fix_mihomo_build_time.sh <mihomo-meta Makefile>}"
if [ ! -f "$makefile" ]; then
    echo "【Lin】错误：找不到 mihomo-meta Makefile：$makefile" >&2
    exit 1
fi

python3 - "$makefile" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = "PKG_BUILD_TIME:=$(shell date -u -Iseconds)"
new = "PKG_BUILD_TIME:=$(shell date -u -d '@$(SOURCE_DATE_EPOCH)' -Iseconds)"
count = text.count(old)
if count == 0 and new in text:
    print("【Lin】mihomo-meta 构建时间已固定为 SOURCE_DATE_EPOCH")
    raise SystemExit(0)
if count != 1:
    print(f"【Lin】错误：预期在 {path} 中找到一条动态构建时间定义，实际 {count} 条", file=sys.stderr)
    raise SystemExit(1)

path.write_text(text.replace(old, new, 1))
print("【Lin】mihomo-meta 构建时间已固定为 SOURCE_DATE_EPOCH")
PY
