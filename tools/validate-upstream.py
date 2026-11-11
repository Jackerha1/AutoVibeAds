#!/usr/bin/env python3
"""Validate an upstream filter payload before it is re-signed and republished.

Subcommands:
  index <index.json>         Validate the upstream manifest. On success, print
                             the payload file names to download (rule lists
                             first, then the scriptlets file), one per line.
  files <dir> <index.json>   Validate the downloaded payload files in <dir>
                             against the same acceptance rules the app enforces
                             (file-name charset, size caps, JSON shapes).

Exit code 0 means valid; anything else prints "error: ..." to stderr and exits 1.
"""

import json
import os
import re
import sys

MAX_INDEX_BYTES = 64 * 1024
MAX_FILE_BYTES = 24 * 1024 * 1024
MAX_RULE_LISTS = 16
RULES_NAME = re.compile(r"^rules-[a-z0-9.-]{1,92}\.json$")
HOST_NAME = re.compile(r"^[a-z0-9.-]{1,253}$")


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def load_index(path: str) -> dict:
    if os.path.getsize(path) > MAX_INDEX_BYTES:
        die(f"manifest exceeds {MAX_INDEX_BYTES} bytes")
    try:
        with open(path, encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, ValueError) as exc:
        die(f"manifest unreadable: {exc}")
    if not isinstance(manifest, dict):
        die("manifest is not a JSON object")

    rules = manifest.get("rules")
    if not isinstance(rules, list) or not rules:
        die("manifest has no rule list array")
    if len(rules) > MAX_RULE_LISTS:
        die(f"manifest lists {len(rules)} rule files; the app accepts at most {MAX_RULE_LISTS}")
    for name in rules:
        if not isinstance(name, str) or ".." in name or not RULES_NAME.match(name):
            die(f"unsafe rule file name: {name!r}")
    if len(set(rules)) != len(rules):
        die("duplicate rule file names in manifest")

    if manifest.get("scriptlets") != "scriptlets.json":
        die(f"unexpected scriptlets file name: {manifest.get('scriptlets')!r}")

    built = manifest.get("built")
    if not isinstance(built, int) or built <= 0:
        die(f"manifest 'built' is not a positive integer: {built!r}")

    return manifest


def validate_files(directory: str, manifest: dict) -> None:
    for name in manifest["rules"]:
        path = os.path.join(directory, name)
        if not os.path.isfile(path):
            die(f"missing downloaded file: {name}")
        if os.path.getsize(path) > MAX_FILE_BYTES:
            die(f"{name} exceeds {MAX_FILE_BYTES} bytes")
        try:
            with open(path, encoding="utf-8") as handle:
                rules = json.load(handle)
        except (OSError, ValueError) as exc:
            die(f"{name} unreadable: {exc}")
        if not isinstance(rules, list) or not rules:
            die(f"{name} is not a non-empty JSON array")
        for position, rule in enumerate(rules):
            if (
                not isinstance(rule, dict)
                or not isinstance(rule.get("trigger"), dict)
                or not isinstance(rule.get("action"), dict)
            ):
                die(f"{name}[{position}] is not a content-blocker rule")

    path = os.path.join(directory, "scriptlets.json")
    if not os.path.isfile(path):
        die("missing downloaded file: scriptlets.json")
    if os.path.getsize(path) > MAX_FILE_BYTES:
        die(f"scriptlets.json exceeds {MAX_FILE_BYTES} bytes")
    try:
        with open(path, encoding="utf-8") as handle:
            scriptlets = json.load(handle)
    except (OSError, ValueError) as exc:
        die(f"scriptlets.json unreadable: {exc}")
    if not isinstance(scriptlets, dict) or not scriptlets:
        die("scriptlets.json is not a non-empty JSON object")
    for host, script in scriptlets.items():
        if not HOST_NAME.match(host):
            die(f"scriptlets.json has an invalid host key: {host!r}")
        if not isinstance(script, str) or not script:
            die(f"scriptlets.json[{host!r}] is not a non-empty string")


def main() -> None:
    if len(sys.argv) >= 3 and sys.argv[1] == "index":
        manifest = load_index(sys.argv[2])
        for name in manifest["rules"]:
            print(name)
        print("scriptlets.json")
    elif len(sys.argv) >= 4 and sys.argv[1] == "files":
        manifest = load_index(sys.argv[3])
        validate_files(sys.argv[2], manifest)
    else:
        die("usage: validate-upstream.py index <index.json> | files <dir> <index.json>")


if __name__ == "__main__":
    main()
