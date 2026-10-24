#!/usr/bin/env python3
"""验证一次编译的所有软件源会合并成一个完整的 Pages 站点。"""

import json
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class MergeFeedsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.inputs = self.root / "artifacts"
        self.output = self.root / "public"
        self.packages_output = self.root / "packages"
        self.apk = self.root / "apk"
        # 仅替换外部索引工具；目录合并、校验和工作流编排均使用实际代码。
        self.apk.write_text(
            "#!/usr/bin/env python3\n"
            "import json, pathlib, sys\n"
            "if sys.argv[1] == 'adbdump':\n"
            "    data = json.loads(pathlib.Path(sys.argv[-1]).read_text())\n"
            "    print(json.dumps(data['metadata']))\n"
            "    sys.exit(0)\n"
            "if sys.argv[1] == 'verify':\n"
            "    data = json.loads(pathlib.Path(sys.argv[-1]).read_text())\n"
            "    sys.exit(0 if data.get('valid', True) else 1)\n"
            "assert sys.argv[1] == 'mkndx'\n"
            "out = pathlib.Path(sys.argv[sys.argv.index('--output') + 1])\n"
            "out.write_text('\\n'.join(sorted(pathlib.Path(x).name "
            "for x in sys.argv[2:] if x.endswith('.apk'))))\n"
        )
        self.apk.chmod(0o755)

    def artifact(self, name, source="libwrt", arch="aarch64_cortex-a53",
                 target="qualcommax", subtarget="ipq60xx", kernel="1111111111111111",
                 packages=("demo-1.0.apk",), commit="a" * 40, vermagic="abi-one"):
        artifact = self.inputs / name
        prefix = f"{source}/{commit[:7]}"
        userspace = artifact / prefix / "packages" / target / subtarget / arch
        kmods = artifact / prefix / "kmods" / target / subtarget / kernel
        userspace.mkdir(parents=True)
        kmods.mkdir(parents=True)
        for package in packages:
            (userspace / package).write_text(package)
        (userspace / "packages.adb").write_text("旧索引，不得覆盖合并后的索引")
        (kmods / "kmod-demo-1.0.apk").write_text(vermagic)
        (kmods / "vermagic").write_text(vermagic + "\n")
        (artifact / "manifest.json").write_text(json.dumps({
            "source_type": source, "source_commit": commit, "source_tag": commit[:7],
            "deployment_tag": "build-123-1", "feed_host": "lin-iwrt.pages.dev",
            "arch": arch, "target": target, "subtarget": subtarget,
            "kernel_id": kernel, "vermagic": vermagic,
        }))
        return artifact

    def merge(self, count):
        return subprocess.run([
            "python3", str(ROOT / "Scripts/merge_apk_feeds.py"),
            "--input", str(self.inputs), "--output", str(self.output),
            "--expected-count", str(count), "--apk", str(self.apk),
            "--packages-output", str(self.packages_output),
            "--archives-output", str(self.root / "archives"),
        ], check=False, text=True, capture_output=True)

    def test_four_builds_share_one_site_and_rebuild_union_index(self):
        self.artifact("ax18", packages=("demo-1.0.apk", "frps-1.0.apk"))
        self.artifact("ax6600", packages=("demo-1.0.apk", "wifi-1.0.apk"))
        self.artifact("mt6000-wifi", source="immortalwrt", arch="aarch64_cortex-a53",
                      target="mediatek", subtarget="filogic", commit="b" * 40)
        self.artifact("mt6000-nowifi", source="immortalwrt", arch="aarch64_cortex-a53",
                      target="mediatek", subtarget="filogic", commit="b" * 40,
                      kernel="2222222222222222", vermagic="abi-two")
        result = self.merge(4)
        self.assertEqual(result.returncode, 0, result.stderr)
        index = self.output / "libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/packages.adb"
        self.assertEqual(index.read_text().splitlines(),
                         ["demo-1.0.apk", "frps-1.0.apk", "wifi-1.0.apk"])
        self.assertTrue((self.output / "immortalwrt/bbbbbbb/packages/mediatek/filogic/aarch64_cortex-a53/demo-1.0.apk").is_file())
        kmods = self.output / "immortalwrt/bbbbbbb/kmods/mediatek/filogic"
        self.assertEqual((kmods / "1111111111111111/vermagic").read_text().strip(), "abi-one")
        self.assertEqual((kmods / "2222222222222222/vermagic").read_text().strip(), "abi-two")
        self.assertTrue((self.output / "index.html").is_file())
        self.assertEqual(
            sorted(path.relative_to(self.packages_output).as_posix()
                   for path in self.packages_output.rglob("*.apk")),
            [
                "feed/immortalwrt/bbbbbbb/kmods/mediatek/filogic/1111111111111111/kmod-demo-1.0.apk",
                "feed/immortalwrt/bbbbbbb/kmods/mediatek/filogic/2222222222222222/kmod-demo-1.0.apk",
                "feed/immortalwrt/bbbbbbb/packages/mediatek/filogic/aarch64_cortex-a53/demo-1.0.apk",
                "feed/libwrt/aaaaaaa/kmods/qualcommax/ipq60xx/1111111111111111/kmod-demo-1.0.apk",
                "feed/libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/demo-1.0.apk",
                "feed/libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/frps-1.0.apk",
                "feed/libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/wifi-1.0.apk",
            ],
        )
        archived_index = self.packages_output / "feed/libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/packages.adb"
        self.assertEqual(archived_index.read_text(), index.read_text())
        self.assertFalse((self.output / "manifest.json").exists())

    def test_different_plugin_versions_are_both_in_feed_and_platform_archive(self):
        first = self.artifact("one", packages=("demo-1.0.apk",))
        second = self.artifact("two", packages=("demo-2.0.apk",))
        (second / "libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/demo-2.0.apk").write_text("demo 2.0")
        result = self.merge(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        directory = self.output / "libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53"
        self.assertEqual((directory / "packages.adb").read_text().splitlines(),
                         ["demo-1.0.apk", "demo-2.0.apk"])
        with zipfile.ZipFile(next((self.root / "archives").glob("*.zip"))) as archive:
            names = archive.namelist()
            self.assertIn("feed/libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/demo-1.0.apk", names)
            self.assertIn("feed/libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/demo-2.0.apk", names)

    def test_same_filename_different_content_keeps_one_deterministically(self):
        first = self.artifact("one")
        second = self.artifact("two")
        relative = "libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/demo-1.0.apk"
        (first / relative).write_text("first artifact")
        (second / relative).write_text("second artifact")
        result = self.merge(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output / relative).read_text(), "first artifact")

    def test_offline_packages_are_preserved_and_deduplicated_without_deploying_them(self):
        for name in ("one", "two"):
            artifact = self.artifact(name)
            offline = artifact / "offline/libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53"
            offline.mkdir(parents=True)
            (offline / "builtin-1.0.apk").write_text("内置包与依赖")
        result = self.merge(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(list(self.packages_output.glob("offline/**/*.apk")))
        self.assertEqual(list(self.output.rglob("builtin-1.0.apk")), [])

    def test_offline_variants_are_not_in_final_platform_package_archive(self):
        first = self.artifact("ax18")
        second = self.artifact("ax6600")
        relative = Path("libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/builtin-1.0.apk")
        for artifact, content in ((first, b"AX18 built-in package"), (second, b"AX6600 built-in package")):
            offline = artifact / "offline" / relative.parent
            offline.mkdir(parents=True)
            (offline / relative.name).write_bytes(content)
        result = self.merge(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.output.rglob("builtin-1.0.apk")), [])
        self.assertFalse(list(self.packages_output.glob("offline/**/*.apk")))
        archives = list((self.root / "archives").glob("*.zip"))
        archived_files = {}
        for path in archives:
            with zipfile.ZipFile(path) as archive:
                for name in archive.namelist():
                    if name.endswith("builtin-1.0.apk"):
                        archived_files[name] = archive.read(name)
        self.assertEqual(archived_files, {})

    def test_offline_package_already_in_another_devices_feed_is_stored_once(self):
        first = self.artifact("one", packages=("builtin-1.0.apk",))
        second = self.artifact("two", packages=())
        offline = second / "offline/libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53"
        offline.mkdir(parents=True)
        (offline / "builtin-1.0.apk").write_bytes(
            (first / "libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/builtin-1.0.apk").read_bytes())
        result = self.merge(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list((self.packages_output / "feed").rglob("builtin-1.0.apk"))), 1)

    def test_offline_package_is_not_added_even_when_feed_has_same_name(self):
        first = self.artifact("one", packages=("builtin-1.0.apk",))
        second = self.artifact("two", packages=())
        relative = Path("libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/builtin-1.0.apk")
        offline = second / "offline" / relative.parent
        offline.mkdir(parents=True)
        (offline / relative.name).write_text("设备专用离线版本")
        result = self.merge(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output / relative).read_text(), "builtin-1.0.apk")
        self.assertEqual(len(list((self.packages_output / "feed").rglob("builtin-1.0.apk"))), 1)

    def test_empty_feed_host_still_creates_one_package_archive(self):
        artifact = self.artifact("one")
        path = artifact / "manifest.json"
        meta = json.loads(path.read_text())
        meta["feed_host"] = ""
        path.write_text(json.dumps(meta))
        result = self.merge(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.packages_output / "feed/index.html").is_file())

    def test_platforms_with_same_source_and_arch_do_not_share_userspace(self):
        self.artifact("ipq")
        second = self.artifact("mtk", target="mediatek", subtarget="filogic")
        relative = "libwrt/aaaaaaa/packages/mediatek/filogic/aarch64_cortex-a53/demo-1.0.apk"
        (second / relative).write_text("平台不同，内容允许不同")
        result = self.merge(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        archives = sorted((self.root / "archives").glob("*.zip"))
        self.assertEqual([path.name for path in archives], [
            "libwrt-aaaaaaa-mediatek-filogic-aarch64_cortex-a53-packages.zip",
            "libwrt-aaaaaaa-qualcommax-ipq60xx-aarch64_cortex-a53-packages.zip",
        ])
        with zipfile.ZipFile(archives[0]) as archive:
            self.assertIn("feed/" + relative, archive.namelist())
            self.assertFalse(any("ipq60xx" in name for name in archive.namelist()))

    def test_limit_and_larger_packages_are_excluded_from_feed_and_archive(self):
        artifact = self.artifact("one", packages=("demo-1.0.apk", "boundary-1.0.apk", "large-1.0.apk"))
        directory = artifact / "libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53"
        for name, size in (("boundary", 25 * 1024 * 1024), ("large", 25 * 1024 * 1024 + 1)):
            with (directory / f"{name}-1.0.apk").open("wb") as stream:
                stream.truncate(size)
        result = self.merge(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        index = self.output / directory.relative_to(artifact) / "packages.adb"
        self.assertEqual(index.read_text(), "demo-1.0.apk")
        self.assertEqual(len(list(self.output.rglob("*.apk"))), 2)  # 小插件与 kmod
        report = json.loads((self.output / "excluded-packages.json").read_text())
        self.assertEqual(len(report), 2)
        with zipfile.ZipFile(next((self.root / "archives").glob("*.zip"))) as archive:
            names = archive.namelist()
            self.assertFalse(any(name.endswith(("boundary-1.0.apk", "large-1.0.apk")) for name in names))

    def test_final_platform_archive_contains_only_feed_packages(self):
        artifact = self.artifact("one")
        offline = artifact / "offline/libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53"
        offline.mkdir(parents=True)
        (offline / "builtin-1.0.apk").write_text("offline only")
        result = self.merge(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(next((self.root / "archives").glob("*.zip"))) as archive:
            self.assertFalse(any(name.startswith("offline/") or "/offline/" in name for name in archive.namelist()))
            self.assertFalse(any(name.endswith("builtin-1.0.apk") for name in archive.namelist()))

    def test_same_filename_with_different_content_uses_deterministic_first_copy(self):
        first = self.artifact("one")
        second = self.artifact("two")
        (second / "libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/demo-1.0.apk").write_text("冲突内容")
        result = self.merge(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output / "libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/demo-1.0.apk").read_text(),
                         "demo-1.0.apk")

    def test_identical_package_signed_by_different_builds_is_deduplicated(self):
        first = self.artifact("one")
        second = self.artifact("two")
        relative = "libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/demo-1.0.apk"
        metadata = {"info": {"name": "demo", "version": "1.0"},
                    "paths": [{"name": "usr/bin/demo", "hash": "same-payload-hash"}]}
        (first / relative).write_text(json.dumps({"signature": "key-one", "metadata": metadata}))
        (second / relative).write_text(json.dumps({"signature": "key-two", "metadata": metadata}))
        result = self.merge(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.output / relative).is_file())

    def test_same_version_with_different_payload_keeps_deterministic_first_copy(self):
        first = self.artifact("one")
        second = self.artifact("two")
        relative = "libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/demo-1.0.apk"
        metadata = {"info": {"name": "demo"}, "paths": [{"hash": "same-hash"}]}
        (first / relative).write_text(json.dumps({"metadata": metadata}))
        (second / relative).write_text(json.dumps({"metadata": metadata, "valid": False}))
        result = self.merge(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output / relative).read_text(), (first / relative).read_text())

    def test_same_version_metadata_difference_keeps_deterministic_first_copy(self):
        first = self.artifact("one")
        second = self.artifact("two")
        relative = "libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/demo-1.0.apk"
        (first / relative).write_text(json.dumps({"metadata": {"paths": [{"hash": "one"}]}}))
        (second / relative).write_text(json.dumps({"metadata": {"paths": [{"hash": "two"}]}}))
        result = self.merge(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output / relative).read_text(), (first / relative).read_text())

    def test_empty_userspace_still_has_a_valid_repository_index(self):
        self.artifact("one", packages=())
        result = self.merge(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        index = self.output / "libwrt/aaaaaaa/packages/qualcommax/ipq60xx/aarch64_cortex-a53/packages.adb"
        self.assertTrue(index.is_file())
        self.assertEqual(index.read_text(), "")

    def test_different_source_commits_are_rejected_within_one_source(self):
        self.artifact("one")
        self.artifact("two", commit="c" * 40)
        result = self.merge(2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("源码提交不一致", result.stderr)

    def test_missing_artifacts_are_rejected(self):
        self.artifact("one")
        result = self.merge(2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("产物数量", result.stderr)

    def test_same_kernel_directory_requires_matching_vermagic(self):
        self.artifact("one")
        self.artifact("two", vermagic="abi-two")
        result = self.merge(2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("内核 ABI 不一致", result.stderr)

    def test_different_runs_cannot_be_mixed(self):
        self.artifact("one")
        second = self.artifact("two")
        path = second / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["deployment_tag"] = "build-456-1"
        path.write_text(json.dumps(manifest))
        result = self.merge(2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("发布标识不一致", result.stderr)


if __name__ == "__main__":
    unittest.main()
