#!/usr/bin/env python3
"""Write a verified release to main/update_manifest.json after gh release create.

Only the GitHub release workflow calls this. The manifest uses a single
platform entry per signed APK, Windows installer, or unsigned iOS IPA or macOS DMG;
SHA-256 is computed on
the exact published artifact. Never store GitHub tokens inside the repo.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import quote

REPO = os.environ.get("GITHUB_REPOSITORY", "")
TOKEN = os.environ.get("GH_TOKEN", "")
URL = f"https://api.github.com/repos/{REPO}/contents/update_manifest.json"


def request(method: str, payload: dict | None = None, url: str = URL):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        url, method=method, data=data,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


def publish(platform: str, version: str, build: int,
            tag: str, artifact: Path, notes: str) -> None:
    if platform not in {"android", "windows", "ios", "macos"}:
        raise ValueError("unsupported platform")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version):
        raise ValueError("invalid app version")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", tag):
        raise ValueError("invalid release tag")
    if not artifact.is_file() or artifact.stat().st_size < 1024:
        raise ValueError("release artifact missing or too small")
    expected = {"android": "apk", "windows": "exe", "ios": "ipa", "macos": "dmg"}[platform]
    if artifact.suffix.lower() != f".{expected}":
        raise ValueError("wrong release extension")
    sha = hashlib.file_digest(artifact.open("rb"), "sha256").hexdigest()
    asset_url = (f"https://github.com/{REPO}/releases/download/"
                 f"{tag}/{artifact.name}")
    # Verify the remote asset, not just the local artifact. GitHub's
    # release digest is computed from the uploaded bytes.
    release_url = f"https://api.github.com/repos/{REPO}/releases/tags/{quote(tag, safe='')}"
    remote = None
    for attempt in range(5):
        release = request("GET", url=release_url)
        remote = next((a for a in release.get("assets", [])
                       if a.get("name") == artifact.name and a.get("state") == "uploaded"), None)
        if remote and remote.get("digest"):
            break
        time.sleep(2 ** attempt)
    if not remote or remote.get("size") != artifact.stat().st_size or (
            remote.get("digest") != f"sha256:{sha}") or (
            remote.get("browser_download_url") != asset_url):
        raise ValueError("GitHub release asset SHA-256/size/URL verification failed; manifest unchanged")
    if release.get("draft"):
        raise ValueError("refusing to publish draft release metadata")
    source_sha = os.environ.get("GITHUB_SHA", "")
    if source_sha and release.get("target_commitish") != source_sha:
        raise ValueError("release does not reference the selected source commit")
    print(f"Verified uploaded asset: {asset_url} ({remote['size']} bytes, {sha})")
    for attempt in range(8):
        try:
            existing = request("GET")
            content = base64.b64decode(existing["content"])
            manifest = json.loads(content)
            document_sha = existing["sha"]
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
            manifest = {"schema": 1}
            document_sha = None
        manifest["schema"] = 1
        previous = manifest.get(platform)
        if isinstance(previous, dict):
            previous_build = int(previous.get("build", 0))
            if previous_build > build:
                raise ValueError("refusing release downgrade")
            if previous_build == build and (
                    previous.get("sha256") != sha or previous.get("url") != asset_url):
                raise ValueError("refusing to replace an existing build with different bytes")
        manifest[platform] = {
            "version": version,
            "build": build,
            "url": asset_url,
            "sha256": sha,
            "size": artifact.stat().st_size,
            "notes": notes[:500],
        }
        body = base64.b64encode(
            (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
        ).decode()
        change = {
            "message": "[skip ci] Update File Share " + platform +
                       " release manifest to build " + str(build),
            "branch": "main",
            "content": body,
        }
        if document_sha is not None:
            change["sha"] = document_sha
        try:
            request("PUT", change)
            print(f"Published {platform} build {build}, SHA-256 {sha}")
            return
        except urllib.error.HTTPError as exc:
            if exc.code not in (409, 422) or attempt == 7:
                raise
            time.sleep(min(2 ** attempt, 15))
    raise RuntimeError("failed to update release manifest")


if __name__ == "__main__":
    if len(sys.argv) != 7:
        raise SystemExit(
            "usage: publish_update_manifest.py PLATFORM VERSION BUILD TAG FILE NOTES")
    if not REPO or not TOKEN:
        raise SystemExit("GITHUB_REPOSITORY / GH_TOKEN not configured")
    publish(sys.argv[1], sys.argv[2], int(sys.argv[3]),
            sys.argv[4], Path(sys.argv[5]), sys.argv[6])
