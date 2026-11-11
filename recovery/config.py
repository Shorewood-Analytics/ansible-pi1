#!/usr/bin/env python3
"""Bounded archive extraction and validation; never print secret values."""
import argparse
import json
import os
import pwd
from pathlib import Path, PurePosixPath
import re
import tarfile

MAX_BYTES = 16 * 1024 * 1024
SHA = re.compile(r"[0-9a-f]{40}")
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}")


def relative_path(value):
    if not isinstance(value, str) or not value or any(c in value for c in ("\x00", "{", "}")):
        raise ValueError("invalid relative file path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in (".", "..") for part in value.split("/")):
        raise ValueError("file paths must stay within the target home")
    if "//" in value or value.endswith("/"):
        raise ValueError("file path must be normalized")
    return value


def profile(data):
    required = {"schema", "role", "files", "mounts", "packages", "chawan_revision"}
    if not isinstance(data, dict) or set(data) != required or data["schema"] != 1:
        raise ValueError("profile requires exactly the documented schema-1 fields")
    if data["role"] not in ("primary", "shadow", "peer"):
        raise ValueError("invalid node role")
    if data["chawan_revision"] is not None and not SHA.fullmatch(data["chawan_revision"]):
        raise ValueError("Chawan requires a full published commit SHA or null")
    if not isinstance(data["packages"], list) or len(data["packages"]) > 100:
        raise ValueError("invalid package list")
    for package in data["packages"]:
        if not isinstance(package, str) or not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*(?::[a-z0-9]+)?=[A-Za-z0-9.+:~_-]+", package):
            raise ValueError("each package must use an explicit name=version pin")
    if not isinstance(data["files"], list) or len(data["files"]) > 500:
        raise ValueError("invalid managed file list")
    paths = set()
    for item in data["files"]:
        if not isinstance(item, dict) or set(item) != {"path", "content"}:
            raise ValueError("each file requires path and content")
        path = relative_path(item["path"])
        if path in paths or not isinstance(item["content"], str) or "\x00" in item["content"]:
            raise ValueError("duplicate path or non-text content")
        paths.add(path)
    for path in paths:
        if any(str(parent) in paths for parent in PurePosixPath(path).parents):
            raise ValueError("managed files cannot also be parent directories")
    if not isinstance(data["mounts"], list) or len(data["mounts"]) > 50:
        raise ValueError("invalid required mount list")
    mount_paths = set()
    for item in data["mounts"]:
        if not isinstance(item, dict) or set(item) != {"path", "uuid"}:
            raise ValueError("mounts require path and uuid")
        value = item["path"]
        if not isinstance(value, str) or not value.startswith("/") or ".." in value.split("/") or any(c in value for c in ("\x00", "{", "}")) or value in mount_paths:
            raise ValueError("invalid or duplicate mount path")
        if not isinstance(item["uuid"], str) or not re.fullmatch(r"[A-Za-z0-9-]+", item["uuid"]):
            raise ValueError("invalid filesystem UUID")
        mount_paths.add(value)
    return data


def manifest(data):
    if not isinstance(data, dict) or set(data) != {"schema", "tooling_revision", "key_release", "key_asset"} or data["schema"] != 1:
        raise ValueError("invalid recovery manifest")
    if not SHA.fullmatch(data["tooling_revision"]):
        raise ValueError("tooling revision must be a full commit SHA")
    if not NAME.fullmatch(data["key_release"]) or not NAME.fullmatch(data["key_asset"]):
        raise ValueError("invalid recovery key reference")
    return data


def extract(archive, destination):
    destination = Path(destination)
    destination.mkdir(mode=0o700)
    with tarfile.open(archive, "r:gz") as source:
        entries = []
        total = 0
        root = None
        seen = set()
        for count, member in enumerate(source):
            if count >= 2000 or member.size < 0:
                raise ValueError("archive exceeds member limit")
            parts = PurePosixPath(member.name).parts
            if not parts or member.name.startswith("/") or ".." in parts:
                raise ValueError("unsafe archive path")
            root = root or parts[0]
            if root != parts[0] or not (member.isdir() or member.isfile()):
                raise ValueError("archive must contain one root and no links or devices")
            total += member.size
            if total > MAX_BYTES:
                raise ValueError("configuration archive exceeds 16 MiB")
            if len(parts) == 1:
                if not member.isdir():
                    raise ValueError("archive root must be a directory")
                continue
            relative = str(PurePosixPath(*parts[1:]))
            if relative in seen:
                raise ValueError("duplicate archive member")
            seen.add(relative)
            entries.append((member, destination / relative))
        for member, target in entries:
            if member.isdir():
                target.mkdir(mode=0o700, parents=True, exist_ok=True)
            else:
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with source.extractfile(member) as src, target.open("xb") as dst:
                    os.chmod(target, 0o600)
                    dst.write(src.read())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("extract", "profile", "manifest", "tree", "prepare"))
    parser.add_argument("source")
    parser.add_argument("destination", nargs="?")
    args = parser.parse_args()
    if args.command == "extract":
        extract(args.source, args.destination)
    elif args.command == "tree":
        # Only the encrypted profile and a non-secret manifest enter Git history.
        folder = Path(args.source)
        files = sorted(folder.rglob("*"))
        tree = [{"path": str(p.relative_to(folder)), "mode": "100644", "type": "blob", "content": p.read_text()} for p in files if p.is_file()]
        print(json.dumps({"base_tree": args.destination, "tree": tree}))
    else:
        path = Path(args.source)
        if path.stat().st_size > MAX_BYTES:
            raise ValueError("configuration exceeds 16 MiB")
        data = json.loads(path.read_text())
        if args.command in ("profile", "prepare"):
            profile(data)
            if args.command == "prepare":
                home = Path(pwd.getpwuid(os.getuid()).pw_dir)
                for item in data["files"]:
                    target = home / item["path"]
                    for part in [target, *target.parents]:
                        if part == home:
                            break
                        if part.is_symlink() or (part.exists() and part != target and not part.is_dir()):
                            raise ValueError("refusing a symlink or non-directory in destination path")
                payload = Path(args.destination).parent / "payload"
                payload.mkdir(mode=0o700)
                for index, item in enumerate(data["files"]):
                    source = payload / str(index)
                    with os.fdopen(os.open(source, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
                        output.write(item.pop("content"))
                    item["source"] = str(source)
                Path(args.destination).write_text(json.dumps(data))
                os.chmod(args.destination, 0o600)
        else:
            data = manifest(data)
            print("\n".join(data[key] for key in ("tooling_revision", "key_release", "key_asset")))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, TypeError, KeyError, OSError, tarfile.TarError):
        raise SystemExit("Invalid recovery input; no secret values were printed.") from None
