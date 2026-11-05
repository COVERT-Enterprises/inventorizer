#!/usr/bin/env python3
"""Release helper for COVERT tools, run by .github/workflows/release.yml.

  prepare   Checks the inputs, sets the script's $Brand Version if needed, and
            writes the release notes. Stops before anything is published if the
            version is malformed, already released, lower than the script's
            current version, or has no section in CHANGELOG.md.
  manifest  Writes version.json, the file the in-app updater reads, from
            CHANGELOG.md (newest first), the released script's sha256, and the
            download package's address and sha256.

The workflow passes its settings as environment variables: PRODUCT, SCRIPT,
VERSION, PLATFORM, TITLE, PRERELEASE and OFFER_UPDATE (plus ZIP, the built
package, for manifest), and GitHub's own GITHUB_REPOSITORY, GITHUB_OUTPUT,
GITHUB_STEP_SUMMARY and RUNNER_TEMP.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

CHANGELOG = Path("CHANGELOG.md")
MANIFEST = Path("version.json")
MANIFEST_NOTE = "Generated from CHANGELOG.md by the Release workflow. Edit CHANGELOG.md, not this file."

SEMVER = re.compile(r"\d+\.\d+\.\d+")
HEADING = re.compile(r"^##\s+v(\d+\.\d+\.\d+)\b(?:\s*[—–-]\s*(\S+))?")
SUBHEADING = re.compile(r"^###\s+(.+)")
BULLET = re.compile(r"^\s*[-*]\s+(.+)")
VERSION_LINE = re.compile(rb"^[ \t]*Version[ \t]*=[ \t]*'([^']*)'", re.M)
UPDATE_URL_LINE = re.compile(rb"^[ \t]*UpdateUrl[ \t]*=[ \t]*'([^']*)'", re.M)


def fail(message):
    print(f"::error::{message}")
    sys.exit(1)


def setting(name, default=""):
    return os.environ.get(name, default).strip()


def version_key(version):
    return tuple(int(part) for part in version.split("."))


def plain(text):
    """Strip Markdown emphasis, code and link syntax; the updater prints raw text."""
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    text = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"\1", text)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    return text.strip()


def changelog_sections():
    """Split CHANGELOG.md into one dict per '## vX.Y.Z' heading, keeping the raw body lines."""
    sections, current = [], None
    for line in CHANGELOG.read_text(encoding="utf-8").splitlines():
        heading = HEADING.match(line)
        if heading:
            current = {"version": heading.group(1), "date": heading.group(2) or "", "body": []}
            sections.append(current)
        elif current is not None:
            current["body"].append(line)
    return sections


def manifest_entry(section):
    entry = {"version": section["version"], "date": section["date"], "highlights": [], "notes": []}
    bucket = "notes"
    for line in section["body"]:
        sub = SUBHEADING.match(line)
        if sub:
            bucket = "highlights" if sub.group(1).lower().startswith("highlight") else "notes"
            continue
        bullet = BULLET.match(line)
        if bullet:
            entry[bucket].append(plain(bullet.group(1)))
        elif line.startswith((" ", "\t")) and line.strip() and entry[bucket]:
            entry[bucket][-1] += " " + plain(line)  # wrapped bullet
    return entry


def requested_version():
    version = setting("VERSION").lstrip("vV")
    if not SEMVER.fullmatch(version):
        fail(f"'{setting('VERSION')}' isn't a version number like 26.7.4.")
    return version


def script_version(source):
    match = VERSION_LINE.search(source)
    if not match:
        fail(f"Couldn't find the Version line in the $Brand block of {setting('SCRIPT')}.")
    return match


def prepare():
    product, script = setting("PRODUCT"), Path(setting("SCRIPT"))
    platform = setting("PLATFORM") or "Windows"
    prerelease = setting("PRERELEASE") == "true"
    version = requested_version()
    tag = f"v{version}"

    already = subprocess.run(["git", "ls-remote", "--exit-code", "--tags", "origin", f"refs/tags/{tag}"],
                             capture_output=True)
    if already.returncode == 0:
        fail(f"{tag} is already released. Run the workflow again with a new version number.")

    source = script.read_bytes()
    match = script_version(source)
    current = match.group(1).decode()
    if SEMVER.fullmatch(current) and version_key(version) < version_key(current):
        fail(f"{script} is already at version {current}. The new version has to be higher.")

    section = next((s for s in changelog_sections() if s["version"] == version), None)
    if section is None or not any(line.strip() for line in section["body"]):
        fail(f"CHANGELOG.md has no '## v{version}' section with notes. "
             "Add one describing this release, then run the workflow again.")

    bumped = current != version
    if bumped:
        script.write_bytes(source[:match.start(1)] + version.encode() + source[match.end(1):])
    notes = Path(setting("RUNNER_TEMP") or ".") / "notes.md"
    notes.write_text("\n".join(section["body"]).strip() + "\n", encoding="utf-8")

    title = setting("TITLE") or f"{product} v{version} ({platform})"
    package = f"{product}-v{version}-{platform}"
    update_url = UPDATE_URL_LINE.search(source)
    has_updater = bool(update_url and update_url.group(1).strip())
    offer = setting("OFFER_UPDATE") == "true" and not prerelease and has_updater
    if offer:
        why = ""
    elif not has_updater:
        why = " (this tool has no updater yet)"
    elif prerelease:
        why = " (pre-releases never are)"
    else:
        why = " (switched off for this run)"

    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as out:
        for key, value in {"version": version, "tag": tag, "title": title, "package": package,
                           "bumped": str(bumped).lower(), "update_manifest": str(offer).lower()}.items():
            out.write(f"{key}={value}\n")

    summary = "\n".join([
        f"### {title}",
        "",
        f"- Version: {version}" + (f" (raised from {current})" if bumped else ""),
        f"- Platform: {platform}",
        f"- Pre-release: {'yes' if prerelease else 'no'}",
        f"- Offered through the in-app updater: {'yes' if offer else 'no' + why}",
        f"- Download: {package}.zip",
    ]) + "\n"
    print(summary)
    if setting("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as out:
            out.write(summary)


def manifest():
    script, version = Path(setting("SCRIPT")), requested_version()
    package = Path(setting("ZIP"))
    if not setting("ZIP") or not package.is_file():
        fail("The download package wasn't found, so the update manifest can't list it.")
    source = script.read_bytes()
    if script_version(source).group(1).decode() != version:
        fail(f"{script} isn't at version {version}, so its update manifest can't be built.")
    sections = [s for s in changelog_sections() if version_key(s["version"]) <= version_key(version)]
    sections.sort(key=lambda s: version_key(s["version"]), reverse=True)
    if not sections or sections[0]["version"] != version:
        fail(f"CHANGELOG.md has no '## v{version}' section.")
    repo = setting("GITHUB_REPOSITORY")
    data = {
        "_comment": MANIFEST_NOTE,
        "version": version,
        "scriptUrl": f"https://raw.githubusercontent.com/{repo}/v{version}/{script.name}",
        "sha256": hashlib.sha256(source).hexdigest().upper(),
        "packageUrl": f"https://github.com/{repo}/releases/download/v{version}/{package.name}",
        "packageSha256": hashlib.sha256(package.read_bytes()).hexdigest().upper(),
        "changelog": [manifest_entry(s) for s in sections],
    }
    MANIFEST.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(f"version.json: v{version}, {len(sections)} changelog entries, sha256 {data['sha256'][:16]}...")


if __name__ == "__main__":
    commands = {"prepare": prepare, "manifest": manifest}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        fail("usage: release.py prepare|manifest")
    commands[sys.argv[1]]()
