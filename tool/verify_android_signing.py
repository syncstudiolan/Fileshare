#!/usr/bin/env python3
"""Compare verified APK signing certificate fingerprints, not SDK log labels."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

# Older apksigner emits "Signer #1"; newer releases emit "V2 Signer"
# (or V3/V3.1). Never match public-key or SHA-1/MD5 digests.
CERT_LINE = re.compile(
    r"^\s*(?:V\d+(?:\.\d+)?\s+)?Signer(?:\s+#\d+)?\s*"
    r"certificate SHA-256 digest:\s*([0-9a-f]{64})\s*$",
    re.IGNORECASE | re.MULTILINE,
)


def fingerprints(output: str) -> frozenset[str]:
    certs = frozenset(match.lower() for match in CERT_LINE.findall(output))
    if not certs:
        raise ValueError("apksigner produced no recognized SHA-256 certificate digest")
    return certs


def compare_outputs(old: str, new: str) -> frozenset[str]:
    previous, candidate = fingerprints(old), fingerprints(new)
    # File Share's published production APK uses exactly one signer.
    # Multiple signing schemes may repeat the same certificate.
    if len(previous) != 1 or len(candidate) != 1 or previous != candidate:
        raise ValueError("Android signing identity differs; restore the original production keystore")
    return previous


def verify_apk(signer: Path, apk: Path) -> str:
    result = subprocess.run(
        [str(signer), "verify", "--verbose", "--print-certs", str(apk)],
        capture_output=True, text=True, check=False,
    )
    if result.returncode:
        raise ValueError(f"APK signature verification failed for {apk.name}: "
                         f"{result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("apksigner", type=Path)
    parser.add_argument("previous_apk", type=Path)
    parser.add_argument("candidate_apk", type=Path)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    # Authenticate the previous artifact against the already published
    # update manifest before using it as the signing identity baseline.
    previous = json.loads(args.manifest.read_text())["android"]
    with args.previous_apk.open("rb") as handle:
        digest = hashlib.file_digest(handle, "sha256").hexdigest()
    if (args.previous_apk.stat().st_size != previous["size"] or
            digest != previous["sha256"].lower()):
        raise SystemExit("Previous APK size/SHA-256 does not match update manifest")
    try:
        certs = compare_outputs(verify_apk(args.apksigner, args.previous_apk),
                                verify_apk(args.apksigner, args.candidate_apk))
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc
    print("Android signing identity matches previous production APK: " + next(iter(certs)))


if __name__ == "__main__":
    main()
