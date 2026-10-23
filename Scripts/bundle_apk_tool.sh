#!/usr/bin/env bash
# 将构建树的 host apk 打包，供同架构 Ubuntu 发布任务重建合并索引。
set -euo pipefail
apk=${1:?缺少 apk 路径}
out=${2:?缺少输出目录}
mkdir -p "$out/lib"
cp -L "$apk" "$out/apk"
if [ "$(head -c 2 "$apk")" != '#!' ]; then
	dependencies=$(ldd "$apk" 2>&1) || {
		if ! printf '%s\n' "$dependencies" | grep -Eq 'not a dynamic executable|statically linked'; then
			printf '%s\n' "$dependencies" >&2
			exit 1
		fi
	}
	if printf '%s\n' "$dependencies" | grep -q 'not found'; then
		echo '【软件源】host apk 缺少运行库，不能生成可发布产物' >&2
		exit 1
	fi
	while IFS= read -r library; do
		[ -n "$library" ] && cp -L "$library" "$out/lib/"
	done < <(printf '%s\n' "$dependencies" | awk '/=> \// {print $3} /^[[:space:]]*\// {print $1}')
fi
cat > "$out/run-apk" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
tool_dir=$(cd "$(dirname "$0")" && pwd)
chmod +x "$tool_dir/apk"
for loader in "$tool_dir"/lib/ld-linux*.so*; do
	if [ -f "$loader" ]; then
		chmod +x "$loader"
		exec "$loader" --library-path "$tool_dir/lib" "$tool_dir/apk" "$@"
	fi
done
exec "$tool_dir/apk" "$@"
SH
chmod +x "$out/run-apk"
