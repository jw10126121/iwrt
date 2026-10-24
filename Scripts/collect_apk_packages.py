#!/usr/bin/env python3
"""从 APK 索引收集模块、内核包及其依赖，其余包保留到离线归档。"""

import argparse
import functools
import json
import re
import subprocess
from collections import defaultdict
from pathlib import Path

from merge_apk_feeds import add_package


def dependency(value):
    # apk-tools 的依赖 schema 含 name/version/match；序列化器也可输出依赖字符串。
    if isinstance(value, dict):
        mask = int(value.get("match", 1 if value.get("version") else 7))
        return value["name"], value.get("version", ""), mask
    match = re.fullmatch(r"(!?)([^<>=~]+)([<>=~]*)(.*)", value)
    if not match:
        raise ValueError(f"无法识别 APK 依赖：{value}")
    conflict, name, operator, version = match.groups()
    mask = sum(bit for char, bit in (("=", 1), ("<", 2), (">", 4), ("~", 9)) if char in operator)
    return name, version, (mask or 7) | (16 if conflict else 0)


def base_name(package):
    name = package["name"]
    for tag in package.get("tags", []):
        if tag.startswith("openwrt:abiversion="):
            suffix = tag.split("=", 1)[1]
            if suffix and name.endswith(suffix):
                return name[:-len(suffix)]
    return name


def dependency_closure(packages, modules, compare):
    providers = defaultdict(list)
    for index, package in enumerate(packages):
        providers[package["name"]].append((index, package["version"]))
        for provided in package.get("provides", []):
            name, version, _ = dependency(provided)
            providers[name].append((index, version))
    selected = {index for index, package in enumerate(packages)
                if package["name"] in modules or base_name(package) in modules
                or package["name"].startswith("kmod-") or package["name"] == "kernel"}
    queue = list(selected)
    while queue:
        current = packages[queue.pop()]
        for dep in current.get("depends", []):
            name, version, mask = dependency(dep)
            if mask & 16:
                continue
            matches = set()
            for index, provided_version in providers[name]:
                if version:
                    if not provided_version:
                        continue
                    if mask & 8:
                        compatible = (provided_version == version or
                                      (provided_version.startswith(version) and
                                       provided_version[len(version):len(version) + 1] in (".", "_", "-")))
                    else:
                        result = "=" if provided_version == version else compare(provided_version, version)
                        compatible = bool(mask & {"=": 1, "<": 2, ">": 4}[result])
                    if not compatible:
                        continue
                matches.add(index)
            if not matches:
                # OpenWrt 的 kernel 依赖由已刷入固件的内核提供，不能跨 ABI 安装。
                if name == "kernel" and not providers[name]:
                    continue
                raise ValueError(f"依赖缺失或版本不兼容：{current['name']} -> {dep}")
            for index in matches - selected:
                selected.add(index)
                queue.append(index)
    return selected


def collect(args):
    roots = [args.root / "bin/packages" / args.arch,
             args.root / "bin/targets" / args.target / args.subtarget / "packages"]
    records = []
    for root in roots:
        for directory in sorted({path.parent for path in root.rglob("*.apk")}):
            index = directory / "packages.adb"
            metadata = {}
            if index.is_file():
                data = json.loads(subprocess.check_output(
                    [args.apk, "adbdump", "--format", "json", str(index)], text=True))
                for package in data.get("packages", []) if isinstance(data, dict) else data:
                    metadata[f"{package['name']}-{package['version']}.apk"] = package
            for path in sorted(directory.glob("*.apk")):
                package = metadata.get(path.name)
                if package is None:
                    data = json.loads(subprocess.check_output(
                        [args.apk, "adbdump", "--format", "json", str(path)], text=True))
                    package = data["info"]
                records.append((path, package))
    modules = set(re.findall(r"^CONFIG_PACKAGE_(.+)=m$", (args.root / ".config").read_text(), re.MULTILINE))

    @functools.cache
    def compare(left, right):
        return subprocess.check_output([args.apk, "version", "-t", left, right], text=True).strip()

    selected = dependency_closure([meta for _, meta in records], modules, compare)
    for index, (path, package) in enumerate(records):
        destination = args.kmods if package["name"].startswith("kmod-") or package["name"] == "kernel" else args.userspace
        if index not in selected:
            destination = args.output / "offline" / destination.relative_to(args.output)
        add_package(path, destination / path.name)
    print(f"【软件源】已收集 APK：feed {len(selected)} 个（含依赖与内核包），其他 {len(records) - len(selected)} 个")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("root", "output", "userspace", "kmods"):
        parser.add_argument(f"--{option}", type=Path, required=True)
    for option in ("apk", "arch", "target", "subtarget"):
        parser.add_argument(f"--{option}", required=True)
    collect(parser.parse_args())


if __name__ == "__main__":
    main()
