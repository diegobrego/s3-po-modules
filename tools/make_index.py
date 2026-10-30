#!/usr/bin/env python3
"""Builds index.json, the catalog S3-PO reads, from the files in modules/.

Each module describes itself at the top of its .lua file (key, name, version, about,
api); this script copies that into the catalog and adds each file's size and SHA-256,
which S3-PO checks before it installs a download. GitHub Actions runs it on every push,
so the catalog is always in step with the modules.

    python3 tools/make_index.py           write index.json
    python3 tools/make_index.py --check   fail if index.json is out of date
"""
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULES = os.path.join(ROOT, "modules")
INDEX = os.path.join(ROOT, "index.json")


def field(source, name, number=False):
    """First `name = "..."` (or a number) in the module table."""
    if number:
        m = re.search(rf"^\s*{name}\s*=\s*(\d+)\s*,", source, re.M)
        return int(m.group(1)) if m else None
    m = re.search(rf'^\s*{name}\s*=\s*"((?:[^"\\]|\\.)*)"\s*,', source, re.M)
    return m.group(1).replace('\\"', '"') if m else None


def build():
    modules, problems = [], []
    for file in sorted(os.listdir(MODULES)):
        if not file.endswith(".lua"):
            continue
        path = os.path.join(MODULES, file)
        data = open(path, "rb").read()
        source = data.decode("utf-8")
        key = field(source, "key")
        entry = {
            "key": key,
            "name": field(source, "name"),
            "version": field(source, "version"),
            "api": field(source, "api", number=True) or 1,
            "about": field(source, "about") or "",
            "file": "modules/" + file,
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        }
        if not key or not re.fullmatch(r"[a-z][a-z0-9]{0,11}", key):
            problems.append(f"{file}: key must be 1-12 lower-case letters and digits")
        elif file != key + ".lua":
            problems.append(f"{file}: the file must be named {key}.lua")
        for f in ("name", "version"):
            if not entry[f]:
                problems.append(f"{file}: `{f}` is missing")
        modules.append(entry)
    modules.sort(key=lambda m: (m["name"] or "").lower())
    catalog = {
        "catalog": "S3-PO modules",
        "about": "Modules for S3-PO, installed from its Modules page or with the command \"install <name>\".",
        "modules": modules,
    }
    return json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", problems


def main():
    text, problems = build()
    for p in problems:
        print("error:", p)
    if problems:
        sys.exit(1)
    if "--check" in sys.argv:
        current = open(INDEX, encoding="utf-8").read() if os.path.exists(INDEX) else ""
        if current != text:
            print("index.json is out of date: run python3 tools/make_index.py")
            sys.exit(1)
        print("index.json is up to date")
        return
    # A changed file needs a new version, or installed copies never hear about it.
    if os.path.exists(INDEX):
        old = {m["key"]: m for m in json.load(open(INDEX, encoding="utf-8")).get("modules", [])}
        for m in json.loads(text)["modules"]:
            o = old.get(m["key"])
            if o and o["version"] == m["version"] and o["sha256"] != m["sha256"]:
                print(f"::warning file=modules/{m['key']}.lua::{m['key']} changed but its version is still "
                      f"{m['version']}: raise the version so S3-PO offers the update")
    open(INDEX, "w", encoding="utf-8").write(text)
    print(f"index.json: {len(json.loads(text)['modules'])} modules")


if __name__ == "__main__":
    main()
