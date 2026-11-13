#!/usr/bin/env python3
"""Package the Lightroom plug-in as dist/LRRemotePreviews-<version>.zip.

Run from anywhere (usually the repository root):

    python tools/package_plugin.py

The version comes from VERSION in plugin/LRRemotePreviews.lrplugin/Info.lua. The zip holds the folder
LRRemotePreviews.lrplugin/ as its only top-level entry, so unzipping gives a folder that can be added in
Lightroom's File > Plug-in Manager. The output is deterministic: entries are sorted, timestamps and
permissions are fixed, and CRLF line endings in text files are stored as LF, so the same sources give the
same bytes on every platform. The project's LICENSE and the plug-in's third-party notices are added to the
folder inside the zip, because the zip is what users receive. Prints the path of the zip. Standard library only.
"""
from __future__ import annotations

import os
import re
import sys
import tempfile
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PLUGIN_NAME = "LRRemotePreviews.lrplugin"
PLUGIN_DIR = REPO_ROOT / "plugin" / PLUGIN_NAME
DIST_DIR = REPO_ROOT / "dist"

FIXED_DATE_TIME = (1980, 1, 1, 0, 0, 0)  # the earliest time a zip entry can carry
FILE_MODE = 0o100644
DIR_MODE = 0o040755
TEXT_SUFFIXES = {".lua", ".md", ".txt"}
SKIPPED_NAMES = {"Thumbs.db", "desktop.ini", "__pycache__"}
# Files from outside the plug-in folder that go into the zip: name inside the plug-in folder -> source.
EXTRA_FILES = {
    "LICENSE.txt": REPO_ROOT / "LICENSE",
    "THIRD-PARTY.md": REPO_ROOT / "plugin" / "THIRD-PARTY.md",
}


def read_version(info_lua: Path) -> str:
    """Returns 'major.minor.revision' from the VERSION table in Info.lua."""
    text = info_lua.read_text(encoding="utf-8")
    table = re.search(r"\bVERSION\s*=\s*\{([^}]*)\}", text)
    if not table:
        raise SystemExit(f"error: no VERSION table in {info_lua}")
    parts = []
    for key in ("major", "minor", "revision"):
        match = re.search(rf"\b{key}\s*=\s*(\d+)", table.group(1))
        if not match:
            raise SystemExit(f"error: VERSION in {info_lua} has no numeric '{key}'")
        parts.append(match.group(1))
    return ".".join(parts)


def is_skipped(path: Path) -> bool:
    name = path.name
    return name.startswith(".") or name in SKIPPED_NAMES or name.endswith("~")


def collect(plugin_dir: Path) -> tuple[list[str], list[str]]:
    """Returns sorted sub-folder and file paths relative to plugin_dir, with forward slashes."""
    folders, files = [], []
    for current, dir_names, file_names in os.walk(plugin_dir):
        current_path = Path(current)
        dir_names[:] = [d for d in dir_names if not is_skipped(current_path / d)]
        for name in dir_names:
            folders.append((current_path / name).relative_to(plugin_dir).as_posix())
        for name in file_names:
            path = current_path / name
            if not is_skipped(path):
                files.append(path.relative_to(plugin_dir).as_posix())
    return sorted(folders), sorted(files)


def zip_entry(name: str, mode: int, is_dir: bool = False) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, date_time=FIXED_DATE_TIME)
    info.create_system = 3  # Unix, so the permission bits below mean the same on every platform
    info.external_attr = (mode << 16) | (0x10 if is_dir else 0)
    info.compress_type = zipfile.ZIP_STORED if is_dir else zipfile.ZIP_DEFLATED
    return info


def build(plugin_dir: Path, out_path: Path) -> None:
    folders, files = collect(plugin_dir)
    if "Info.lua" not in files:
        raise SystemExit(f"error: {plugin_dir} has no Info.lua")
    sources = {relative: plugin_dir / relative for relative in files}
    for name, source in EXTRA_FILES.items():
        if name in sources:
            raise SystemExit(f"error: {name} exists in {plugin_dir} and would be replaced by {source}")
        if not source.is_file():
            raise SystemExit(f"error: {source} is missing")
        sources[name] = source
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=out_path.name + ".", suffix=".tmp", dir=out_path.parent)
    os.close(fd)
    try:
        with zipfile.ZipFile(tmp_name, "w") as archive:
            archive.writestr(zip_entry(PLUGIN_NAME + "/", DIR_MODE, is_dir=True), b"")
            entries = [(f, True) for f in folders] + [(f, False) for f in sources]
            for relative, is_dir in sorted(entries):
                name = f"{PLUGIN_NAME}/{relative}"
                if is_dir:
                    archive.writestr(zip_entry(name + "/", DIR_MODE, is_dir=True), b"")
                    continue
                data = sources[relative].read_bytes()
                if Path(relative).suffix.lower() in TEXT_SUFFIXES:
                    data = data.replace(b"\r\n", b"\n")
                archive.writestr(zip_entry(name, FILE_MODE), data, compresslevel=9)
        os.replace(tmp_name, out_path)
    except BaseException:
        if os.path.exists(tmp_name):
            os.remove(tmp_name)
        raise


def main() -> int:
    if not PLUGIN_DIR.is_dir():
        print(f"error: plug-in folder not found: {PLUGIN_DIR}", file=sys.stderr)
        return 1
    version = read_version(PLUGIN_DIR / "Info.lua")
    out_path = DIST_DIR / f"LRRemotePreviews-{version}.zip"
    build(PLUGIN_DIR, out_path)
    print(out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
