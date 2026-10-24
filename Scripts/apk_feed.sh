#!/usr/bin/env bash
# 生成可独立发布的 APK 软件源，并按需写入固件仓库地址。
set -euo pipefail

MODE=${1:-}
ROOT=${OPENWRT_PATH:-$(pwd)}
OUT=${APK_FEED_OUT:-${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}/feed-out}
ARCH=${DEVICE_ARCH:-$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\([^"]*\)"/\1/p' "$ROOT/.config" | head -n1)}
SUBTARGET=${DEVICE_SUBTARGET:-}
TARGET=${DEVICE_TARGET:-}
FEED_HOST=${WRT_FEED_HOST:-}
FEED_TAG=${WRT_HASH:-${REPO_GIT_HASH:-}}
APK=${APK_TOOL:-$ROOT/staging_dir/host/bin/apk}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=Scripts/lib/source_type.sh
. "$SCRIPT_DIR/lib/source_type.sh"
SOURCE_TYPE=$(resolve_source_type "${SOURCE_TYPE:-auto}" "$ROOT")
# 固件使用源码短 Hash 对应的 Pages 分支；一次工作流可部署多个源码分支。
DEPLOY_TAG=${APK_FEED_DEPLOY_TAG:-$FEED_TAG}
FEED_HOST=${FEED_HOST#https://}; FEED_HOST=${FEED_HOST#http://}; FEED_HOST=${FEED_HOST%%/*}
PREFIX="$SOURCE_TYPE/$FEED_TAG"

kernel_id() {
	# 固件打包之前尚未生成 vermagic，先按最终配置隔离，再在收集阶段校验实际 ABI。
	python3 - "$ROOT/.config" <<'PY'
import hashlib, pathlib, sys
lines = sorted(line.strip() for line in pathlib.Path(sys.argv[1]).read_text().splitlines()
               if line.startswith("CONFIG_") or line.startswith("# CONFIG_"))
print(hashlib.sha256("\n".join(lines).encode()).hexdigest()[:16])
PY
}

make_index() {
	local dir=$1
	# 空目录也生成有效索引，固件配置的两个仓库地址都必须可访问。
	(cd "$dir"; shopt -s nullglob; packages=(./*.apk); "$APK" mkndx --root "$ROOT" --keys-dir "$ROOT" --allow-untrusted --output packages.adb "${packages[@]}")
}

case "$MODE" in
	collect)
		[ -f "$ROOT/.config" ] || { echo '【软件源】缺少 .config' >&2; exit 1; }
		[ -x "$APK" ] || { echo "【软件源】找不到 host apk 工具：$APK" >&2; exit 1; }
		[ -n "$ARCH" ] || { echo '【软件源】无法确定软件包架构' >&2; exit 1; }
		[ -n "$SUBTARGET" ] || { echo '【软件源】无法确定 target subtarget' >&2; exit 1; }
		[ -n "$TARGET" ] || { echo '【软件源】无法确定 target' >&2; exit 1; }
		[ -n "$FEED_TAG" ] || { echo '【软件源】缺少源码提交标识 WRT_HASH' >&2; exit 1; }
		KERNEL_ID=$(cat "$ROOT/.apk-feed-kernel-id" 2>/dev/null || kernel_id)
		rm -rf "$OUT"
		userspace="$OUT/$PREFIX/packages/$TARGET/$SUBTARGET/$ARCH"
		kmods="$OUT/$PREFIX/kmods/$TARGET/$SUBTARGET/$KERNEL_ID"
		offline_userspace="$OUT/offline/$PREFIX/packages/$TARGET/$SUBTARGET/$ARCH"
		offline_kmods="$OUT/offline/$PREFIX/kmods/$TARGET/$SUBTARGET/$KERNEL_ID"
		mkdir -p "$userspace" "$kmods" "$offline_userspace" "$offline_kmods"
		python3 "$SCRIPT_DIR/collect_apk_packages.py" --root "$ROOT" --output "$OUT" \
			--apk "$APK" --arch "$ARCH" --target "$TARGET" --subtarget "$SUBTARGET" \
			--userspace "$userspace" --kmods "$kmods"
		vm=$(find "$ROOT/build_dir" -maxdepth 5 -type f -path '*/linux-*/.vermagic' -print -quit)
		[ -n "$vm" ] || { echo '【软件源】未找到内核 vermagic' >&2; exit 1; }
		cp "$vm" "$kmods/vermagic"
		make_index "$kmods"
		make_index "$userspace"
		python3 - "$OUT/manifest.json" "$SOURCE_TYPE" "${REPO_GIT_HASH:-$FEED_TAG}" "$FEED_TAG" "$DEPLOY_TAG" "$FEED_HOST" "$ARCH" "$TARGET" "$SUBTARGET" "$KERNEL_ID" "$(cat "$vm")" <<'PY'
import json, pathlib, sys
keys = ("source_type", "source_commit", "source_tag", "deployment_tag", "feed_host",
        "arch", "target", "subtarget", "kernel_id", "vermagic")
pathlib.Path(sys.argv[1]).write_text(json.dumps(dict(zip(keys, sys.argv[2:])), ensure_ascii=False, indent=2) + "\n")
PY
		# 发布任务不再有构建树，随产物保存该源码实际使用的 host apk 和运行库。
		bash "$SCRIPT_DIR/bundle_apk_tool.sh" "$APK" "$OUT/tools"
		;;
	firmware)
		if [ -z "$FEED_HOST" ]; then echo '【软件源】未设置 WRT_FEED_HOST，跳过固件仓库配置'; exit 0; fi
		[ -n "$ARCH" ] && [ -n "$TARGET" ] && [ -n "$SUBTARGET" ] && [ -n "$FEED_TAG" ] || { echo '【软件源】缺少架构、target/subtarget 或源码提交标识' >&2; exit 1; }
		KERNEL_ID=$(kernel_id)
		printf '%s\n' "$KERNEL_ID" > "$ROOT/.apk-feed-kernel-id"
		mkdir -p "$ROOT/files/etc/apk/repositories.d"
		printf 'https://%s.%s/%s/packages/%s/%s/%s/packages.adb\nhttps://%s.%s/%s/kmods/%s/%s/%s/packages.adb\n' "$DEPLOY_TAG" "$FEED_HOST" "$PREFIX" "$TARGET" "$SUBTARGET" "$ARCH" "$DEPLOY_TAG" "$FEED_HOST" "$PREFIX" "$TARGET" "$SUBTARGET" "$KERNEL_ID" > "$ROOT/files/etc/apk/repositories.d/extra-feeds.list"
		;;
	*) echo '用法：apk_feed.sh collect|firmware' >&2; exit 2 ;;
esac
