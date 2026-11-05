#!/usr/bin/env python3
"""Build version.json, the manifest Inventorizer's built-in updater reads.

The Release workflow runs this from the repository root:

    python3 .github/scripts/build_version_json.py <version> <owner/repo>

CHANGELOG.md is the single source of truth: every "## vX.Y.Z" section up to the
version being released becomes a changelog entry, newest first. The run fails
before anything is published if Inventorizer.ps1's $Brand.Version doesn't match
the release, or if CHANGELOG.md has no section for it.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

SCRIPT = Path("Inventorizer.ps1")
CHANGELOG = Path("CHANGELOG.md")
MANIFEST = Path("version.json")

HEADING = re.compile(r"^##\s+v(\d+\.\d+\.\d+)\b(?:\s*[—–-]\s*(\S+))?")
SUBHEADING = re.compile(r"^###\s+(.+)")
BULLET = re.compile(r"^\s*[-*]\s+(.+)")


def fail(message):
    print(f"::error::{message}")
    sys.exit(1)


def version_key(version):
    return tuple(int(part) for part in version.split("."))


def plain(text):
    """Strip Markdown emphasis, code and link syntax; the updater prints raw text."""
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    text = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"\1", text)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    return text.strip()


def parse_changelog(text):
    entries, entry, section = [], None, "notes"
    for line in text.splitlines():
        heading = HEADING.match(line)
        if heading:
            entry = {"version": heading.group(1), "date": heading.group(2) or "",
                     "highlights": [], "notes": []}
            entries.append(entry)
            section = "notes"
            continue
        if entry is None:
            continue
        sub = SUBHEADING.match(line)
        if sub:
            section = "highlights" if sub.group(1).lower().startswith("highlight") else "notes"
            continue
        bullet = BULLET.match(line)
        if bullet:
            entry[section].append(plain(bullet.group(1)))
        elif line.startswith((" ", "\t")) and line.strip() and entry[section]:
            entry[section][-1] += " " + plain(line)  # wrapped bullet
    return entries


def main():
    if len(sys.argv) != 3:
        fail("usage: build_version_json.py <version> <owner/repo>")
    version, repo = sys.argv[1].strip().lstrip("vV"), sys.argv[2].strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        fail(f"'{sys.argv[1]}' isn't a version number like 26.7.3.")

    match = re.search(r"^\s*Version\s*=\s*'([^']*)'", SCRIPT.read_text(encoding="utf-8"), re.M)
    in_script = match.group(1) if match else "(not found)"
    if in_script != version:
        fail(f"Inventorizer.ps1 says Version = '{in_script}', but this release is {version}. "
             "Update the Version line in the $Brand block, then run the release again.")

    entries = [e for e in parse_changelog(CHANGELOG.read_text(encoding="utf-8"))
               if version_key(e["version"]) <= version_key(version)]
    entries.sort(key=lambda e: version_key(e["version"]), reverse=True)
    if not entries or entries[0]["version"] != version:
        fail(f"CHANGELOG.md has no '## v{version}' section. "
             "Add one with this release's highlights and notes, then run the release again.")

    manifest = {
        "_comment": "Generated from CHANGELOG.md by the Release workflow. Edit CHANGELOG.md, not this file.",
        "version": version,
        "scriptUrl": f"https://raw.githubusercontent.com/{repo}/v{version}/{SCRIPT.name}",
        "sha256": hashlib.sha256(SCRIPT.read_bytes()).hexdigest().upper(),
        "changelog": entries,
    }
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"version.json: v{version}, {len(entries)} changelog entries, sha256 {manifest['sha256'][:16]}...")


if __name__ == "__main__":
    main()
