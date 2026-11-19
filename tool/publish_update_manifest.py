#!/usr/bin/env python3
"""Write a verified release to main/update_manifest.json after gh release create.

Only the GitHub release workflow calls this. The manifest uses a single
platform entry per signed APK/Windows installer; SHA-256 is computed on
the exact published artifact. Never store GitHub tokens inside the repo.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = os.environ.get("GITHUB_REPOSITORY", "")
TOKEN = os.environ.get("GH_TOKEN", "")
URL = f"https://api.github.com/repos/{REPO}/contents/update_manifest.json"


def request(method: str, payload: dict | None = None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        URL, method=method, data=data,
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
    if platform not in {"android", "windows"}:
        raise ValueError("unsupported platform")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version):
        raise ValueError("invalid app version")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", tag):
        raise ValueError("invalid release tag")
    if not artifact.is_file() or artifact.stat().st_size < 1024:
        raise ValueError("release artifact missing or too small")
    expected = "apk" if platform == "android" else "exe"
    if artifact.suffix.lower() != f".{expected}":
        raise ValueError("wrong release extension")
    sha = hashlib.file_digest(artifact.open("rb"), "sha256").hexdigest()
    asset_url = (f"https://github.com/{REPO}/releases/download/"
                 f"{tag}/{artifact.name}")
    for attempt in range(3):
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
        if isinstance(previous, dict) and int(previous.get("build", 0)) > build:
            raise ValueError("refusing release downgrade")
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
            if exc.code not in (409, 422) or attempt == 2:
                raise
    raise RuntimeError("failed to update release manifest")


if __name__ == "__main__":
    if len(sys.argv) != 7:
        raise SystemExit(
            "usage: publish_update_manifest.py PLATFORM VERSION BUILD TAG FILE NOTES")
    if not REPO or not TOKEN:
        raise SystemExit("GITHUB_REPOSITORY / GH_TOKEN not configured")
    publish(sys.argv[1], sys.argv[2], int(sys.argv[3]),
            sys.argv[4], Path(sys.argv[5]), sys.argv[6])
