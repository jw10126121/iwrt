#!/usr/bin/env python3
"""CORE 导出原始构建产物；入口工作流统一整理平台固件与插件包并发布。"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path

from ci_platform import platform_archive_name, platform_identity

SCRIPTS = Path(__file__).resolve().parent
METADATA_KEYS = (
    "WRT_DEVICE", "OUTPUT_NAME_PREFIX", "DEVICE_NAME_LIST", "system_content",
    "WRT_MINE_SAY", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "END_TIME",
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_metadata(meta):
    for key in METADATA_KEYS:
        require(isinstance(meta.get(key), str), f"构建元数据缺失或无效：{key}")
    for key in ("WRT_DEVICE", "OUTPUT_NAME_PREFIX"):
        require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", meta[key]), f"无效的构建标识：{key}")
    for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"):
        require(meta[key] and meta[key] == os.environ.get(key), f"构建产物不属于本次运行：{key}")


def validate_feed_branch(feed_meta):
    platform_identity(feed_meta)
    require(feed_meta.get("deployment_tag") == feed_meta.get("source_tag"),
            "软件源部署分支必须与源码短 Hash 一致")


def export(args):
    root = Path(os.environ["OPENWRT_PATH"])
    feed = Path(os.environ.get("APK_FEED_OUT", str(Path(os.environ["GITHUB_WORKSPACE"]) / "feed-out")))
    meta = {key: os.environ.get(key, "") for key in METADATA_KEYS}
    validate_metadata(meta)
    require((feed / "manifest.json").is_file(), "缺少软件源产物")
    for name in (".config", "my_config.txt"):
        require((root / name).is_file(), f"缺少构建配置：{name}")
    require((root / "bin/targets").is_dir(), "缺少固件原始目录")
    require(not args.output.exists(), f"原始产物目录已存在：{args.output}")
    args.output.mkdir(parents=True)
    # 只封装原始固件和配置，不在 CORE 重命名、生成说明或分类压缩安装包。
    # APK 已由 feed 完整携带，不能再塞入固件传输包。
    with tarfile.open(args.output / "firmware.tar", "w", dereference=True) as archive:
        for name in (".config", "my_config.txt", "seed.config"):
            if (root / name).is_file():
                archive.add(root / name, arcname=name)
        for path in sorted((root / "bin/targets").rglob("*")):
            if path.is_file() and path.suffix != ".apk" and "packages" not in path.relative_to(root).parts:
                archive.add(path, arcname=path.relative_to(root))
    (args.output / "build.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
    shutil.move(str(feed), args.output / "feed")
    print(f"【产物】已导出原始构建：{meta['WRT_DEVICE']} / {meta['OUTPUT_NAME_PREFIX']}")


def prepare_firmware(artifact, meta, build):
    build.mkdir()
    with tarfile.open(artifact / "firmware.tar") as archive:
        archive.extractall(build, filter="data")
    (build / "config_mine").mkdir(exist_ok=True)
    environment = dict(os.environ, **meta, OPENWRT_PATH=str(build),
                       GITHUB_WORKSPACE=str(SCRIPTS.parent), WRT_DIR_SCRIPTS="Scripts",
                       GITHUB_ENV=str(build / "environment"), GITHUB_OUTPUT=str(build / "output"))
    for script in ("ci_organize_outputs.sh", "ci_supplement_versions_from_manifest.sh"):
        subprocess.run(["bash", str(SCRIPTS / script)], env=environment, check=True)


def add_tree(archive, root, prefix, exclude=()):
    for path in sorted(root.rglob("*")):
        if path.is_file() and not any(part in exclude for part in path.relative_to(root).parts):
            archive.write(path, (Path(prefix) / path.relative_to(root)).as_posix())


def extract_firmware_zip(archive_path, destination):
    destination.mkdir(parents=True)
    root = destination.resolve()
    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.infolist():
            path = (destination / member.filename).resolve()
            require(path == root or root in path.parents, f"固件 ZIP 含有非法路径：{member.filename}")
            if member.is_dir():
                path.mkdir(parents=True, exist_ok=True)
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as source, path.open("wb") as output:
                shutil.copyfileobj(source, output)


def ready(args):
    artifact = args.input
    meta = json.loads((artifact / "build.json").read_text())
    validate_metadata(meta)
    require((artifact / "firmware.tar").is_file(), "缺少固件原始产物")
    feed = artifact / "feed"
    feed_manifest = feed / "manifest.json"
    require(feed_manifest.is_file(), "缺少软件源产物")
    feed_meta = json.loads(feed_manifest.read_text())
    validate_feed_branch(feed_meta)
    require(not args.firmware_output.exists(), f"输出目录已存在，拒绝覆盖：{args.firmware_output}")
    args.firmware_output.mkdir(parents=True)
    prefix = meta["OUTPUT_NAME_PREFIX"]
    firmware_zip = args.firmware_output / f"{prefix}-firmware.zip"
    with tempfile.TemporaryDirectory(prefix="iwrt-ready-") as temporary:
        build = Path(temporary) / prefix
        prepare_firmware(artifact, meta, build)
        upload = build / "upload"
        require(upload.is_dir() and any(upload.iterdir()), f"未生成可用固件：{prefix}")
        with zipfile.ZipFile(firmware_zip, "w", compression=zipfile.ZIP_STORED) as archive:
            add_tree(archive, upload, "")
    print(f"【产物】单固件信息包已整理：{firmware_zip.name}")


def organize(args):
    manifests = sorted(args.input.glob("*/build.json"))
    require(len(manifests) == args.expected_count and manifests,
            f"构建产物数量不完整：预期 {args.expected_count}，实际 {len(manifests)}")
    entries = []
    prefixes = set()
    # 先完整校验跨任务接口，再开始生成最终目录。
    for manifest in manifests:
        meta = json.loads(manifest.read_text())
        validate_metadata(meta)
        prefix = meta["OUTPUT_NAME_PREFIX"]
        require(prefix not in prefixes, f"构建标识重复：{prefix}")
        prefixes.add(prefix)
        artifact = manifest.parent
        feed_manifest = artifact / "feed/manifest.json"
        require(feed_manifest.is_file(), f"缺少软件源产物：{prefix}")
        feed_meta = json.loads(feed_manifest.read_text())
        validate_feed_branch(feed_meta)
        firmware_artifact = args.firmware_input / f"{prefix}-firmware"
        firmware_zip = firmware_artifact / f"{prefix}-firmware.zip"
        require(firmware_zip.is_file(), f"缺少单设备固件包：{prefix}")
        entries.append((artifact, firmware_artifact, meta, feed_meta))
    for directory in (args.output, args.platform_firmware_output, args.work, args.feeds_output):
        require(not directory.exists(), f"输出目录已存在，拒绝覆盖：{directory}")
    args.output.mkdir(parents=True)
    args.platform_firmware_output.mkdir(parents=True)
    args.work.mkdir(parents=True)
    args.feeds_output.mkdir(parents=True)
    platform_builds = {}
    for artifact, firmware_artifact, meta, feed_meta in entries:
        prefix = meta["OUTPUT_NAME_PREFIX"]
        destination = args.output / meta["WRT_DEVICE"] / prefix
        extract_firmware_zip(firmware_artifact / f"{prefix}-firmware.zip", destination)
        work = args.work / prefix
        work.mkdir()
        readmes = sorted(destination.glob(f"readme_{prefix}.txt"))
        require(readmes, f"固件包缺少说明文件：{prefix}")
        shutil.copy2(readmes[0], work / "readme_release.txt")
        shutil.move(str(artifact / "feed"), args.feeds_output / prefix)
        platform_builds.setdefault(platform_identity(feed_meta), []).append(
            (feed_meta, meta, destination))
        print(f"【固件】已按型号整理：{destination}")
    for builds in platform_builds.values():
        feed_meta = builds[0][0]
        archive_path = args.platform_firmware_output / platform_archive_name(feed_meta, "firmware")
        platform_info = {key: feed_meta[key] for key in (
            "source_type", "source_tag", "target", "subtarget", "arch")}
        platform_info["builds"] = [
            {"device": meta["WRT_DEVICE"], "prefix": meta["OUTPUT_NAME_PREFIX"]}
            for _, meta, _ in builds
        ]
        description = (
            "此平台固件包汇总本次构建中该平台的所有设备及配置变体。\n"
            "devices/<构建前缀>/ 内分别包含固件镜像、配置和说明文件。\n"
        )
        with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_STORED) as archive:
            for _, meta, directory in builds:
                add_tree(archive, directory, f"devices/{meta['OUTPUT_NAME_PREFIX']}")
            archive.writestr("平台信息.json", json.dumps(platform_info, ensure_ascii=False, indent=2) + "\n")
            archive.writestr("说明.txt", description)
    (args.work / "builds.json").write_text(
        json.dumps([meta for _, _, meta, _ in entries], ensure_ascii=False, indent=2))


def release_platforms(args):
    entries = json.loads((args.work / "builds.json").read_text())
    require(entries, "没有构建元数据，无法发布平台归档")
    for meta in entries:
        validate_metadata(meta)
    first = entries[0]
    tag = f"build-outputs-{first['GITHUB_RUN_ID']}-{first['GITHUB_RUN_ATTEMPT']}"
    files = []
    firmware_names = []
    plugin_names = []
    if args.firmware:
        firmware_names = sorted(args.firmware_input.glob("*-firmware.zip"))
        require(firmware_names, f"未找到平台固件包：{args.firmware_input}")
        files.extend(firmware_names)
    if args.packages:
        plugin_names = sorted(args.plugins_input.glob("*-plugins.zip"))
        require(plugin_names, f"未找到平台插件包：{args.plugins_input}")
        files.extend(plugin_names)
    require(files, "至少需要选择平台固件包或平台插件包")
    if args.firmware and args.packages:
        firmware_stems = {path.name.removesuffix("-firmware.zip") for path in firmware_names}
        plugin_stems = {path.name.removesuffix("-plugins.zip") for path in plugin_names}
        require(firmware_stems == plugin_stems, "平台固件包与插件包不成对")
    notes = args.work / "build-outputs-release-notes.txt"
    notes.write_text("本次工作流按源码版本、平台和架构整理的固件包与 APK 插件包。\n"
                     "固件 ZIP 按设备/配置变体分目录保存；插件 ZIP 含用户态 APK、内核模块和 vermagic，\n"
                     "不含 packages.adb 软件源索引或 offline 包。\n")
    exists = subprocess.run(["gh", "release", "view", tag], capture_output=True).returncode == 0
    if exists:
        subprocess.run(["gh", "release", "edit", tag, "--title", tag,
                        "--notes-file", str(notes)], check=True)
        subprocess.run(["gh", "release", "upload", tag, *files, "--clobber"], check=True)
    else:
        subprocess.run(["gh", "release", "create", tag, *files, "--title", tag,
                        "--notes-file", str(notes)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    exporter = commands.add_parser("export")
    exporter.add_argument("--output", type=Path, required=True)
    ready_parser = commands.add_parser("ready")
    ready_parser.add_argument("--input", type=Path, required=True)
    ready_parser.add_argument("--firmware-output", type=Path, required=True)
    organizer = commands.add_parser("organize")
    organizer.add_argument("--input", type=Path, required=True)
    organizer.add_argument("--firmware-input", type=Path, required=True)
    organizer.add_argument("--platform-firmware-output", type=Path, required=True)
    organizer.add_argument("--expected-count", type=int, required=True)
    organizer.add_argument("--feeds-output", type=Path, required=True)
    organizer.add_argument("--output", type=Path, required=True)
    organizer.add_argument("--work", type=Path, required=True)
    releaser = commands.add_parser("release-platforms")
    releaser.add_argument("--work", type=Path, required=True)
    releaser.add_argument("--firmware-input", type=Path, required=True)
    releaser.add_argument("--plugins-input", type=Path, required=True)
    releaser.add_argument("--firmware", action="store_true")
    releaser.add_argument("--packages", action="store_true")
    args = parser.parse_args()
    try:
        {"export": export, "ready": ready, "organize": organize,
         "release-platforms": release_platforms}[args.command](args)
    except (ValueError, KeyError, OSError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print(f"【产物】处理失败：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
