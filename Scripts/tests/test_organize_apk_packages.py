#!/usr/bin/env python3
"""验证下载用 APK 归档独立于 Pages feed，并按平台整理。"""

import json
import io
import subprocess
import tempfile
import tarfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/ci_organize_apk_packages.py"


def write_test_apk(path, package, depends="", provides="", payload_size=0):
    control = f"Package: {package}\nVersion: 1\n"
    if depends:
        control += f"Depends: {depends}\n"
    if provides:
        control += f"Provides: {provides}\n"
    control_bytes = control.encode()
    nested = io.BytesIO()
    with tarfile.open(fileobj=nested, mode="w:gz") as archive:
        info = tarfile.TarInfo("./control")
        info.size = len(control_bytes)
        archive.addfile(info, io.BytesIO(control_bytes))
    outer = io.BytesIO()
    with tarfile.open(fileobj=outer, mode="w") as archive:
        payload = nested.getvalue()
        info = tarfile.TarInfo("./control.tar.gz")
        info.size = len(payload)
        archive.addfile(info, io.BytesIO(payload))
        if payload_size:
            info = tarfile.TarInfo("./data")
            info.size = payload_size
            archive.addfile(info, io.BytesIO(b"\0" * payload_size))
    path.write_bytes(outer.getvalue())


