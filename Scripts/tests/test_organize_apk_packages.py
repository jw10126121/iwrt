#!/usr/bin/env python3
"""验证下载用 APK 归档独立于 Pages feed，并按平台整理。"""

import json
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/ci_organize_apk_packages.py"


class OrganizeApkPackagesTest(unittest.TestCase):
    def test_platform_archive_is_curated_and_not_a_feed_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            feed = root / "feed"
            userspace = feed / "libwrt/abc1234/packages/qualcommax/ipq60xx/aarch64_cortex-a53"
            kmods = feed / "libwrt/abc1234/kmods/qualcommax/ipq60xx/kernel-one"
            userspace.mkdir(parents=True)
            kmods.mkdir(parents=True)
            (userspace / "packages.adb").write_text("index")
            (userspace / "demo-1.0.apk").write_bytes(b"1.0")
            (userspace / "demo-2.0.apk").write_bytes(b"2.0")
            (kmods / "packages.adb").write_text("index")
            (kmods / "vermagic").write_text("abi\n")
            (kmods / "kmod-demo-1.0.apk").write_bytes(b"kmod")
            (feed / "excluded-packages.json").write_text("[]\n")
            output = root / "organized"
            result = subprocess.run(["python3", str(SCRIPT), "--input", str(feed),
                                     "--output", str(output)], text=True,
                                    capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            archive_path = output / "libwrt-abc1234-qualcommax-ipq60xx-aarch64_cortex-a53-packages.zip"
            self.assertTrue(archive_path.is_file())
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


if __name__ == "__main__":
    unittest.main()
