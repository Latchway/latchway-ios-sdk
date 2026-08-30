#!/usr/bin/env python3
"""Deterministically bind every safe directory and regular file in an iOS .app."""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import pathlib
import stat
import struct
import sys
import unicodedata


HASH_PROFILE = "latchway.ios-app-bundle-tree.v1"
MAX_ENTRIES = 20_000
MAX_EXPANDED_BYTES = 1_073_741_824
MAX_DEPTH = 64


class BundleTreeError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class BundleTreeDigest:
    sha256: str
    entry_count: int
    regular_file_count: int
    directory_count: int
    expanded_bytes: int

    def as_dict(self) -> dict[str, int | str]:
        return {
            "directory_count": self.directory_count,
            "entry_count": self.entry_count,
            "expanded_bytes": self.expanded_bytes,
            "hash_profile": HASH_PROFILE,
            "regular_file_count": self.regular_file_count,
            "tree_sha256": self.sha256,
        }


@dataclasses.dataclass(frozen=True)
class _Record:
    kind: bytes
    path: bytes
    mode: int
    size: int = 0
    content_sha256: bytes = b""


@dataclasses.dataclass
class _DirectoryFrame:
    descriptor: int
    raw_parts: tuple[str, ...]
    names: list[str]
    baseline: tuple[int, int, int, int, int, int, int]
    index: int = 0


def _canonical_component(component: str) -> str:
    if not component or component in {".", ".."} or "\x00" in component or "/" in component:
        raise BundleTreeError("application bundle contains an invalid path component")
    try:
        component.encode("utf-8", "strict")
    except UnicodeError as error:
        raise BundleTreeError("application bundle path is not valid UTF-8") from error
    return unicodedata.normalize("NFC", component)


def assert_no_case_or_nfc_collisions(paths: list[str]) -> None:
    observed: dict[str, str] = {}
    for path in paths:
        canonical = "/".join(_canonical_component(part) for part in path.split("/"))
        collision_key = canonical.casefold()
        if collision_key in observed and observed[collision_key] != path:
            raise BundleTreeError("application bundle contains a case or Unicode-normalization collision")
        observed[collision_key] = path


