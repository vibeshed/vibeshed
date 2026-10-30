#!/usr/bin/env python3
"""Points the repo at a release: writes docs/latest.json (which the page reads) and the same
values into docs/index.html, so the download button is right even without JavaScript, then
updates the version in the cask template and project.yml.

  python3 scripts/update-latest.py VERSION SIZE_BYTES DATE URL SHA256

The release workflow runs it with the unversioned asset's URL,
https://github.com/vibeshed/vibeshed/releases/latest/download/Vibeshed.zip.
"""

import json
import re
import sys

INDEX = "docs/index.html"
OUT = "docs/latest.json"
CASK = "scripts/Casks/vibeshed.rb"
PROJECT = "project.yml"


def megabytes(size):
    return f"{size / 1_000_000:.1f} MB"


def substitute(path, replacements):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    for pattern, value in replacements:
        text, count = re.subn(pattern, rf"\g<1>{value}\g<2>", text, flags=re.MULTILINE)
        if count != 1:
            sys.exit(f"{path}: expected one match for {pattern}, found {count}")
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def main():
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    version, size, date, url, sha256 = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
    version = version.removeprefix("v")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        sys.exit(f"bad version or date: {version} {date}")
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        sys.exit(f"bad sha256: {sha256}")
    latest = {
        "version": version,
        "file": url.rsplit("/", 1)[1],
        "url": url,
        "size": size,
        "date": date,
        "sha256": sha256,
    }
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(latest, f, indent=2)
        f.write("\n")

    with open(INDEX, encoding="utf-8") as f:
        html = f.read()
    values = {"version": version, "size": megabytes(size), "file": latest["file"]}
    for key, value in values.items():
        html = re.sub(rf'(data-latest="{key}"[^>]*>)[^<]*(<)', rf"\g<1>{value}\g<2>", html)
    html = re.sub(r'(<a\b[^>]*\bdata-download\b[^>]*\bhref=")[^"]*(")', rf"\g<1>{url}\g<2>", html)
    html = re.sub(r'("softwareVersion": ")[^"]*(")', rf"\g<1>{version}\g<2>", html)
    html = re.sub(r'("fileSize": ")[^"]*(")', rf"\g<1>{megabytes(size)}\g<2>", html)
    html = re.sub(r'("downloadUrl": ")[^"]*(")', rf"\g<1>{url}\g<2>", html)
    with open(INDEX, "w", encoding="utf-8") as f:
        f.write(html)

    substitute(CASK, [(r'^(  version ")[^"]*(")', version), (r'^(  sha256 ")[^"]*(")', sha256)])
    substitute(PROJECT, [(r'^(\s*MARKETING_VERSION: ")[^"]*(")', version)])
    print(f"{OUT}: {version}, {megabytes(size)}, {date}")


if __name__ == "__main__":
    main()
