#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
OPENWRT_PATH="$TMP_ROOT/openwrt"
GITHUB_WORKSPACE="$TMP_ROOT/workspace"
mkdir -p "$OPENWRT_PATH/staging_dir/host/bin" "$OPENWRT_PATH/bin/packages/testarch/feed" \
	"$OPENWRT_PATH/bin/targets/test/testsub/packages" "$OPENWRT_PATH/build_dir/linux-test" \
	"$GITHUB_WORKSPACE/Config"

cat > "$OPENWRT_PATH/staging_dir/host/bin/apk" <<'EOF'
#!/usr/bin/env bash
set -e
case "$1" in
	adbdump) printf '{"packages":[{"name":"demo","version":"1.0-r1","tags":[],"depends":["libdep=1.0"]},{"name":"libdep","version":"1.0","tags":[],"depends":["libc"]},{"name":"libc","version":"1.0","tags":[]},{"name":"kmod-test","version":"1.0","tags":[]},{"name":"unlisted","version":"1.0","tags":[]}]}' ;;
	mkndx) while [ "$1" != '--output' ]; do shift; done; shift; touch "$1" ;;
	*) exit 3 ;;
esac
EOF
chmod +x "$OPENWRT_PATH/staging_dir/host/bin/apk"
touch "$OPENWRT_PATH/bin/packages/testarch/feed/packages.adb" "$OPENWRT_PATH/bin/packages/testarch/feed/demo-1.0-r1.apk" "$OPENWRT_PATH/bin/packages/testarch/feed/unlisted-1.0.apk"
touch "$OPENWRT_PATH/bin/packages/testarch/feed/libdep-1.0.apk" "$OPENWRT_PATH/bin/packages/testarch/feed/libc-1.0.apk"
touch "$OPENWRT_PATH/bin/targets/test/testsub/packages/packages.adb" "$OPENWRT_PATH/bin/targets/test/testsub/packages/kmod-test-1.0.apk" "$OPENWRT_PATH/bin/targets/test/testsub/packages/unlisted-1.0.apk"
printf 'test-vermagic\n' > "$OPENWRT_PATH/build_dir/linux-test/.vermagic"
printf 'CONFIG_TARGET_ARCH_PACKAGES="testarch"\nCONFIG_PACKAGE_demo=m\nCONFIG_PACKAGE_kept=y\nCONFIG_PACKAGE_libdep=y\nCONFIG_PACKAGE_libc=y\nCONFIG_PACKAGE_kmod-test=m\n' > "$OPENWRT_PATH/.config"

export OPENWRT_PATH GITHUB_WORKSPACE DEVICE_ARCH=testarch DEVICE_TARGET=test DEVICE_SUBTARGET=testsub WRT_HASH=abc1234
export SOURCE_TYPE=immortalwrt GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 WRT_FEED_HOST=lin-iwrt.pages.dev
grep -Fxq 'CONFIG_PACKAGE_demo=m' "$OPENWRT_PATH/.config"
grep -Fxq 'CONFIG_PACKAGE_kept=y' "$OPENWRT_PATH/.config"
bash "$ROOT_DIR/Scripts/apk_feed.sh" collect
export APK_FEED_OUT="$GITHUB_WORKSPACE/feed-out"
bash "$ROOT_DIR/Scripts/apk_feed.sh" collect

kernel_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kernel_id"])' "$APK_FEED_OUT/manifest.json")
prefix="$APK_FEED_OUT/immortalwrt/abc1234"
test -f "$prefix/packages/test/testsub/testarch/demo-1.0-r1.apk"
test -f "$prefix/packages/test/testsub/testarch/packages.adb"
test -f "$prefix/packages/test/testsub/testarch/libdep-1.0.apk"
test -f "$prefix/packages/test/testsub/testarch/libc-1.0.apk"
test ! -e "$APK_FEED_OUT/offline/immortalwrt/abc1234/packages/test/testsub/testarch/libdep-1.0.apk"
test -f "$prefix/kmods/test/testsub/$kernel_id/vermagic"
test -f "$prefix/kmods/test/testsub/$kernel_id/kmod-test-1.0.apk"
test -f "$prefix/kmods/test/testsub/$kernel_id/packages.adb"
test ! -e "$prefix/packages/test/testsub/testarch/unlisted-1.0.apk"
test ! -e "$prefix/kmods/test/testsub/$kernel_id/unlisted-1.0.apk"
test -f "$APK_FEED_OUT/offline/immortalwrt/abc1234/packages/test/testsub/testarch/unlisted-1.0.apk"
test ! -e "$APK_FEED_OUT/offline/immortalwrt/abc1234/kmods/test/testsub/$kernel_id/unlisted-1.0.apk"
grep -Fxq test-vermagic "$prefix/kmods/test/testsub/$kernel_id/vermagic"
test -f "$APK_FEED_OUT/tools/apk"
test -f "$APK_FEED_OUT/tools/run-apk"
# 模拟 artifact 下载会清除可执行权限，打包后的工具仍应能工作。
chmod -x "$APK_FEED_OUT/tools/apk" "$APK_FEED_OUT/tools/run-apk"
bash "$APK_FEED_OUT/tools/run-apk" mkndx --output "$TMP_ROOT/bundled.adb" "$prefix/packages/test/testsub/testarch/demo-1.0-r1.apk"
test -f "$TMP_ROOT/bundled.adb"

