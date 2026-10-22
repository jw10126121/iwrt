#!/bin/sh
# 允许从自建 APK 仓库安装未签名的软件包索引。
set -eu

OPENWRT_PATH=${OPENWRT_PATH:-$(pwd)}
PATCH_DIR="$OPENWRT_PATH/package/system/apk/patches"
PATCH_FILE="$PATCH_DIR/0101-allow-untrusted-by-default.patch"

mkdir -p "$PATCH_DIR"
cat > "$PATCH_FILE" <<'PATCH'
--- a/src/context.c
+++ b/src/context.c
@@ -66,7 +66,7 @@ int apk_ctx_prepare(struct apk_ctx *ac)
 		ac->open_flags &= ~(APK_OPENF_CREATE | APK_OPENF_WRITE);
 		ac->open_flags |= APK_OPENF_READ;
 	}
-	if (ac->flags & APK_ALLOW_UNTRUSTED) ac->trust.allow_untrusted = 1;
+	ac->trust.allow_untrusted = 1;
 	if (!ac->cache_dir) ac->cache_dir = "etc/apk/cache";
 	else ac->cache_dir_set = 1;
 	if (!ac->root) ac->root = "/";
PATCH
echo '【Lin】已启用自建 APK 软件源的未签名索引支持'
