#!/usr/bin/env python3
"""验证固件整理与发布模式无关，不重复生成机型安装包归档。"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class OrganizeOutputsTest(unittest.TestCase):
    def organize(self, root, release):
        for directory in ("bin/packages/testarch/base", "bin/targets/test/testsub", "config_mine"):
            (root / directory).mkdir(parents=True)
        (root / ".config").write_text("CONFIG_PACKAGE_demo=m\n")
        (root / "my_config.txt").write_text("配置\n")
        (root / "bin/packages/testarch/base/demo-1.0.apk").write_text("用户态包")
        (root / "bin/targets/test/testsub/kmod-demo-1.0.apk").write_text("内核模块")
        (root / "bin/targets/test/testsub/firmware.bin").write_text("固件")
        environment = dict(os.environ, OPENWRT_PATH=str(root), GITHUB_WORKSPACE=str(ROOT),
                           WRT_DIR_SCRIPTS="Scripts", OUTPUT_NAME_PREFIX="test-build",
                           WRT_RELEASE_FIRMWARE=str(release).lower(),
                           GITHUB_ENV=str(root / "environment"), GITHUB_OUTPUT=str(root / "output"),
                           DEVICE_NAME_LIST="")
        result = subprocess.run(["bash", str(ROOT / "Scripts/ci_organize_outputs.sh")],
                                env=environment, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_artifact_only_build_does_not_repackage_or_leak_apks_into_firmware(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.organize(root, False)
            self.assertTrue((root / "upload/firmware.bin").is_file())
            self.assertEqual(list((root / "upload").rglob("*.apk")), [])
            self.assertFalse((root / "upload/test-build_Packages.zip").exists())

    def test_release_also_uses_platform_package_archives(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.organize(root, True)
            self.assertTrue((root / "upload/firmware.bin").is_file())
            self.assertEqual(list((root / "upload").rglob("*.apk")), [])
            self.assertEqual(list((root / "upload").rglob("*Packages*")), [])


if __name__ == "__main__":
    unittest.main()