export WRT_FEED_HOST=feeds.example.net
bash "$ROOT_DIR/Scripts/apk_feed.sh" firmware
grep -Fxq 'https://build-123-1.feeds.example.net/immortalwrt/abc1234/packages/test/testsub/testarch/packages.adb' "$OPENWRT_PATH/files/etc/apk/repositories.d/extra-feeds.list"
grep -Fxq "https://build-123-1.feeds.example.net/immortalwrt/abc1234/kmods/test/testsub/$kernel_id/packages.adb" "$OPENWRT_PATH/files/etc/apk/repositories.d/extra-feeds.list"

# firmware 阶段写入的内核目录标识必须被后续 collect 复用。
printf 'CONFIG_PACKAGE_later=m\n' >> "$OPENWRT_PATH/.config"
bash "$ROOT_DIR/Scripts/apk_feed.sh" collect
test -f "$prefix/kmods/test/testsub/$kernel_id/packages.adb"

rm -rf "$OPENWRT_PATH/files/etc/apk/repositories.d"
unset WRT_FEED_HOST
bash "$ROOT_DIR/Scripts/apk_feed.sh" firmware
test ! -e "$OPENWRT_PATH/files/etc/apk/repositories.d/extra-feeds.list"

# 从固件 URL 一直验证到合并站点，防止下载产物时目录层级发生偏移。
export WRT_FEED_HOST=lin-iwrt.pages.dev
bash "$ROOT_DIR/Scripts/apk_feed.sh" firmware
bash "$ROOT_DIR/Scripts/apk_feed.sh" collect
mkdir -p "$GITHUB_WORKSPACE/feed-artifacts"
mv "$APK_FEED_OUT" "$GITHUB_WORKSPACE/feed-artifacts/device-apk-feed"
GITHUB_OUTPUT="$TMP_ROOT/publish-output" python3 "$ROOT_DIR/Scripts/merge_apk_feeds.py" \
	--input "$GITHUB_WORKSPACE/feed-artifacts" --output "$TMP_ROOT/public" \
	--packages-output "$TMP_ROOT/packages" \
	--expected-count 1 --host "$WRT_FEED_HOST"
python3 - "$OPENWRT_PATH/files/etc/apk/repositories.d/extra-feeds.list" "$TMP_ROOT/public" <<'PY'
import pathlib, sys
from urllib.parse import urlparse
for url in pathlib.Path(sys.argv[1]).read_text().splitlines():
    parsed = urlparse(url)
    assert parsed.netloc == "build-123-1.lin-iwrt.pages.dev", url
    assert (pathlib.Path(sys.argv[2]) / parsed.path.lstrip("/")).is_file(), url
PY
grep -Fxq 'project=lin-iwrt' "$TMP_ROOT/publish-output"
grep -Fxq 'tag=build-123-1' "$TMP_ROOT/publish-output"
test ! -e "$TMP_ROOT/public/tools"
test ! -e "$TMP_ROOT/public/manifest.json"

kernel_id=$(cat "$OPENWRT_PATH/.apk-feed-kernel-id")

# 超限 APK 不阻止收集；汇总时从可发布 feed 与平台 ZIP 一并排除，并记录原因。
python3 - "$OPENWRT_PATH/bin/packages/testarch/feed/demo-1.0-r1.apk" <<'PYTEST'
import sys
with open(sys.argv[1], "wb") as package:
    package.truncate(26214400)
PYTEST
bash "$ROOT_DIR/Scripts/apk_feed.sh" collect
mkdir -p "$TMP_ROOT/oversized-input"
mv "$APK_FEED_OUT" "$TMP_ROOT/oversized-input/device-apk-feed"
python3 "$ROOT_DIR/Scripts/merge_apk_feeds.py" \
    --input "$TMP_ROOT/oversized-input" --output "$TMP_ROOT/small-public" \
    --packages-output "$TMP_ROOT/all-packages" --archives-output "$TMP_ROOT/archives" \
    --expected-count 1
test ! -e "$TMP_ROOT/small-public/immortalwrt/abc1234/packages/test/testsub/testarch/demo-1.0-r1.apk"
test ! -e "$TMP_ROOT/all-packages/offline/immortalwrt/abc1234/packages/test/testsub/testarch/demo-1.0-r1.apk"
grep -Fq 'demo-1.0-r1.apk' "$TMP_ROOT/small-public/excluded-packages.json"
test ! -e "$TMP_ROOT/archives/immortalwrt-abc1234-test-testsub-testarch-packages.zip" || \
  ! unzip -l "$TMP_ROOT/archives/immortalwrt-abc1234-test-testsub-testarch-packages.zip" | \
  grep -q 'demo-1.0-r1.apk'
test -f "$TMP_ROOT/small-public/immortalwrt/abc1234/kmods/test/testsub/$kernel_id/kmod-test-1.0.apk"
test -f "$TMP_ROOT/archives/immortalwrt-abc1234-test-testsub-testarch-packages.zip"
echo '【测试】APK 软件源依赖收集、平台归档、固件配置与单包过滤通过'
