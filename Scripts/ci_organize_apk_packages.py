#!/usr/bin/env python3
"""整理给 Artifact/Release 下载的 APK 包；输出与 Pages feed 分离。"""

import argparse
import fnmatch
import io
import json
import re
import shutil
import subprocess
import sys
import tarfile
import zipfile
from functools import lru_cache
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


BASE_DEPENDENCIES = (
    "libc", "libgcc1", "libpthread", "zlib", "libstdcpp6", "librt", "libatomic1",
    "busybox", "base-files", "kernel", "lua", "uci", "ubus", "rpcd", "cgi-io",
    "libubox*", "libubus*", "libuci*", "liblua*", "luci-base", "luci-compat",
    "luci-lib-*", "luci-mod-*", "luci-proto-*", "rpcd-mod-*", "uhttpd",
    "uhttpd-mod-*", "procd*", "jshn", "jsonfilter",
)


def apk_metadata(path):
    """读取 APK 内的 control 元数据，供每个插件目录展开运行时依赖。"""
    with tarfile.open(path, "r:*") as package:
        control_member = next((member for member in package.getmembers()
                               if member.name.lstrip("./") == "control.tar.gz"), None)
        require(control_member is not None, f"APK 缺少 control.tar.gz：{path.name}")
        control_stream = package.extractfile(control_member)
        require(control_stream is not None, f"无法读取 APK 控制信息：{path.name}")
        with tarfile.open(fileobj=io.BytesIO(control_stream.read()), mode="r:*") as control:
            control_file = next((member for member in control.getmembers()
                                 if member.name.lstrip("./") == "control"), None)
            require(control_file is not None, f"APK 缺少 control 文件：{path.name}")
            control_data = control.extractfile(control_file)
            require(control_data is not None, f"无法读取 APK 控制信息：{path.name}")
            text = control_data.read().decode("utf-8", errors="replace")
    fields = {}
    current = None
    for line in text.splitlines():
        if line.startswith((" ", "\t")) and current:
            fields[current] += " " + line.strip()
        elif ":" in line:
            current, value = line.split(":", 1)
            fields[current] = value.strip()
    require(fields.get("Package"), f"APK 缺少 Package 字段：{path.name}")
    provides = [item.strip().split("=", 1)[0] for item in fields.get("Provides", "").split(",")]
    depends = [item.strip() for item in fields.get("Depends", "").split(",") if item.strip()]
    return {"name": fields["Package"], "version": fields.get("Version", ""),
            "provides": provides, "depends": depends}


def dependency_options(expression):
    options = []
    for item in expression.split("|"):
        item = item.strip().split(" ", 1)[0].split("(", 1)[0]
        match = re.fullmatch(r"([^<>=~]+)([<>=~]*)(.*)", item)
        if match and not match.group(1).startswith("!"):
            options.append(match.groups())
    return options


def is_base_dependency(name):
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in BASE_DEPENDENCIES)


def load_manual_groups(path):
    text = path.read_text()
    match = re.search(r"PACKAGE_OVERRIDES=\$\(cat <<'EOF'\n(.*?)\nEOF\n\)", text, re.DOTALL)
    require(match is not None, f"无法从 Organize_Packages.sh 读取 PACKAGE_OVERRIDES：{path}")
    groups = {}
    for line in match.group(1).splitlines():
        if "|" not in line:
            continue
        _, package_list = line.split("|", 1)
        packages = [item.rstrip("_") for item in package_list.split()]
        anchor = next((item for item in packages
                       if item.startswith(("luci-app-", "luci-theme-"))), None)
        if anchor:
            groups.setdefault(anchor, set()).update(packages)
    return groups


def plugin_closure(roots, by_name, by_provide, apk_tool):
    selected = {root["path"] for root in roots}
    queue = list(roots)
    while queue:
        current = queue.pop(0)
        for expression in current["meta"]["depends"]:
            resolved = None
            base_satisfied = False
            for name, operator, required_version in dependency_options(expression):
                if is_base_dependency(name):
                    base_satisfied = True
                    break
                candidates = [(item, item["meta"]["version"]) for item in by_name.get(name, [])]
                if not candidates:
                    candidates = by_provide.get(name, [])
                candidates = [(item, version) for item, version in candidates
                              if version_satisfies(version, operator, required_version, apk_tool)]
                if candidates:
                    resolved = candidates[0][0]
                    break
            if resolved and resolved["path"] not in selected:
                selected.add(resolved["path"])
                queue.append(resolved)
            elif not resolved and not base_satisfied and dependency_options(expression):
                raise ValueError(
                    f"插件依赖未包含在平台包池中：{current['meta']['name']} -> {expression}")
    return selected


