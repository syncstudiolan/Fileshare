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
import subprocess
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


# Central pipeline: a SINGLE public release contains all selected packages.
# Until every build and every asset is verified, only a draft can exist.
RELEASE_FILES = {
    "android": ("file-share-android-signed-release-apk", "FileShare-Android-ARM64-Release.apk",
                "Production signed Android ARM64 APK; approve OS installation."),
    "windows": ("file-share-windows-installer", "FileShare-Windows-Setup.exe",
                "Windows x64 Setup installer; approve UAC."),
    "ios": ("file-share-ios-unsigned-ipa", "FileShare-iOS-UNSIGNED.ipa",
            "Unsigned iOS IPA; sign externally with compatible original identity before installation."),
    "macos": ("FileShare-macOS-AppleSilicon-DMG", "FileShare-macOS-AppleSilicon.dmg",
              "Apple Silicon DMG; replace the app in Applications using Finder."),
}


def _merge_release_set(manifest: dict, entries: dict) -> dict:
    """Validate every channel before changing ANY channel."""
    updated = dict(manifest)
    updated["schema"] = 1
    for platform, entry in entries.items():
        previous = manifest.get(platform)
        if isinstance(previous, dict):
            previous_build = int(previous.get("build", 0))
            if previous_build > entry["build"]:
                raise ValueError(f"refusing release downgrade for {platform}")
            if previous_build == entry["build"] and (
                    previous.get("sha256") != entry["sha256"] or
                    previous.get("url") != entry["url"]):
                raise ValueError(f"refusing to replace existing {platform} build")
        updated[platform] = entry
    return updated


def _read_manifest():
    existing = request("GET")
    return json.loads(base64.b64decode(existing["content"])), existing["sha"]


def _verify_release_set(release: dict, entries: dict, tag: str,
                        source: str, *, draft: bool) -> None:
    if (release.get("tag_name") != tag or
            release.get("target_commitish") != source or
            release.get("draft") is not draft):
        raise ValueError("release tag, source or draft state mismatch")
    assets = release.get("assets", [])
    if len(assets) != len(entries):
        raise ValueError("release asset set incomplete or unexpected")
    by_name = {asset["name"]: asset for asset in assets}
    for platform, entry in entries.items():
        filename = RELEASE_FILES[platform][1]
        remote = by_name.get(filename)
        if not remote or remote.get("state") != "uploaded" or (
                remote.get("size") != entry["size"] or
                remote.get("digest") != "sha256:" + entry["sha256"]):
            raise ValueError(f"{platform}: GitHub asset size/SHA-256 mismatch")
        actual_url = remote.get("browser_download_url", "")
        # GitHub draft releases use a temporary untagged-<id> URL until
        # published (observed in Build 624). Verify the real digest and
        # size in both phases, but allow only the trusted temporary URL
        # for this exact filename in this repository while still draft.
        temporary_url = re.fullmatch(
            rf"https://github\.com/{re.escape(REPO)}/releases/download/"
            rf"untagged-[A-Za-z0-9]+/{re.escape(filename)}",
            actual_url if isinstance(actual_url, str) else "",
        )
        if actual_url != entry["url"] and not (draft and temporary_url):
            raise ValueError(f"{platform}: GitHub asset download URL mismatch")


