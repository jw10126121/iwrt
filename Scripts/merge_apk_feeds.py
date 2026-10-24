#!/usr/bin/env python3
"""汇总本次工作流的设备软件源，重建索引后生成一个完整站点。"""

import argparse
import html
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def apk_command(artifact, override):
    return [str(override.resolve())] if override else ["bash", str((artifact / "tools/run-apk").resolve())]


def add_package(package, destination):
    if destination.exists():
        # 文件名已包含包版本；相同路径代表同平台同包同版本。entries 按
        # artifact 名排序，因此保留首个副本即可，避免签名差异阻断发布。
        return
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(package, destination)


def link_or_copy(source, destination):
    # 两份本地视图共用文件数据；跨文件系统时回退复制，不增加网络传输。
    try:
        os.link(source, destination)
    except OSError:
        shutil.copy2(source, destination)


def merge(args):
    manifests = sorted(args.input.glob("*/manifest.json"))
    require(len(manifests) == args.expected_count,
            f"软件源产物数量不完整：预期 {args.expected_count}，实际 {len(manifests)}")
    require(manifests, "没有可发布的软件源产物")
    require(not args.output.exists(), f"输出目录已存在，拒绝覆盖：{args.output}")
    require(not args.packages_output.exists(), f"包归档目录已存在，拒绝覆盖：{args.packages_output}")
    entries = [(path.parent, json.loads(path.read_text())) for path in manifests]
    host = entries[0][1]["feed_host"]
    tag = entries[0][1]["deployment_tag"]
    require(not host or re.fullmatch(r"[a-z0-9-]+\.pages\.dev", host),
            "软件源主机必须是 Pages 项目域名")
    require(re.fullmatch(r"[a-z0-9-]+", tag), "无效的发布标识")
    if args.host:
        require(args.host.removeprefix("https://").removeprefix("http://").split("/")[0] == host,
                "发布主机与固件软件源主机不一致")
    if args.archives_output:
        require(not args.archives_output.exists(), f"压缩包目录已存在：{args.archives_output}")
    commits = {}
    kernels = {}
    repositories = {}
    # 所有元数据先校验，再生成站点；不允许混入缺失、旧版本或其他运行的产物。
    for artifact, meta in entries:
        require(meta["feed_host"] == host, "软件源主机不一致")
        require(meta["deployment_tag"] == tag, "发布标识不一致")
        for key in ("source_type", "source_commit", "source_tag", "arch", "target", "subtarget", "kernel_id"):
            require(re.fullmatch(r"[A-Za-z0-9_.-]+", meta[key]) and meta[key] not in (".", ".."),
                    f"无效的软件源字段：{key}")
        source = meta["source_type"]
        identity = (meta["source_commit"], meta["source_tag"])
        require(commits.setdefault(source, identity) == identity,
                f"同一源码的源码提交不一致：{source}，请固定提交后重新编译")
        prefix = Path(source) / meta["source_tag"]
        user_dir = prefix / "packages" / meta["target"] / meta["subtarget"] / meta["arch"]
        kernel_dir = prefix / "kmods" / meta["target"] / meta["subtarget"] / meta["kernel_id"]
        require(kernels.setdefault(kernel_dir, meta["vermagic"]) == meta["vermagic"],
                f"内核 ABI 不一致：{kernel_dir}")
        vm = artifact / kernel_dir / "vermagic"
        require(vm.is_file() and vm.read_text().strip() == meta["vermagic"],
                f"内核 vermagic 缺失或不匹配：{artifact.name}")
        for directory in (user_dir, kernel_dir):
            require((artifact / directory).is_dir(), f"软件源目录缺失：{artifact / directory}")
            repositories.setdefault(directory, (artifact, args.apk))
    args.output.mkdir(parents=True)
    args.packages_output.mkdir(parents=True)
    for artifact, meta in entries:
        prefix = Path(meta["source_type"]) / meta["source_tag"]
        directories = (prefix / "packages" / meta["target"] / meta["subtarget"] / meta["arch"],
                       prefix / "kmods" / meta["target"] / meta["subtarget"] / meta["kernel_id"])
        for directory in directories:
            destination = args.output / directory
            destination.mkdir(parents=True, exist_ok=True)
            for package in sorted((artifact / directory).glob("*.apk")):
                add_package(package, destination / package.name)
        (args.output / directories[1] / "vermagic").write_text(meta["vermagic"] + "\n")
    # Pages 限制只影响站点；超限包不进入可发布 feed，也不进入最终平台 ZIP。
    excluded = []
    for package in sorted(args.output.rglob("*.apk")):
        if package.stat().st_size >= 25 * 1024 * 1024:
            relative = package.relative_to(args.output)
            excluded.append({"path": str(relative), "size": package.stat().st_size,
                             "reason": "达到或超过 25 MiB，未纳入可发布 feed"})
            package.unlink()
            print(f"【软件源】仅跳过 CF 超限包：{relative}")
    (args.output / "excluded-packages.json").write_text(
        json.dumps(excluded, ensure_ascii=False, indent=2) + "\n")
    # 不复制旧 packages.adb，必须为软件包并集重新生成完整索引。
    for directory, (artifact, override) in sorted(repositories.items()):
        destination = (args.output / directory).resolve()
        command = apk_command(artifact, override)
        subprocess.run(command + ["mkndx", "--root", str(args.output.resolve()),
                       "--keys-dir", str(args.output.resolve()), "--allow-untrusted",
                       "--output", "packages.adb"] + [p.name for p in sorted(destination.glob("*.apk"))],
                       cwd=destination, check=True)
        require((destination / "packages.adb").is_file(), f"未生成软件包索引：{directory}")
    links = "\n".join(f'<li><a href="/{html.escape(str(path.relative_to(args.output)), quote=True)}">'
                      f'{html.escape(str(path.relative_to(args.output)))}</a></li>'
                      for path in sorted(args.output.rglob("packages.adb")))
    (args.output / "index.html").write_text(
        f'<!doctype html><meta charset="utf-8"><title>APK 软件源 {tag}</title>'
        f'<h1>本次编译的 APK 软件源</h1><ul>{links}</ul>\n')
    shutil.copytree(args.output, args.packages_output / "feed", copy_function=link_or_copy)
    (args.packages_output / "说明.txt").write_text(
        "本平台可发布的 APK feed 归档\n\n"
        "feed/：=m 插件、递归依赖、内核包和重建的软件源索引。\n"
        "同平台同插件不同版本均保留；相同文件名只保留排序后首个构建的副本。\n"
        "不包含 offline 包。excluded-packages.json 记录因 Cloudflare 25 MiB 限制排除的包。\n")
    if args.archives_output:
        args.archives_output.mkdir(parents=True)
        groups = {}
        for _, meta in entries:
            identity = tuple(meta[key] for key in ("source_type", "source_tag", "target", "subtarget", "arch"))
            groups.setdefault(identity, set()).add(meta["kernel_id"])
        for (source, revision, target, subtarget, arch), kernel_ids in sorted(groups.items()):
            prefix = Path(source) / revision
            directories = [prefix / "packages" / target / subtarget / arch]
            directories += [prefix / "kmods" / target / subtarget / kernel for kernel in sorted(kernel_ids)]
            filename = f"{source}-{revision}-{target}-{subtarget}-{arch}-packages.zip"
            # APK 已压缩，ZIP 使用存储模式，避免反复压缩浪费 CPU。
            with zipfile.ZipFile(args.archives_output / filename, "w", compression=zipfile.ZIP_STORED) as archive:
                for directory in directories:
                    root = args.packages_output / "feed" / directory
                    if root.exists():
                        for path in sorted(root.rglob("*")):
                            if path.is_file():
                                archive.write(path, path.relative_to(args.packages_output))
                archive.write(args.packages_output / "说明.txt", "说明.txt")
                own_excluded = [item for item in excluded if any(
                    Path(item["path"]).is_relative_to(directory) for directory in directories)]
                archive.writestr("excluded-packages.json", json.dumps(own_excluded, ensure_ascii=False, indent=2))
    result = {"project": host.split(".")[0], "tag": tag, "host": host,
              "builds": len(entries), "repositories": len(repositories)}
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"project={result['project']}\ntag={tag}\n")
    print("【软件源】合并完成：" + json.dumps(result, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-count", type=int, required=True)
    parser.add_argument("--host", default="")
    parser.add_argument("--apk", type=Path)
    parser.add_argument("--packages-output", type=Path, required=True,
                        help="合并后的单份 APK 包归档目录")
    parser.add_argument("--archives-output", type=Path, help="按源码短哈希与平台生成 feed ZIP 的目录")
    args = parser.parse_args()
    try:
        merge(args)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"【软件源】拒绝发布：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
