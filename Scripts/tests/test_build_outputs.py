#!/usr/bin/env python3
"""验证 CORE 交付原始产物，入口工作流按机型整理并发布固件。"""

import io
import json
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/ci_build_outputs.py"


class BuildOutputsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.inputs = self.root / "artifacts"
        self.environment = dict(os.environ, GITHUB_WORKSPACE=str(ROOT),
                                GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="1")

    def run_script(self, *arguments, environment=None):
        return subprocess.run(["python3", str(SCRIPT), *map(str, arguments)],
                              env=environment or self.environment, text=True,
                              capture_output=True, check=False)

    def export(self, device="gl-mt6000-wifi", prefix="test-build", target="glinet_gl-mt6000"):
        build = self.root / prefix
        firmware = build / "bin/targets/test/testsub"
        firmware.mkdir(parents=True)
        (build / ".config").write_text("CONFIG_PACKAGE_luci-app-demo=y\n")
        (build / "my_config.txt").write_text("CONFIG_PACKAGE_luci-app-demo=y\n")
        (build / "seed.config").write_text("CONFIG_PACKAGE_luci-app-demo=y\n")
        (firmware / f"immortalwrt-{target}-squashfs-sysupgrade.bin").write_text("固件")
        (firmware / f"immortalwrt-{target}.manifest").write_text("luci-app-demo - 1.2.3\n")
        (firmware / "config.buildinfo").write_text("不上传的构建元数据")
        (firmware / "kmod-demo.apk").write_text("不能混入固件的内核包")
        (firmware / "packages").mkdir()
        (firmware / "packages/demo.apk").write_text("不能混入固件的包")
        feed = self.root / (prefix + "-feed")
        feed.mkdir()
        (feed / "manifest.json").write_text(json.dumps({"deployment_tag": "build-123-1"}))
        (feed / "demo.apk").write_text("插件留在软件源")
        output = self.inputs / prefix
        env = dict(self.environment, OPENWRT_PATH=str(build), APK_FEED_OUT=str(feed),
                   WRT_DEVICE=device, OUTPUT_NAME_PREFIX=prefix, DEVICE_NAME_LIST=target,
                   system_content="编译说明\n多行信息", WRT_MINE_SAY="测试说明", END_TIME="D261023_T120000")
        result = self.run_script("export", "--output", output, environment=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return output

    def organize(self, count=1):
        return self.run_script("organize", "--input", self.inputs,
                               "--output", self.root / "firmware",
                               "--work", self.root / "work",
                               "--feeds-output", self.root / "feeds",
                               "--expected-count", count)

    def test_core_export_preserves_raw_firmware_and_metadata_without_organizing(self):
        artifact = self.export()
        self.assertTrue((artifact / "feed/demo.apk").is_file())
        meta = json.loads((artifact / "build.json").read_text())
        self.assertEqual(meta["WRT_DEVICE"], "gl-mt6000-wifi")
        self.assertEqual(meta["GITHUB_RUN_ID"], "123")
        self.assertEqual(meta["system_content"], "编译说明\n多行信息")
        with tarfile.open(artifact / "firmware.tar") as archive:
            names = archive.getnames()
            self.assertIn(".config", names)
            self.assertTrue(any("immortalwrt-glinet_gl-mt6000-squashfs" in name for name in names))
            self.assertFalse(any(name.endswith(".apk") for name in names))
        self.assertFalse((self.root / "test-build/upload").exists())

    def test_single_device_is_organized_and_versions_are_supplemented_in_publisher(self):
        self.export()
        result = self.organize()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        output = self.root / "firmware/gl-mt6000-wifi/test-build"
        self.assertTrue((output / "test-build_squashfs-sysupgrade.bin").is_file())
        self.assertIn("luci-app-demo (1.2.3)", (output / "readme_test-build.txt").read_text())
        self.assertIn("多行信息", (output / "readme_test-build.txt").read_text())
        self.assertEqual(list(output.rglob("*.apk")), [])
        self.assertEqual(list(output.rglob("*Packages*")), [])
        self.assertTrue((self.root / "feeds/test-build/manifest.json").is_file())
        self.assertTrue((self.root / "work/test-build/readme_release.txt").is_file())

    def test_multiple_devices_and_variants_have_separate_firmware_directories(self):
        self.export(prefix="mt6000-wifi")
        self.export(device="gl-mt6000-nowifi", prefix="mt6000-nowifi")
        self.export(device="cmiot-ax18-nowifi", prefix="ax18", target="cmiot_ax18")
        result = self.organize(3)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(list((self.root / "firmware").rglob("*.bin"))), 3)
        self.assertTrue((self.root / "firmware/cmiot-ax18-nowifi/ax18/ax18_squashfs-sysupgrade.bin").is_file())

    def test_missing_build_artifacts_prevent_organizing(self):
        self.export()
        result = self.organize(2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("产物数量", result.stderr)
        self.assertFalse((self.root / "firmware").exists())

    def test_different_attempt_is_rejected_before_organizing(self):
        artifact = self.export()
        path = artifact / "build.json"
        meta = json.loads(path.read_text())
        meta["GITHUB_RUN_ATTEMPT"] = "2"
        path.write_text(json.dumps(meta))
        result = self.organize()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("运行", result.stderr)
        self.assertFalse((self.root / "firmware").exists())

    def test_path_traversal_in_device_is_rejected(self):
        artifact = self.export()
        path = artifact / "build.json"
        meta = json.loads(path.read_text())
        meta["WRT_DEVICE"] = "../../outside"
        path.write_text(json.dumps(meta))
        result = self.organize()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "outside").exists())

    def test_unsafe_archive_is_rejected(self):
        artifact = self.export()
        with tarfile.open(artifact / "firmware.tar", "w") as archive:
            info = tarfile.TarInfo("../../escaped")
            info.size = 1
            archive.addfile(info, io.BytesIO(b"x"))
        result = self.organize()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "escaped").exists())

    def test_existing_release_uploads_only_device_firmware(self):
        self.export()
        result = self.organize()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        executable = self.root / "tools"
        executable.mkdir()
        gh = executable / "gh"
        gh.write_text("#!/usr/bin/env python3\nimport json, os, sys\n"
                      "with open(os.environ['GH_LOG'], 'a') as log: log.write(json.dumps(sys.argv[1:]) + '\\n')\n")
        gh.chmod(0o755)
        env = dict(self.environment, PATH=str(executable) + os.pathsep + os.environ["PATH"],
                   GH_LOG=str(self.root / "gh.log"))
        result = self.run_script("release", "--output", self.root / "firmware",
                                 "--work", self.root / "work", environment=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        commands = [json.loads(line) for line in (self.root / "gh.log").read_text().splitlines()]
        self.assertEqual([command[1] for command in commands], ["view", "edit", "upload"])
        self.assertEqual(commands[-1][2], "test-build")
        self.assertTrue(any(item.endswith("test-build_squashfs-sysupgrade.bin") for item in commands[-1]))
        self.assertFalse(any("Packages" in item or item.endswith(".apk") for item in commands[-1]))


if __name__ == "__main__":
    unittest.main()