def publish_set(version: str, build: int, root: Path, selected: list[str]) -> None:
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version) or build < 1:
        raise ValueError("invalid version or build")
    if not selected or len(set(selected)) != len(selected) or any(
            platform not in RELEASE_FILES for platform in selected):
        raise ValueError("invalid selected platform set")
    source = os.environ.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ValueError("missing exact source commit")
    tag = f"fileshare-v{version}-build-{build}"
    release_api = f"https://api.github.com/repos/{REPO}/releases"
    entries, files = {}, []
    for platform in selected:
        directory, filename, notes = RELEASE_FILES[platform]
        artifact = root / directory / filename
        if not artifact.is_file() or artifact.stat().st_size < 1024:
            raise ValueError(f"{platform}: verified build artifact missing")
        with artifact.open("rb") as handle:
            digest = hashlib.file_digest(handle, "sha256").hexdigest()
        files.append(str(artifact))
        entries[platform] = {
            "version": version, "build": build, "size": artifact.stat().st_size,
            "sha256": digest,
            "url": f"https://github.com/{REPO}/releases/download/{tag}/{filename}",
            "notes": notes,
        }
    current, _ = _read_manifest()
    _merge_release_set(current, entries)  # no downgrade before release creation

    # gh uploads all assets to a draft, which is invisible to update clients.
    # No independent platform publish jobs can expose partial results.
    subprocess.run(["gh", "release", "create", tag, *files,
                    "--repo", REPO, "--target", source, "--draft",
                    "--title", f"File Share {version} (Build {build})",
                    "--notes", ("Verified release packages from source " + source +
                                ". " + " ".join(entries[p]["notes"] for p in selected))],
                   check=True)
    release = None
    for attempt in range(6):
        releases = request("GET", url=release_api + "?per_page=100")
        release = next((r for r in releases if r.get("tag_name") == tag), None)
        if release and release.get("id"):
            try:
                _verify_release_set(release, entries, tag, source, draft=True)
                break
            except ValueError:
                if attempt == 5:
                    raise
        time.sleep(min(2 ** attempt, 15))
    if not release:
        raise RuntimeError("draft release was not found")
    _verify_release_set(release, entries, tag, source, draft=True)
    release_url = release_api + "/" + str(release["id"])
    # Recheck monotonicity immediately before the single publication action.
    current, _ = _read_manifest()
    _merge_release_set(current, entries)
    request("PATCH", {"draft": False}, url=release_url)
    # The public tag URL may take a moment to replace the draft URL.
    # Do not write the manifest until the final URL, digest, size and
    # complete asset set have all been confirmed in the published release.
    for attempt in range(8):
        published = request("GET", url=release_url)
        try:
            _verify_release_set(published, entries, tag, source, draft=False)
            break
        except ValueError:
            if attempt == 7:
                raise
            time.sleep(min(2 ** attempt, 15))

    # One optimistic-lock commit updates all selected platforms together.
    # If publication or verification fails, none of the update entries change.
    for attempt in range(8):
        current, sha = _read_manifest()
        manifest = _merge_release_set(current, entries)
        change = {
            "message": f"[skip ci] Publish File Share release set build {build}",
            "branch": "main", "sha": sha,
            "content": base64.b64encode(
                (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
            ).decode(),
        }
        try:
            request("PUT", change)
            for platform, entry in entries.items():
                print(f"Published {platform} build {build}, {entry['size']} bytes, "
                      f"SHA-256 {entry['sha256']}: {entry['url']}")
            return
        except urllib.error.HTTPError as exc:
            if exc.code not in (409, 422) or attempt == 7:
                raise
            time.sleep(min(2 ** attempt, 15))
    raise RuntimeError("failed to commit complete update manifest")


if __name__ == "__main__":
    if not REPO or not TOKEN:
        raise SystemExit("GITHUB_REPOSITORY / GH_TOKEN not configured")
    if len(sys.argv) == 6 and sys.argv[1] == "--set":
        publish_set(sys.argv[2], int(sys.argv[3]), Path(sys.argv[4]),
                    sys.argv[5].split(","))
    elif len(sys.argv) == 7:
        publish(sys.argv[1], sys.argv[2], int(sys.argv[3]),
                sys.argv[4], Path(sys.argv[5]), sys.argv[6])
    else:
        raise SystemExit(
            "usage: publish_update_manifest.py --set VERSION BUILD DIRECTORY PLATFORMS "
            "or PLATFORM VERSION BUILD TAG FILE NOTES")