def manual_group_records(plugin_name, groups, package_records):
    prefixes = groups.get(plugin_name, set())
    return [record for record in package_records
            if any(record["path"].name.startswith((prefix + "-", prefix + "_"))
                   for prefix in prefixes)]


@lru_cache(maxsize=None)
def version_satisfies(version, operator, required, apk_tool):
    if not operator or not required:
        return True
    if not version:
        return False
    if operator == "~":
        return version == required or version.startswith(required + (".", "_", "-"))
    if not apk_tool:
        raise ValueError("APK 依赖带版本约束，但未提供 host apk 工具进行版本校验")
    result = subprocess.check_output([str(apk_tool), "version", "-t", version, required], text=True).strip()
    mask = sum(bit for char, bit in (("=", 1), ("<", 2), (">", 4)) if char in operator)
    return result == "=" and bool(mask & 1) or result == "<" and bool(mask & 2) or result == ">" and bool(mask & 4)


def organize(args):
    require(args.input.is_dir(), f"缺少合并后的 feed 包目录：{args.input}")
    require(args.organize_script.is_file(), f"缺少 Organize_Packages.sh：{args.organize_script}")
    require(not args.output.exists(), f"输出目录已存在，拒绝覆盖：{args.output}")
    require(not args.artifact_output.exists(),
            f"Artifact 输出目录已存在，拒绝覆盖：{args.artifact_output}")
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
    args.artifact_output.mkdir(parents=True)
    excluded_path = args.input / "excluded-packages.json"
    excluded = json.loads(excluded_path.read_text()) if excluded_path.is_file() else []
    manual_groups = load_manual_groups(args.organize_script)
    for identity, repositories in sorted(groups.items()):
        source, revision, target, subtarget, arch = identity
        filename = f"{source}-{revision}-{target}-{subtarget}-{arch}-packages.zip"
        artifact_dir = args.artifact_output / Path(filename).stem
        artifact_dir.mkdir()
        selected_dirs = [repositories["userspace"], *repositories["kmods"]]
        platform_excluded = [item for item in excluded if any(
            Path(item["path"]).is_relative_to(path.relative_to(args.input)) for path in selected_dirs)]
        package_records = []
        for package in sorted(repositories["userspace"].glob("*.apk")):
            package_records.append({"path": package, "meta": apk_metadata(package), "kernel_id": None})
        for directory in repositories["kmods"]:
            for package in sorted(directory.glob("*.apk")):
                package_records.append({"path": package, "meta": apk_metadata(package),
                                       "kernel_id": directory.name})
        by_name = {}
        by_provide = {}
        for record in package_records:
            by_name.setdefault(record["meta"]["name"], []).append(record)
            for provided in record["meta"]["provides"]:
                by_provide.setdefault(provided, []).append(record)
        for records in (*by_name.values(), *by_provide.values()):
            records.sort(key=lambda item: item["path"].name)
        description = (
            f"平台插件包：{source} {revision} / {target}/{subtarget} / {arch}\n\n"
            "此目录及同名 ZIP 用于手动下载和保存，不是设备软件源。\n"
            "packages/：用户态插件与依赖 APK。\n"
            "kmods/<kernel_id>/：内核模块 APK、vermagic。不同 kernel_id 不可混用。\n"
            "此归档不包含 packages.adb；设备在线安装请使用对应 Pages feed。\n"
            "excluded-packages.json 记录因 Cloudflare 单文件大小限制排除的 APK。\n"
        )
        with zipfile.ZipFile(args.output / filename, "w", compression=zipfile.ZIP_STORED) as archive:
            for package in sorted(repositories["userspace"].glob("*.apk")):
                relative = Path("packages") / arch / package.name
                archive.write(package, relative.as_posix())
                destination = artifact_dir / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(package, destination)
            for directory in repositories["kmods"]:
                kernel_id = directory.name
                for item in sorted(directory.iterdir()):
                    if item.is_file() and item.name != "packages.adb":
                        relative = Path("kmods") / kernel_id / item.name
                        archive.write(item, relative.as_posix())
                        destination = artifact_dir / relative
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(item, destination)
            # 参照 Organize_Packages.sh 的功能目录，为 LuCI 插件附带可分发的完整依赖闭包。
            for record in package_records:
                name = record["meta"]["name"]
                if not name.startswith(("luci-app-", "luci-theme-")):
                    continue
                plugin_dir = artifact_dir / name
                plugin_dir.mkdir(exist_ok=True)
                related_roots = [record, *manual_group_records(name, manual_groups, package_records)]
                suffix = name.removeprefix("luci-app-").removeprefix("luci-theme-")
                translation_name = f"luci-i18n-{suffix}-zh-cn"
                translations = by_name.get(translation_name, [])
                if translations:
                    related_roots.append(translations[0])
                related = plugin_closure(related_roots, by_name, by_provide, args.apk)
                for related_record in package_records:
                    if related_record["path"] not in related:
                        continue
                    if related_record["kernel_id"]:
                        relative = Path("kmods") / related_record["kernel_id"] / related_record["path"].name
                    else:
                        relative = Path(related_record["path"].name)
                    destination = plugin_dir / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(related_record["path"], destination)
                    archive.write(related_record["path"],
                                  (Path(name) / relative).as_posix())
            platform_info = json.dumps({
                "source": source, "revision": revision, "target": target,
                "subtarget": subtarget, "arch": arch,
                "kernel_ids": [path.name for path in repositories["kmods"]],
            }, ensure_ascii=False, indent=2) + "\n"
            excluded_info = json.dumps(platform_excluded, ensure_ascii=False, indent=2) + "\n"
            for name, contents in (("平台信息.json", platform_info),
                                   ("excluded-packages.json", excluded_info),
                                   ("说明.txt", description)):
                archive.writestr(name, contents)
                (artifact_dir / name).write_text(contents)
            # ZIP 中每个插件目录另带本平台说明，解压或单独复制时保留安装提示。
            for plugin_dir in sorted(path for path in artifact_dir.iterdir() if path.is_dir()
                                     and path.name.startswith(("luci-app-", "luci-theme-"))):
                plugin_readme = (
                    f"{plugin_dir.name} 安装包及依赖\n\n"
                    "此目录包含本次 feed 中可分发的插件依赖 APK 和对应中文包（如有）。\n"
                    "将目录复制到路由器后，可使用 apk add <目录>/*.apk 安装用户态包。\n"
                    "kmods/<kernel_id>/ 中的内核模块仅适用于平台信息所列的对应内核 ABI；"
                    "请按设备当前 kernel_id 选择，不要混用。\n"
                    "固件内置依赖无需重复安装；未打包的基础系统依赖由固件提供。\n"
                )
                (plugin_dir / "说明.txt").write_text(plugin_readme)
                archive.write(plugin_dir / "说明.txt",
                              (Path(plugin_dir.name) / "说明.txt").as_posix())
    print(f"【产物】已整理 Artifact/Release 平台 APK 包：{len(groups)} 个平台目录和 ZIP")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="合并后的 feed 包目录")
    parser.add_argument("--output", type=Path, required=True, help="Artifact/Release 平台 ZIP 输出目录")
    parser.add_argument("--artifact-output", type=Path, required=True,
                        help="Artifact 内按平台分目录保存的解压后文件")
    parser.add_argument("--apk", type=Path, help="host apk 工具，用于校验依赖版本约束")
    parser.add_argument("--organize-script", type=Path,
                        default=Path(__file__).with_name("Organize_Packages.sh"),
                        help="读取手工插件分组的 Organize_Packages.sh")
    args = parser.parse_args()
    try:
        organize(args)
    except (ValueError, KeyError, OSError, tarfile.TarError,
            subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print(f"【产物】APK 包整理失败：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