class OrganizeApkPackagesTest(unittest.TestCase):
    def test_standalone_pool_without_indexes_archives_oversized_apks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plugin_pool = root / "plugins"
            userspace = plugin_pool / "libwrt/abc1234/packages/qualcommax/ipq60xx/aarch64_cortex-a53"
            userspace.mkdir(parents=True)
            write_test_apk(userspace / "large-1.0.apk", "large", payload_size=25 * 1024 * 1024)
            archives = root / "archives"
            result = subprocess.run([
                "python3", str(SCRIPT), "--input", str(plugin_pool), "--output", str(archives),
                "--artifact-output", str(root / "artifact")],
                text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            archive_path = archives / "libwrt-abc1234-qualcommax-ipq60xx-aarch64_cortex-a53-plugins.zip"
            with zipfile.ZipFile(archive_path) as archive:
                names = archive.namelist()
                self.assertIn("packages/aarch64_cortex-a53/large-1.0.apk", names)
                self.assertFalse(any(name.endswith("packages.adb") for name in names))

    def test_platform_archive_is_curated_and_not_a_feed_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            feed = root / "feed"
            userspace = feed / "libwrt/abc1234/packages/qualcommax/ipq60xx/aarch64_cortex-a53"
            kmods = feed / "libwrt/abc1234/kmods/qualcommax/ipq60xx/kernel-one"
            filogic = feed / "libwrt/abc1234/packages/mediatek/filogic/aarch64_cortex-a53"
            userspace.mkdir(parents=True)
            kmods.mkdir(parents=True)
            filogic.mkdir(parents=True)
            (userspace / "packages.adb").write_text("index")
            write_test_apk(userspace / "demo-1.0.apk", "demo")
            write_test_apk(userspace / "demo-2.0.apk", "demo")
            (kmods / "packages.adb").write_text("index")
            (kmods / "vermagic").write_text("abi\n")
            write_test_apk(kmods / "kmod-demo-1.0.apk", "kmod-demo")
            (filogic / "packages.adb").write_text("index")
            write_test_apk(filogic / "demo-1.0.apk", "demo")
            (feed / "excluded-packages.json").write_text("[]\n")
            output = root / "organized"
            artifact_output = root / "artifact"
            result = subprocess.run(["python3", str(SCRIPT), "--input", str(feed),
                                     "--output", str(output), "--artifact-output",
                                     str(artifact_output)], text=True,
                                    capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            archive_path = output / "libwrt-abc1234-qualcommax-ipq60xx-aarch64_cortex-a53-plugins.zip"
            self.assertTrue(archive_path.is_file())
            second_archive = output / "libwrt-abc1234-mediatek-filogic-aarch64_cortex-a53-plugins.zip"
            self.assertTrue(second_archive.is_file())
            with zipfile.ZipFile(archive_path) as archive:
                names = archive.namelist()
                self.assertIn("packages/aarch64_cortex-a53/demo-1.0.apk", names)
                self.assertIn("packages/aarch64_cortex-a53/demo-2.0.apk", names)
                self.assertIn("kmods/kernel-one/kmod-demo-1.0.apk", names)
                self.assertIn("kmods/kernel-one/vermagic", names)
                self.assertIn("平台信息.json", names)
                self.assertIn("说明.txt", names)
                self.assertFalse(any(name.endswith("packages.adb") for name in names))
                self.assertFalse(any(name.startswith("feed/") or name.startswith("offline/") for name in names))
                self.assertEqual(json.loads(archive.read("平台信息.json"))["kernel_ids"], ["kernel-one"])

            platform_dir = artifact_output / archive_path.stem
            self.assertTrue((platform_dir / "packages/aarch64_cortex-a53/demo-1.0.apk").is_file())
            self.assertTrue((platform_dir / "packages/aarch64_cortex-a53/demo-2.0.apk").is_file())
            self.assertTrue((platform_dir / "kmods/kernel-one/kmod-demo-1.0.apk").is_file())
            self.assertTrue((platform_dir / "平台信息.json").is_file())
            self.assertTrue((platform_dir / "说明.txt").is_file())
            self.assertFalse(any(platform_dir.rglob("*.zip")))
            second_platform_dir = artifact_output / second_archive.stem
            self.assertTrue((second_platform_dir / "packages/aarch64_cortex-a53/demo-1.0.apk").is_file())
            self.assertFalse(any(second_platform_dir.rglob("*.zip")))

    def test_adb_packages_use_host_apk_metadata_for_dependency_closure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            feed = root / "feed"
            userspace = feed / "immortalwrt/abc1234/packages/mediatek/filogic/aarch64_cortex-a53"
            userspace.mkdir(parents=True)
            (userspace / "packages.adb").write_text("index")
            (userspace / "luci-app-adbdemo_1.apk").write_bytes(b"ADBd" + b"binary package body")
            write_test_apk(userspace / "libhelper_1.apk", "libhelper")
            (feed / "excluded-packages.json").write_text("[]\n")

            apk_tool = root / "run-apk"
            apk_tool.write_text(
                "#!/usr/bin/env python3\n"
                "import json, sys\n"
                "if sys.argv[1:4] == ['adbdump', '--format', 'json'] and len(sys.argv) == 5:\n"
                "    print(json.dumps({'info': {'name': 'luci-app-adbdemo', 'version': '1.0', "
                "'depends': ['libhelper>=1'], 'provides': []}, 'paths': [], 'scripts': {}, "
                "'triggers': [], 'replaces-priority': 0}))\n"
                "elif sys.argv[1] == 'version':\n"
                "    print('=')\n"
                "else:\n"
                "    raise SystemExit(2)\n"
            )
            apk_tool.chmod(0o755)

            archives = root / "archives"
            artifact = root / "artifact"
            result = subprocess.run([
                "python3", str(SCRIPT), "--input", str(feed), "--output", str(archives),
                "--artifact-output", str(artifact), "--apk", str(apk_tool)],
                text=True, capture_output=True, check=False)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            plugin_dir = artifact / "immortalwrt-abc1234-mediatek-filogic-aarch64_cortex-a53-plugins/luci-app-adbdemo"
            self.assertEqual({path.name for path in plugin_dir.glob("*.apk")}, {
                "luci-app-adbdemo_1.apk", "libhelper_1.apk"})

    def test_plugin_directory_contains_recursive_runtime_and_translation_dependencies(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            feed = root / "feed"
            userspace = feed / "libwrt/abc1234/packages/qualcommax/ipq60xx/aarch64_cortex-a53"
            userspace.mkdir(parents=True)
            (userspace / "packages.adb").write_text("index")

            write_test_apk(userspace / "luci-app-socat_1.apk", "luci-app-socat", "libhelper>=1")
            write_test_apk(userspace / "luci-i18n-socat-zh-cn_1.apk", "luci-i18n-socat-zh-cn")
            write_test_apk(userspace / "libhelper_1.apk", "libhelper", "libbase")
            write_test_apk(userspace / "libbase_1.apk", "libbase")
            write_test_apk(userspace / "socat-1.apk", "socat", "libsocket")
            write_test_apk(userspace / "libsocket-1.apk", "libsocket")
            write_test_apk(userspace / "unrelated_1.apk", "unrelated")
            feed.joinpath("excluded-packages.json").write_text("[]\n")
            archives = root / "archives"
            artifact = root / "artifact"
            apk_tool = root / "run-apk"
            apk_tool.write_text("#!/bin/sh\nprintf '=\\n'\n")
            apk_tool.chmod(0o755)
            result = subprocess.run([
                "python3", str(SCRIPT), "--input", str(feed), "--output", str(archives),
                "--artifact-output", str(artifact), "--apk", str(apk_tool)],
                text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            platform_dir = artifact / "libwrt-abc1234-qualcommax-ipq60xx-aarch64_cortex-a53-plugins"
            plugin_dir = platform_dir / "luci-app-socat"
            self.assertEqual({path.name for path in plugin_dir.glob("*.apk")}, {
                "luci-app-socat_1.apk", "luci-i18n-socat-zh-cn_1.apk",
                "libhelper_1.apk", "libbase_1.apk", "socat-1.apk", "libsocket-1.apk"})
            with zipfile.ZipFile(archives / "libwrt-abc1234-qualcommax-ipq60xx-aarch64_cortex-a53-plugins.zip") as archive:
                names = set(archive.namelist())
            self.assertIn("luci-app-socat/luci-app-socat_1.apk", names)
            self.assertIn("luci-app-socat/libbase_1.apk", names)
            self.assertNotIn("luci-app-socat/unrelated_1.apk", names)


if __name__ == "__main__":
    unittest.main()
