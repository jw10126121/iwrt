#!/usr/bin/env python3
"""验证入口工作流拥有固件与软件源的整理、上传和发布职责。"""

import unittest
from pathlib import Path

import yaml

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github/workflows"


def workflow(name):
    return yaml.safe_load((WORKFLOWS / name).read_text())


class FeedWorkflowTest(unittest.TestCase):
    def test_every_entry_waits_for_all_builds_and_publishes_once(self):
        for name in ("CUSTOM-iwrt-all.yml", "DEFAULT.yml"):
            with self.subTest(workflow=name):
                jobs = workflow(name)["jobs"]
                builds = {name for name, job in jobs.items()
                          if job.get("uses", "").endswith("/CORE-ALL.yml")}
                publishers = [job for job in jobs.values()
                              if job.get("uses", "").endswith("/PUBLISH-OUTPUTS.yml")]
                self.assertEqual(len(publishers), 1)
                publisher = publishers[0]
                needs = publisher["needs"]
                self.assertEqual(set([needs] if isinstance(needs, str) else needs), builds)
                self.assertEqual(publisher["with"]["WRT_EXPECTED_BUILDS"], len(builds))
                self.assertNotIn("if", publisher)
                self.assertIn("WRT_RELEASE_FIRMWARE", publisher["with"])
                self.assertIn("WRT_RELEASE_PACKAGES", publisher["with"])
                for name in builds:
                    self.assertEqual(jobs[name]["with"]["WRT_FEED_HOST"],
                                     publisher["with"]["WRT_FEED_HOST"])
                    self.assertNotIn("WRT_RELEASE_FIRMWARE", jobs[name]["with"])

    def test_core_delivers_raw_and_immediately_usable_device_artifacts(self):
        steps = workflow("CORE-ALL.yml")["jobs"]["build"]["steps"]
        commands = "\n".join(step.get("run", "") for step in steps)
        self.assertIn("ci_build_outputs.py\" ready", commands)
        self.assertNotIn("gh release", commands)
        self.assertIn("ci_build_outputs.py\" export", commands)
        self.assertFalse(any("cloudflare/" in step.get("uses", "") for step in steps))
        uploads = [step for step in steps if "actions/upload-artifact@" in step.get("uses", "")]
        self.assertEqual(len(uploads), 2)
        names = [step["with"]["name"] for step in uploads]
        self.assertTrue(any(name.endswith("-feed") for name in names))
        self.assertTrue(any(name.endswith("-firmware") for name in names))
        self.assertFalse(any(name.endswith("-apk-packages") for name in names))
        self.assertTrue(all(step["with"]["if-no-files-found"] == "error" for step in uploads))
        self.assertTrue(all("continue-on-error" not in step for step in uploads))

    def test_publisher_organizes_firmware_and_deploys_feed_for_source_hashes(self):
        publisher = workflow("PUBLISH-OUTPUTS.yml")["jobs"]["publish"]
        self.assertNotIn("if", publisher)
        steps = publisher["steps"]
        downloads = [step for step in steps if "actions/download-artifact@" in step.get("uses", "")]
        self.assertEqual(len(downloads), 2)
        self.assertEqual({step["with"]["pattern"] for step in downloads},
                         {"*-feed", "*-firmware"})
        self.assertTrue(all(not step["with"]["merge-multiple"] for step in downloads))
        deploys = [step for step in steps if "wrangler@4 pages deploy public" in step.get("run", "")]
        self.assertEqual(len(deploys), 1)
        self.assertEqual(deploys[0]["env"]["SOURCE_TAGS"], "${{ steps.merge.outputs.source_tags }}")
        self.assertIn('for source_tag in "${source_tags[@]}"', deploys[0]["run"])
        uploads = [step for step in steps if "actions/upload-artifact@" in step.get("uses", "")]
        self.assertEqual({step["with"]["name"] for step in uploads}, {"apk-packages"})
        self.assertEqual(uploads[0]["with"]["path"], "package-artifacts/")
        self.assertTrue(all(step["with"]["if-no-files-found"] == "error" for step in uploads))
        self.assertTrue(all(step["if"] == "inputs.WRT_UPLOAD_PACKAGES_ARTIFACT" for step in uploads))
        commands = "\n".join(step.get("run", "") for step in steps)
        self.assertIn("ci_build_outputs.py organize", commands)
        self.assertIn("--firmware-input firmware-artifacts", commands)
        self.assertIn("merge_apk_feeds.py", commands)
        self.assertIn("ci_organize_apk_packages.py", commands)
        self.assertIn("--input merged-feed-packages/plugins --output plugin-archives", commands)
        self.assertIn("--artifact-output package-artifacts", commands)
        self.assertIn("--apk \"$APK_TOOL\"", commands)
        self.assertIn("--platform-firmware-output platform-firmware-archives", commands)
        releases = [step for step in steps if "ci_build_outputs.py release-platforms" in step.get("run", "")]
        self.assertEqual(len(releases), 1)
        self.assertEqual(releases[0]["if"], "inputs.WRT_RELEASE_FIRMWARE || inputs.WRT_RELEASE_PACKAGES")
        self.assertIn("--firmware-input platform-firmware-archives", releases[0]["run"])
        self.assertIn("--plugins-input plugin-archives", releases[0]["run"])


if __name__ == "__main__":
    unittest.main()
