#!/usr/bin/env python3
"""整理给 Artifact/Release 下载的 APK 包；输出与 Pages feed 分离。"""

import argparse
import json
import sys
import zipfile
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def organize(args):
    require(args.input.is_dir(), f"缺少合并后的 feed 包目录：{args.input}")
    require(not args.output.exists(), f"输出目录已存在，拒绝覆盖：{args.output}")
    groups = {}
    # feed/<source>/<revision>/packages/<target>/<subtarget>/<arch>/packages.adb
    for index in sorted(args.input.glob("*/*/packages/*/*/*/packages.adb")):
        source, revision, _, target, subtarget, arch = index.relative_to(args.input).parts[:6]
        identity = (source, revision, target, subtarget, arch)
        groups.setdefault(identity, {"userspace": index.parent, "kmods": []})
    require(groups, "合并后的 feed 中没有用户态软件包索引")
    for source, revision, target, subtarget, arch in groups:
        for vermagic in sorted((args.input / source / revision / "kmods" / target / subtarget).glob("*/vermagic")):
            groups[(source, revision, target, subtarget, arch)]["kmods"].append(vermagic.parent)

    args.output.mkdir(parents=True)
    excluded_path = args.input / "excluded-packages.json"
    excluded = json.loads(excluded_path.read_text()) if excluded_path.is_file() else []
    for identity, repositories in sorted(groups.items()):
        source, revision, target, subtarget, arch = identity
        filename = f"{source}-{revision}-{target}-{subtarget}-{arch}-packages.zip"
        selected_dirs = [repositories["userspace"], *repositories["kmods"]]
        platform_excluded = [item for item in excluded if any(
            Path(item["path"]).is_relative_to(path.relative_to(args.input)) for path in selected_dirs)]
        description = (
            f"平台插件包下载归档：{source} {revision} / {target}/{subtarget} / {arch}\n\n"
            "本归档用于手动下载和保存，不是设备软件源。\n"
            "packages/：用户态插件与依赖 APK。\n"
            "kmods/<kernel_id>/：内核模块 APK、vermagic。不同 kernel_id 不可混用。\n"
            "此归档不包含 packages.adb；设备在线安装请使用对应 Pages feed。\n"
            "excluded-packages.json 记录因 Cloudflare 单文件大小限制排除的 APK。\n"
        )
        with zipfile.ZipFile(args.output / filename, "w", compression=zipfile.ZIP_STORED) as archive:
            for package in sorted(repositories["userspace"].glob("*.apk")):
                archive.write(package, f"packages/{arch}/{package.name}")
            for directory in repositories["kmods"]:
                kernel_id = directory.name
                for item in sorted(directory.iterdir()):
                    if item.is_file() and item.name != "packages.adb":
                        archive.write(item, f"kmods/{kernel_id}/{item.name}")
            archive.writestr("平台信息.json", json.dumps({
                "source": source, "revision": revision, "target": target,
                "subtarget": subtarget, "arch": arch,
                "kernel_ids": [path.name for path in repositories["kmods"]],
            }, ensure_ascii=False, indent=2) + "\n")
            archive.writestr("excluded-packages.json", json.dumps(platform_excluded,
                                                                 ensure_ascii=False, indent=2) + "\n")
            archive.writestr("说明.txt", description)
    print(f"【产物】已整理 Artifact/Release 平台 APK 包：{len(groups)} 个 ZIP")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="合并后的 feed 包目录")
    parser.add_argument("--output", type=Path, required=True, help="Artifact/Release 平台 ZIP 输出目录")
    args = parser.parse_args()
    try:
        organize(args)
    except (ValueError, KeyError, OSError, zipfile.BadZipFile) as error:
        print(f"【产物】APK 包整理失败：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
