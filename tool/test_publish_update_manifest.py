"""Offline release transaction tests; no credentials or network needed."""
import base64
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import publish_update_manifest as publisher


class ReleaseSetTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = "example/fileshare"
        self.source = "a" * 40
        self.tag = "fileshare-v0.1.0-build-623"
        self.platforms = list(publisher.RELEASE_FILES)
        self.entries = {}
        self.assets = []
        for platform, (directory, filename, notes) in publisher.RELEASE_FILES.items():
            path = self.root / directory / filename
            path.parent.mkdir()
            content = (platform.encode() * 2048)
            path.write_bytes(content)
            digest = hashlib.sha256(content).hexdigest()
            url = f"https://github.com/{self.repo}/releases/download/{self.tag}/{filename}"
            self.entries[platform] = dict(build=623, version="0.1.0", sha256=digest,
                                          size=len(content), url=url, notes=notes)
            self.assets.append(dict(name=filename, state="uploaded",
                                    size=len(content), digest="sha256:"+digest,
                                    browser_download_url=url.replace(self.tag, "untagged-5f11d1ab6b626820d19d")))
        self.previous = {"schema": 1, **{
            platform: dict(build=622, url="old", sha256="old")
            for platform in self.platforms
        }}
        self.remote = dict(id=17, tag_name=self.tag, target_commitish=self.source,
                           draft=True, assets=self.assets)
        self.keep_temporary_url = False
        self.calls = []
        self.payloads = []

    def fake_request(self, method, payload=None, url=publisher.URL):
        self.calls.append((method, url))
        if url == publisher.URL:
            if method == "GET":
                return {"sha": "old-sha", "content": base64.b64encode(
                    json.dumps(self.previous).encode()).decode()}
            if method == "PUT":
                self.payloads.append(json.loads(base64.b64decode(payload["content"])))
                return {}
        if method == "GET" and url.endswith("?per_page=100"):
            return [self.remote]
        if url.endswith("/17"):
            if method == "PATCH":
                self.remote["draft"] = payload["draft"]
                if not self.keep_temporary_url:
                    for asset in self.remote["assets"]:
                        asset["browser_download_url"] = asset["browser_download_url"].replace(
                            "untagged-5f11d1ab6b626820d19d", self.tag)
            return self.remote
        raise AssertionError((method, url))

    def execute(self, selected=None):
        with patch.object(publisher, "REPO", self.repo), \
             patch.dict(publisher.os.environ, {"GITHUB_SHA": self.source}), \
             patch.object(publisher, "request", side_effect=self.fake_request), \
             patch.object(publisher.subprocess, "run") as gh, \
             patch.object(publisher.time, "sleep"):
            publisher.publish_set("0.1.0", 623, self.root, selected or self.platforms)
            self.assertIn("--draft", gh.call_args.args[0])
            self.assertEqual(gh.call_count, 1)

    def test_all_four_channels_committed_together_after_release_verification(self):
        self.execute()
        self.assertEqual(self.payloads, [{"schema": 1, **self.entries}])
        writes = [method for method, _ in self.calls if method in ("PATCH", "PUT")]
        self.assertEqual(writes, ["PATCH", "PUT"])

    def test_missing_artifact_does_not_publish_or_modify_manifest(self):
        directory, filename, _ = publisher.RELEASE_FILES["ios"]
        (self.root / directory / filename).unlink()
        with self.assertRaisesRegex(ValueError, "artifact missing"):
            self.execute()
        self.assertEqual(self.calls, [])
        self.assertEqual(self.payloads, [])

    def test_wrong_remote_digest_keeps_release_draft_and_manifest_unchanged(self):
        self.assets[0]["digest"] = "sha256:" + "0" * 64
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            self.execute()
        self.assertTrue(self.remote["draft"])
        self.assertFalse(any(method in ("PATCH", "PUT") for method, _ in self.calls))

    def test_untrusted_draft_url_prevents_publication(self):
        self.assets[0]["browser_download_url"] = "https://example.org/other.apk"
        with self.assertRaisesRegex(ValueError, "download URL mismatch"):
            self.execute()
        self.assertTrue(self.remote["draft"])
        self.assertEqual(self.payloads, [])

    def test_published_temporary_url_prevents_manifest_update(self):
        self.keep_temporary_url = True
        with self.assertRaisesRegex(ValueError, "download URL mismatch"):
            self.execute()
        self.assertEqual(self.payloads, [])
        self.assertFalse(any(method == "PUT" for method, _ in self.calls))

    def test_previous_newer_platform_blocks_entire_release(self):
        self.previous["ios"]["build"] = 624
        with self.assertRaisesRegex(ValueError, "downgrade for ios"):
            self.execute()
        self.assertFalse(any(method in ("PATCH", "PUT") for method, _ in self.calls))

    def test_partial_manual_selection_preserves_other_channels(self):
        self.remote["assets"] = [a for a in self.assets if a["name"].endswith(".exe")]
        self.execute(["windows"])
        expected = dict(self.previous)
        expected["windows"] = self.entries["windows"]
        self.assertEqual(self.payloads, [expected])


if __name__ == "__main__":
    unittest.main()
