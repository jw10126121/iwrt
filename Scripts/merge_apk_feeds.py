#!/usr/bin/env python3
"""汇总本次工作流的设备软件源，重建索引后生成一个完整站点。"""

import argparse
import hashlib
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


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").digest()


def apk_command(artifact, override):
    return [str(override.resolve())] if override else ["bash", str((artifact / "tools/run-apk").resolve())]


def same_package(left, right, command):
    if digest(left) == digest(right):
        return True
    # 独立 CORE 各自生成签名密钥。adbdump JSON 含文件哈希和脚本但不含签名，
    # 必须先验证数据完整性，才能把仅签名或压缩方式不同的包认作同一内容。
    try:
        metadata = []
        for package in (left, right):
            subprocess.run(command + ["verify", "--allow-untrusted", str(package.resolve())],
                           check=True, capture_output=True)
            metadata.append(json.loads(subprocess.check_output(
                command + ["adbdump", "--format", "json", str(package.resolve())],
                text=True, stderr=subprocess.PIPE)))
        return metadata[0] == metadata[1]
    except (ValueError, OSError, subprocess.CalledProcessError):
        return False


def add_package(package, destination, command):
    if destination.exists():
        require(same_package(destination, package, command), f"软件包内容冲突：{destination}")
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
                add_package(package, destination / package.name, apk_command(artifact, args.apk))
        (args.output / directories[1] / "vermagic").write_text(meta["vermagic"] + "\n")
    # 不属于模块或内核依赖的额外内置包仅供离线下载；feed 已有的包不存第二份。
    for artifact, meta in entries:
        prefix = Path(meta["source_type"]) / meta["source_tag"]
        directories = (prefix / "packages" / meta["target"] / meta["subtarget"] / meta["arch"],
                       prefix / "kmods" / meta["target"] / meta["subtarget"] / meta["kernel_id"])
        for directory in directories:
            for package in sorted((artifact / "offline" / directory).glob("*.apk")):
                deployed = args.output / directory / package.name
                command = apk_command(artifact, args.apk)
                if deployed.exists():
                    require(same_package(deployed, package, command), f"软件包内容冲突：{directory / package.name}")
                else:
                    add_package(package, args.packages_output / "offline" / directory / package.name, command)
    # Pages 限制只影响站点；被排除的包仍保留在完整下载归档中。
    excluded = []
    for package in sorted(args.output.rglob("*.apk")):
        if package.stat().st_size >= 25 * 1024 * 1024:
            relative = package.relative_to(args.output)
            destination = args.packages_output / "offline" / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                destination.unlink()
            shutil.move(package, destination)
            excluded.append({"path": str(relative), "size": destination.stat().st_size,
                             "reason": "达到或超过 25 MiB，仅跳过 CF 上传"})
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
        "本次编译的完整 APK 包归档\n\n"
        "feed/：=m 插件、递归依赖和内核包，以及重新生成的软件源索引。\n"
        "offline/：其余 =y 包、依赖及 >=25 MiB 的超限包，不上传 CF。\n"
        "同平台相同内容只存一份；不同源码、平台、架构及内核配置分目录。\n"
        "excluded-packages.json：当前平台的 CF 超限排除清单，大包仍可从 offline/ 手动下载。\n")
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
                for view in ("feed", "offline"):
                    for directory in directories:
                        root = args.packages_output / view / directory
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
    parser.add_argument("--archives-output", type=Path, help="按源码短哈希与平台生成完整 ZIP 的目录")
    args = parser.parse_args()
    try:
        merge(args)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"【软件源】拒绝发布：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