def _stable_identity(value: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _open_directory_at(
    parent_descriptor: int | None,
    name: str | os.PathLike[str],
    expected: os.stat_result,
) -> int:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        if parent_descriptor is None:
            descriptor = os.open(name, flags)
        else:
            descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    except OSError as error:
        raise BundleTreeError("application bundle directory could not be opened safely") from error
    try:
        actual = os.fstat(descriptor)
        if not stat.S_ISDIR(actual.st_mode) or _stable_identity(actual) != _stable_identity(expected):
            raise BundleTreeError("application bundle changed during inspection")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _directory_frame(
    descriptor: int,
    raw_parts: tuple[str, ...],
) -> _DirectoryFrame:
    baseline = os.fstat(descriptor)
    try:
        names = os.listdir(descriptor)
    except OSError as error:
        raise BundleTreeError("application bundle directory could not be read safely") from error
    if not all(isinstance(name, str) for name in names):
        raise BundleTreeError("application bundle path is not valid UTF-8")
    return _DirectoryFrame(
        descriptor=descriptor,
        raw_parts=raw_parts,
        names=names,
        baseline=_stable_identity(baseline),
    )


def _regular_file_digest(
    directory_descriptor: int,
    name: str,
    expected: os.stat_result,
) -> bytes:
    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(name, flags, dir_fd=directory_descriptor)
    except OSError as error:
        raise BundleTreeError("application bundle file could not be opened safely") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or _stable_identity(before) != _stable_identity(expected):
            raise BundleTreeError("application bundle changed during inspection")
        digest = hashlib.sha256()
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            digest.update(block)
        after = os.fstat(descriptor)
        if _stable_identity(after) != _stable_identity(before):
            raise BundleTreeError("application bundle changed during inspection")
        return digest.digest()
    finally:
        os.close(descriptor)


def _app_bundle_tree_digest_once(
    root: pathlib.Path | str,
    *,
    max_entries: int = MAX_ENTRIES,
    max_expanded_bytes: int = MAX_EXPANDED_BYTES,
    max_depth: int = MAX_DEPTH,
) -> BundleTreeDigest:
    root = pathlib.Path(root)
    if root.suffix != ".app":
        raise BundleTreeError("application bundle root must end in .app")
    try:
        root_status = os.lstat(root)
    except OSError as error:
        raise BundleTreeError("application bundle root is unavailable") from error
    if stat.S_ISLNK(root_status.st_mode) or not stat.S_ISDIR(root_status.st_mode):
        raise BundleTreeError("application bundle root must be a real directory")
    if max_entries < 1 or max_expanded_bytes < 0 or max_depth < 0:
        raise BundleTreeError("application bundle limits are invalid")

    root_descriptor = _open_directory_at(None, root, root_status)
    records: list[_Record] = [
        _Record(kind=b"D", path=b".", mode=stat.S_IMODE(root_status.st_mode))
    ]
    raw_paths: list[str] = []
    expanded_bytes = 0
    regular_files = 0
    directories = 1

    frames: list[_DirectoryFrame] = []
    try:
        frames.append(_directory_frame(root_descriptor, ()))
        while frames:
            frame = frames[-1]
            if frame.index == len(frame.names):
                if _stable_identity(os.fstat(frame.descriptor)) != frame.baseline:
                    raise BundleTreeError("application bundle changed during inspection")
                completed = frames.pop()
                if completed.descriptor != root_descriptor:
                    os.close(completed.descriptor)
                continue

            name = frame.names[frame.index]
            frame.index += 1
            raw_parts = (*frame.raw_parts, name)
            try:
                if len(raw_parts) > max_depth:
                    raise BundleTreeError("application bundle nesting-depth limit exceeded")
                raw_relative = "/".join(raw_parts)
                canonical_relative = "/".join(
                    _canonical_component(part) for part in raw_parts
                )
                raw_paths.append(raw_relative)
                entry_status = os.stat(
                    name,
                    dir_fd=frame.descriptor,
                    follow_symlinks=False,
                )
                if stat.S_ISLNK(entry_status.st_mode):
                    raise BundleTreeError("application bundle contains a symbolic link")
                path_bytes = canonical_relative.encode("utf-8")
                if stat.S_ISDIR(entry_status.st_mode):
                    directories += 1
                    records.append(
                        _Record(
                            kind=b"D",
                            path=path_bytes,
                            mode=stat.S_IMODE(entry_status.st_mode),
                        )
                    )
                    child_descriptor = _open_directory_at(
                        frame.descriptor,
                        name,
                        entry_status,
                    )
                    try:
                        child_frame = _directory_frame(child_descriptor, raw_parts)
                    except BaseException:
                        os.close(child_descriptor)
                        raise
                    frames.append(child_frame)
                elif stat.S_ISREG(entry_status.st_mode):
                    expanded_bytes += entry_status.st_size
                    if expanded_bytes > max_expanded_bytes:
                        raise BundleTreeError(
                            "application bundle expanded-byte limit exceeded"
                        )
                    regular_files += 1
                    records.append(
                        _Record(
                            kind=b"F",
                            path=path_bytes,
                            mode=stat.S_IMODE(entry_status.st_mode),
                            size=entry_status.st_size,
                            content_sha256=_regular_file_digest(
                                frame.descriptor, name, entry_status
                            ),
                        )
                    )
                else:
                    raise BundleTreeError(
                        "application bundle contains a special filesystem entry"
                    )
                if len(records) > max_entries:
                    raise BundleTreeError(
                        "application bundle entry-count limit exceeded"
                    )
            except BundleTreeError:
                raise
            except OSError as error:
                raise BundleTreeError(
                    "application bundle entry could not be inspected safely"
                ) from error

        final_root_status = os.lstat(root)
        if (
            _stable_identity(final_root_status) != _stable_identity(root_status)
            or _stable_identity(os.fstat(root_descriptor)) != _stable_identity(root_status)
        ):
            raise BundleTreeError("application bundle root changed during inspection")
    finally:
        for frame in reversed(frames):
            if frame.descriptor != root_descriptor:
                os.close(frame.descriptor)
        os.close(root_descriptor)

    assert_no_case_or_nfc_collisions(raw_paths)

    digest = hashlib.sha256()
    digest.update(HASH_PROFILE.encode("ascii") + b"\x00")
    for record in sorted(records, key=lambda value: (value.path, value.kind)):
        digest.update(record.kind)
        digest.update(struct.pack(">I", len(record.path)))
        digest.update(record.path)
        digest.update(struct.pack(">I", record.mode))
        if record.kind == b"F":
            digest.update(struct.pack(">Q", record.size))
            digest.update(record.content_sha256)
    return BundleTreeDigest(
        sha256=digest.hexdigest(),
        entry_count=len(records),
        regular_file_count=regular_files,
        directory_count=directories,
        expanded_bytes=expanded_bytes,
    )


def app_bundle_tree_digest(
    root: pathlib.Path | str,
    *,
    max_entries: int = MAX_ENTRIES,
    max_expanded_bytes: int = MAX_EXPANDED_BYTES,
    max_depth: int = MAX_DEPTH,
) -> BundleTreeDigest:
    """Require two complete descriptor-relative passes over identical bytes."""
    arguments = {
        "max_entries": max_entries,
        "max_expanded_bytes": max_expanded_bytes,
        "max_depth": max_depth,
    }
    first = _app_bundle_tree_digest_once(root, **arguments)
    second = _app_bundle_tree_digest_once(root, **arguments)
    if first != second:
        raise BundleTreeError("application bundle changed between inspection passes")
    return second


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("application_bundle")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    arguments = parser.parse_args()
    result = app_bundle_tree_digest(arguments.application_bundle)
    if arguments.emit_json:
        print(json.dumps(result.as_dict(), separators=(",", ":"), sort_keys=True))
    else:
        print(result.sha256)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BundleTreeError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from None
