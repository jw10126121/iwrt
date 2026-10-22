#!/usr/bin/env bash
# 生成可独立发布的 APK 软件源，并按需写入固件仓库地址。
set -euo pipefail

MODE=${1:-}
ROOT=${OPENWRT_PATH:-$(pwd)}
OUT=${APK_FEED_OUT:-${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}/feed-out}
ARCH=${DEVICE_ARCH:-$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\([^"]*\)"/\1/p' "$ROOT/.config" | head -n1)}
SUBTARGET=${DEVICE_SUBTARGET:-}
FEED_HOST=${WRT_FEED_HOST:-}
FEED_TAG=${WRT_HASH:-${REPO_GIT_HASH:-}}
APK=${APK_TOOL:-$ROOT/staging_dir/host/bin/apk}

make_index() {
	local dir=$1
	find "$dir" -maxdepth 1 -type f -name '*.apk' -size +25M -print -delete | sed 's/^/【软件源】超过 25MB，跳过：/'
	[ -n "$(find "$dir" -maxdepth 1 -type f -name '*.apk' -print -quit)" ] || return 1
	(cd "$dir" && "$APK" mkndx --root "$ROOT" --keys-dir "$ROOT" --allow-untrusted --output packages.adb ./*.apk)
}

case "$MODE" in
	collect)
		[ -f "$ROOT/.config" ] || { echo '【软件源】缺少 .config' >&2; exit 1; }
		[ -x "$APK" ] || { echo "【软件源】找不到 host apk 工具：$APK" >&2; exit 1; }
		[ -n "$ARCH" ] || { echo '【软件源】无法确定软件包架构' >&2; exit 1; }
		[ -n "$SUBTARGET" ] || { echo '【软件源】无法确定 target subtarget' >&2; exit 1; }
		[ -n "$FEED_TAG" ] || { echo '【软件源】缺少源码提交标识 WRT_HASH' >&2; exit 1; }
		rm -rf "$OUT"
		userspace="$OUT/$FEED_TAG/packages/$ARCH"
		kmods="$OUT/$FEED_TAG/kmods/$SUBTARGET"
		mkdir -p "$userspace" "$kmods"
		want=$(mktemp)
		trap 'rm -f "$want"' EXIT
		sed -n 's/^CONFIG_PACKAGE_\([^=]*\)=m$/\1/p' "$ROOT/.config" | sort -u > "$want"
		python3 - "$want" "$APK" "$userspace" "$ROOT/bin/packages/$ARCH"/*/ <<'PY'
import json, os, shutil, subprocess, sys
want_file, apk, destination = sys.argv[1:4]
want = set(open(want_file, encoding="utf-8").read().split())
count = 0
for source in sys.argv[4:]:
    index = os.path.join(source, "packages.adb")
    if not os.path.isfile(index):
        continue
    data = json.loads(subprocess.check_output([apk, "adbdump", "--format", "json", index], text=True))
    packages = data.get("packages", []) if isinstance(data, dict) else data
    for package in packages:
        name = package["name"]
        base = name
        for tag in package.get("tags", []):
            if tag.startswith("openwrt:abiversion="):
                abi = tag.split("=", 1)[1]
                if base.endswith(abi):
                    base = base[:-len(abi)]
        if base not in want and name not in want:
            continue
        filename = f"{name}-{package['version']}.apk"
        path = os.path.join(source, filename)
        if os.path.isfile(path):
            shutil.copy2(path, destination)
            count += 1
print(f"【软件源】已收集用户态 APK：{count} 个")
PY
		python3 - "$want" "$APK" "$kmods" "$ROOT/bin/targets"/*/*/packages <<'PY'
import json, os, shutil, subprocess, sys
want_file, apk, destination = sys.argv[1:4]
want = set(open(want_file, encoding="utf-8").read().split())
count = 0
for source in sys.argv[4:]:
    index = os.path.join(source, "packages.adb")
    if not os.path.isfile(index):
        continue
    data = json.loads(subprocess.check_output([apk, "adbdump", "--format", "json", index], text=True))
    packages = data.get("packages", []) if isinstance(data, dict) else data
    for package in packages:
        name = package["name"]
        base = name
        for tag in package.get("tags", []):
            if tag.startswith("openwrt:abiversion=") and base.endswith(tag.split("=", 1)[1]):
                base = base[:-len(tag.split("=", 1)[1])]
        if base in want or name in want:
            path = os.path.join(source, f"{name}-{package['version']}.apk")
            if os.path.isfile(path):
                shutil.copy2(path, destination)
                count += 1
print(f"【软件源】已收集内核模块 APK：{count} 个")
PY
		vm=$(find "$ROOT/build_dir" -maxdepth 5 -type f -path '*/linux-*/.vermagic' -print -quit)
		[ -n "$vm" ] || { echo '【软件源】未找到内核 vermagic' >&2; exit 1; }
		cp "$vm" "$kmods/vermagic"
		if find "$kmods" -maxdepth 1 -name '*.apk' -print -quit | grep -q .; then make_index "$kmods"; else echo '【软件源】没有内核模块 APK，未生成内核索引'; fi
		if find "$userspace" -maxdepth 1 -name '*.apk' -print -quit | grep -q .; then make_index "$userspace"; else echo '【软件源】没有匹配的用户态 APK，未生成用户态索引'; fi
		;;
	firmware)
		if [ -z "$FEED_HOST" ]; then echo '【软件源】未设置 WRT_FEED_HOST，跳过固件仓库配置'; exit 0; fi
		[ -n "$ARCH" ] && [ -n "$SUBTARGET" ] && [ -n "$FEED_TAG" ] || { echo '【软件源】缺少架构、subtarget 或源码提交标识' >&2; exit 1; }
		FEED_HOST=${FEED_HOST#https://}; FEED_HOST=${FEED_HOST#http://}; FEED_HOST=${FEED_HOST%%/*}
		mkdir -p "$ROOT/files/etc/apk/repositories.d"
		printf 'https://%s.%s/packages/%s/packages.adb\nhttps://%s.%s/kmods/%s/packages.adb\n' "$FEED_TAG" "$FEED_HOST" "$ARCH" "$FEED_TAG" "$FEED_HOST" "$SUBTARGET" > "$ROOT/files/etc/apk/repositories.d/extra-feeds.list"
		;;
	*) echo '用法：apk_feed.sh collect|firmware' >&2; exit 2 ;;
esac
