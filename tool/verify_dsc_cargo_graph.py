"""Reject incompatible PDF Craft dependency resolution before Rust compilation."""
import json
import sys

REVISION = "0a6e42b80bfd586aee6ee1144aa98cf1ea37a844"
FAMILY = {"krilla", "hayro", "hayro-interpret", "hayro-syntax",
          "hayro-jbig2", "hayro-cmap", "hayro-postscript", "linesweeper"}


def verify(metadata):
    packages = metadata["packages"]
    # Cargo metadata includes unused/platform-dependent packages as well.
    # Do not permit any registry copy of a patched parser family.
    selected = [p for p in packages if p["name"] in FAMILY]
    if not any(p["name"] == "hayro-syntax" for p in selected):
        raise ValueError("Required hayro-syntax parser missing from Cargo graph")
    for p in selected:
        source = p.get("source") or ""
        if not (source.startswith("git+https://github.com/storytold/craft-libs?")
                and source.endswith("#" + REVISION)):
            raise ValueError(f"Incompatible parser dependency: {p['name']} {p['version']} {source}")
    return [(p["name"], p["version"]) for p in selected]


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as f:
        for name, version in verify(json.load(f)):
            print(f"Verified pinned parser: {name} {version} @ {REVISION[:8]}")
