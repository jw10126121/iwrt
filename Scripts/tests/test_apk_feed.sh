#!/usr/bin/env bash
set -euo pipefail

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
	adbdump) printf '{"packages":[{"name":"demo","version":"1.0-r1","tags":[]},{"name":"kmod-test","version":"1.0","tags":[]},{"name":"unlisted","version":"1.0","tags":[]}]}' ;;
	mkndx) while [ "$1" != '--output' ]; do shift; done; shift; touch "$1" ;;
	*) exit 3 ;;
esac
EOF
chmod +x "$OPENWRT_PATH/staging_dir/host/bin/apk"
touch "$OPENWRT_PATH/bin/packages/testarch/feed/packages.adb" "$OPENWRT_PATH/bin/packages/testarch/feed/demo-1.0-r1.apk" "$OPENWRT_PATH/bin/packages/testarch/feed/unlisted-1.0.apk"
touch "$OPENWRT_PATH/bin/targets/test/testsub/packages/packages.adb" "$OPENWRT_PATH/bin/targets/test/testsub/packages/kmod-test-1.0.apk" "$OPENWRT_PATH/bin/targets/test/testsub/packages/unlisted-1.0.apk"
printf 'test-vermagic\n' > "$OPENWRT_PATH/build_dir/linux-test/.vermagic"
printf 'CONFIG_TARGET_ARCH_PACKAGES="testarch"\nCONFIG_PACKAGE_demo=m\nCONFIG_PACKAGE_kept=y\nCONFIG_PACKAGE_kmod-test=m\n' > "$OPENWRT_PATH/.config"

export OPENWRT_PATH GITHUB_WORKSPACE DEVICE_ARCH=testarch DEVICE_SUBTARGET=testsub WRT_HASH=abc1234
grep -Fxq 'CONFIG_PACKAGE_demo=m' "$OPENWRT_PATH/.config"
grep -Fxq 'CONFIG_PACKAGE_kept=y' "$OPENWRT_PATH/.config"
bash "$ROOT_DIR/Scripts/apk_feed.sh" collect
export APK_FEED_OUT="$GITHUB_WORKSPACE/feed-out"
bash "$ROOT_DIR/Scripts/apk_feed.sh" collect

test -f "$APK_FEED_OUT/abc1234/packages/testarch/demo-1.0-r1.apk"
test -f "$APK_FEED_OUT/abc1234/packages/testarch/packages.adb"
test -f "$APK_FEED_OUT/abc1234/kmods/testsub/vermagic"
test -f "$APK_FEED_OUT/abc1234/kmods/testsub/kmod-test-1.0.apk"
test -f "$APK_FEED_OUT/abc1234/kmods/testsub/packages.adb"
test ! -e "$APK_FEED_OUT/abc1234/packages/testarch/unlisted-1.0.apk"
test ! -e "$APK_FEED_OUT/abc1234/kmods/testsub/unlisted-1.0.apk"
grep -Fxq test-vermagic "$APK_FEED_OUT/abc1234/kmods/testsub/vermagic"

export WRT_FEED_HOST=feeds.example.net
bash "$ROOT_DIR/Scripts/apk_feed.sh" firmware
grep -Fxq 'https://abc1234.feeds.example.net/packages/testarch/packages.adb' "$OPENWRT_PATH/files/etc/apk/repositories.d/extra-feeds.list"
grep -Fxq 'https://abc1234.feeds.example.net/kmods/testsub/packages.adb' "$OPENWRT_PATH/files/etc/apk/repositories.d/extra-feeds.list"

rm -rf "$OPENWRT_PATH/files/etc/apk/repositories.d"
unset WRT_FEED_HOST
bash "$ROOT_DIR/Scripts/apk_feed.sh" firmware
test ! -e "$OPENWRT_PATH/files/etc/apk/repositories.d/extra-feeds.list"
echo '【测试】APK 软件源收集与固件配置通过'
