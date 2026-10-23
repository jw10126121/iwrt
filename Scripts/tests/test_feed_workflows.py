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
        for name in ("CUSTOM-iwrt-all.yml", "CUSTOM-iwrt.yml", "CUSTOM-LWRT.yml", "DEFAULT.yml"):
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
                for name in builds:
                    self.assertEqual(jobs[name]["with"]["WRT_FEED_HOST"],
                                     publisher["with"]["WRT_FEED_HOST"])
                    self.assertNotIn("WRT_RELEASE_FIRMWARE", jobs[name]["with"])

    def test_core_only_delivers_one_raw_build_artifact(self):
        steps = workflow("CORE-ALL.yml")["jobs"]["build"]["steps"]
        commands = "\n".join(step.get("run", "") for step in steps)
        self.assertNotIn("ci_organize_outputs.sh", commands)
        self.assertNotIn("ci_supplement_versions_from_manifest.sh", commands)
        self.assertNotIn("gh release", commands)
        self.assertIn("ci_build_outputs.py\" export", commands)
        self.assertFalse(any("cloudflare/" in step.get("uses", "") for step in steps))
        uploads = [step for step in steps if "actions/upload-artifact@" in step.get("uses", "")]
        self.assertEqual(len(uploads), 1)
        self.assertTrue(uploads[0]["with"]["name"].endswith("-build-output"))
        self.assertEqual(uploads[0]["with"]["if-no-files-found"], "error")
        self.assertNotIn("continue-on-error", uploads[0])
        self.assertEqual(uploads[0]["with"]["retention-days"], 1)

    def test_publisher_organizes_firmware_and_deploys_one_complete_feed(self):
        publisher = workflow("PUBLISH-OUTPUTS.yml")["jobs"]["publish"]
        self.assertNotIn("if", publisher)
        steps = publisher["steps"]
        downloads = [step for step in steps if "actions/download-artifact@" in step.get("uses", "")]
        self.assertEqual(len(downloads), 1)
        self.assertEqual(downloads[0]["with"]["pattern"], "*-build-output")
        self.assertFalse(downloads[0]["with"]["merge-multiple"])
        deploys = [step for step in steps if "cloudflare/" in step.get("uses", "")]
        self.assertEqual(len(deploys), 1)
        self.assertIn("pages deploy public", deploys[0]["with"]["command"])
        uploads = [step for step in steps if "actions/upload-artifact@" in step.get("uses", "")]
        self.assertEqual({step["with"]["name"] for step in uploads}, {"firmware", "apk-packages"})
        self.assertTrue(all(step["with"]["if-no-files-found"] == "error" for step in uploads))
        commands = "\n".join(step.get("run", "") for step in steps)
        self.assertIn("ci_build_outputs.py organize", commands)
        self.assertIn("merge_apk_feeds.py", commands)
        releases = [step for step in steps if "ci_build_outputs.py release" in step.get("run", "")]
        self.assertEqual(len(releases), 1)
        self.assertEqual(releases[0]["if"], "inputs.WRT_RELEASE_FIRMWARE")


if __name__ == "__main__":
    unittest.main()
