#!/usr/bin/env python3
"""CORE 导出原始构建产物；入口工作流统一整理和发布各机型固件。"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

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
        require((artifact / "firmware.tar").is_file(), f"缺少固件原始产物：{prefix}")
        feed_manifest = artifact / "feed/manifest.json"
        require(feed_manifest.is_file(), f"缺少软件源产物：{prefix}")
        feed_meta = json.loads(feed_manifest.read_text())
        tag = f"build-{meta['GITHUB_RUN_ID']}-{meta['GITHUB_RUN_ATTEMPT']}"
        require(feed_meta["deployment_tag"] == tag, f"软件源不属于本次运行：{prefix}")
        entries.append((artifact, meta))
    for directory in (args.output, args.work, args.feeds_output):
        require(not directory.exists(), f"输出目录已存在，拒绝覆盖：{directory}")
    args.output.mkdir(parents=True)
    args.work.mkdir(parents=True)
    args.feeds_output.mkdir(parents=True)
    for artifact, meta in entries:
        prefix = meta["OUTPUT_NAME_PREFIX"]
        build = (args.work / prefix).resolve()
        build.mkdir()
        with tarfile.open(artifact / "firmware.tar") as archive:
            archive.extractall(build, filter="data")
        (build / "config_mine").mkdir(exist_ok=True)
        environment = dict(os.environ, **meta, OPENWRT_PATH=str(build),
                           GITHUB_WORKSPACE=str(SCRIPTS.parent), WRT_DIR_SCRIPTS="Scripts",
                           GITHUB_ENV=str(build / "environment"), GITHUB_OUTPUT=str(build / "output"))
        for script in ("ci_organize_outputs.sh", "ci_supplement_versions_from_manifest.sh"):
            subprocess.run(["bash", str(SCRIPTS / script)], env=environment, check=True)
        destination = args.output / meta["WRT_DEVICE"] / prefix
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(build / "upload"), destination)
        shutil.move(str(artifact / "feed"), args.feeds_output / prefix)
        print(f"【固件】已按型号整理：{destination}")
    (args.work / "builds.json").write_text(json.dumps([meta for _, meta in entries], ensure_ascii=False, indent=2))


def release(args):
    entries = json.loads((args.work / "builds.json").read_text())
    for meta in entries:
        validate_metadata(meta)
        prefix = meta["OUTPUT_NAME_PREFIX"]
        directory = args.output / meta["WRT_DEVICE"] / prefix
        files = [str(path.resolve()) for path in sorted(directory.iterdir()) if path.is_file()]
        require(files, f"未找到可发布的固件：{prefix}")
        notes = str((args.work / prefix / "readme_release.txt").resolve())
        exists = subprocess.run(["gh", "release", "view", prefix], capture_output=True).returncode == 0
        if exists:
            subprocess.run(["gh", "release", "edit", prefix, "--title", prefix, "--notes-file", notes], check=True)
            subprocess.run(["gh", "release", "upload", prefix, *files, "--clobber"], check=True)
        else:
            subprocess.run(["gh", "release", "create", prefix, *files, "--title", prefix,
                            "--notes-file", notes], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    exporter = commands.add_parser("export")
    exporter.add_argument("--output", type=Path, required=True)
    organizer = commands.add_parser("organize")
    organizer.add_argument("--input", type=Path, required=True)
    organizer.add_argument("--expected-count", type=int, required=True)
    organizer.add_argument("--feeds-output", type=Path, required=True)
    for command in (organizer, commands.add_parser("release")):
        command.add_argument("--output", type=Path, required=True)
        command.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    try:
        {"export": export, "organize": organize, "release": release}[args.command](args)
    except (ValueError, KeyError, OSError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print(f"【产物】处理失败：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
