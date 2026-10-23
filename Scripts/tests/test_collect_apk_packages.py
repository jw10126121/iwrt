"""验证模块包、内置依赖与虚拟依赖的收集边界。"""
import importlib.util
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

SPEC = importlib.util.spec_from_file_location(
    "collector", Path(__file__).resolve().parents[1] / "collect_apk_packages.py")
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)


class DependencyTest(unittest.TestCase):
    def test_module_closure_includes_builtin_transitive_and_virtual_dependencies(self):
        packages = [
            {"name": "plugin", "version": "1", "depends": ["libabi>=2", "!conflict"]},
            {"name": "libabi2", "version": "2", "tags": ["openwrt:abiversion=2"],
             "provides": ["libabi=2"], "depends": [{"name": "so:libc.so", "version": "1"}]},
            {"name": "libc", "version": "1", "provides": [{"name": "so:libc.so", "version": "1"}]},
            {"name": "builtin", "version": "1"},
            {"name": "kmod-extra", "version": "1", "depends": ["kernel=6.6-abi"]},
        ]
        selected = collector.dependency_closure(packages, {"plugin"}, lambda a, b: "=" if a == b else ">")
        self.assertEqual(selected, {0, 1, 2, 4})

    def test_missing_dependency_fails_instead_of_publishing_broken_feed(self):
        with self.assertRaisesRegex(ValueError, "依赖.*missing"):
            collector.dependency_closure(
                [{"name": "plugin", "version": "1", "depends": ["missing"]}], {"plugin"}, None)

    def test_wrong_provider_version_is_not_accepted(self):
        with self.assertRaisesRegex(ValueError, "依赖"):
            collector.dependency_closure([
                {"name": "plugin", "version": "1", "depends": ["lib>=3"]},
                {"name": "lib", "version": "2"},
            ], {"plugin"}, lambda a, b: "<")

    def test_abi_suffix_can_match_config_module_name(self):
        self.assertEqual(collector.dependency_closure([
            {"name": "libdemo2026", "version": "1", "tags": ["openwrt:abiversion=2026"]},
        ], {"libdemo"}, None), {0})
