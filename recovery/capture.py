#!/usr/bin/env python3
"""Capture only explicitly selected text files, packages and mounted volumes."""
import argparse
import json
import os
from pathlib import Path
import subprocess
from config import profile, relative_path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--role", choices=("primary", "shadow", "peer"), required=True)
    parser.add_argument("--file", action="append", default=[], help="selected file relative to HOME")
    parser.add_argument("--mount", action="append", default=[], help="existing mountpoint to require on restore")
    parser.add_argument("--package", action="append", default=[], help="installed Debian package to version-pin")
    parser.add_argument("--chawan-revision")
    args = parser.parse_args()
    data = {"schema": 1, "role": args.role, "files": [], "mounts": [], "packages": [], "chawan_revision": args.chawan_revision}
    home = Path.home().resolve()
    for value in args.file:
        relative_path(value)
        source = home / value
        source.resolve(strict=True).relative_to(home)
        if source.is_symlink() or not source.is_file() or source.stat().st_size > 1024 * 1024:
            raise ValueError("selected file must be a regular text file under 1 MiB")
        data["files"].append({"path": value, "content": source.read_bytes().decode("utf-8")})
    for value in args.mount:
        uuid = subprocess.check_output(["findmnt", "--noheadings", "--output", "UUID", "--mountpoint", value], text=True).strip()
        data["mounts"].append({"path": value, "uuid": uuid})
    for value in args.package:
        if value.startswith("-"):
            raise ValueError("invalid package name")
        pin = subprocess.check_output(["dpkg-query", "--show", "--showformat=${Package}=${Version}", value], text=True).strip()
        data["packages"].append(pin)
    profile(data)
    content = json.dumps(data, indent=2)
    if len(content.encode()) > 1024 * 1024:
        raise ValueError("combined recovery profile exceeds 1 MiB")
    with os.fdopen(os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
        output.write(content + "\n")
    print("Selected configuration captured with mode 0600; publish it before discarding the old host.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError):
        raise SystemExit("Capture failed; no secret values were printed.") from None
