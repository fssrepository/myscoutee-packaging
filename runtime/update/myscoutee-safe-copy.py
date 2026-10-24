#!/usr/bin/env python3
"""Copy an update input without following attacker-controlled path components."""

from __future__ import annotations

import argparse
import os
import re
import stat
import sys
from contextlib import ExitStack


JOB_ID = re.compile(r"^upd_[0-9a-f]{32}$")
COPY_CHUNK_BYTES = 1024 * 1024
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
SOURCE_FLAGS = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
DESTINATION_FLAGS = (
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW
)


class SafeCopyError(RuntimeError):
    pass


def positive_integer(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def absolute_components(path: str) -> list[str]:
    if not os.path.isabs(path):
        raise SafeCopyError("paths must be absolute")
    components = path.split("/")[1:]
    if not components or any(component in ("", ".", "..") for component in components):
        raise SafeCopyError("paths must be normalized absolute paths")
    return components


def open_directory(path: str, stack: ExitStack) -> int:
    components = absolute_components(path)
    current = os.open("/", DIRECTORY_FLAGS)
    stack.callback(os.close, current)
    for component in components:
        next_fd = os.open(component, DIRECTORY_FLAGS, dir_fd=current)
        stack.callback(os.close, next_fd)
        current = next_fd
    return current


def split_destination(path: str) -> tuple[str, str]:
    components = absolute_components(path)
    name = components[-1]
    if "/" in name or name in ("", ".", ".."):
        raise SafeCopyError("destination filename is unsafe")
    parent = "/" + "/".join(components[:-1])
    if parent == "":
        parent = "/"
    return parent, name


def source_identity(file_stat: os.stat_result) -> tuple[int, ...]:
    return (
        file_stat.st_dev,
        file_stat.st_ino,
        file_stat.st_mode,
        file_stat.st_nlink,
        file_stat.st_uid,
        file_stat.st_gid,
        file_stat.st_size,
        file_stat.st_mtime_ns,
        file_stat.st_ctime_ns,
    )


def copy_open_file(
    source_dir_fd: int,
    source_name: str,
    destination: str,
    maximum_bytes: int,
    expected_bytes: int | None,
    remove_source: bool,
) -> None:
    if "/" in source_name or source_name in ("", ".", ".."):
        raise SafeCopyError("source filename is unsafe")

    destination_parent, destination_name = split_destination(destination)
    with ExitStack() as stack:
        destination_dir_fd = open_directory(destination_parent, stack)
        source_fd = os.open(source_name, SOURCE_FLAGS, dir_fd=source_dir_fd)
        stack.callback(os.close, source_fd)
        before = os.fstat(source_fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise SafeCopyError("source must be a singly-linked regular file")
        if before.st_size < 1 or before.st_size > maximum_bytes:
            raise SafeCopyError("source exceeds the allowed size")
        if expected_bytes is not None and before.st_size != expected_bytes:
            raise SafeCopyError("source size does not match the request")

        destination_fd = -1
        created = False
        try:
            destination_fd = os.open(
                destination_name,
                DESTINATION_FLAGS,
                0o600,
                dir_fd=destination_dir_fd,
            )
            created = True
            copied = 0
            while True:
                remaining = maximum_bytes + 1 - copied
                if remaining <= 0:
                    raise SafeCopyError("source grew beyond the allowed size")
                chunk = os.read(source_fd, min(COPY_CHUNK_BYTES, remaining))
                if not chunk:
                    break
                copied += len(chunk)
                if copied > maximum_bytes:
                    raise SafeCopyError("source grew beyond the allowed size")
                view = memoryview(chunk)
                while view:
                    written = os.write(destination_fd, view)
                    if written < 1:
                        raise SafeCopyError("destination write made no progress")
                    view = view[written:]

            if expected_bytes is not None and copied != expected_bytes:
                raise SafeCopyError("copied size does not match the request")
            after = os.fstat(source_fd)
            if source_identity(before) != source_identity(after):
                raise SafeCopyError("source changed while it was copied")

            os.fchmod(destination_fd, 0o600)
            os.fsync(destination_fd)
            os.close(destination_fd)
            destination_fd = -1
            os.fsync(destination_dir_fd)

            if remove_source:
                current = os.stat(
                    source_name,
                    dir_fd=source_dir_fd,
                    follow_symlinks=False,
                )
                if source_identity(current) != source_identity(after):
                    raise SafeCopyError("source changed before cleanup")
                os.unlink(source_name, dir_fd=source_dir_fd)
                os.fsync(source_dir_fd)
        except BaseException:
            if destination_fd >= 0:
                os.close(destination_fd)
            if created:
                try:
                    os.unlink(destination_name, dir_fd=destination_dir_fd)
                    os.fsync(destination_dir_fd)
                except FileNotFoundError:
                    pass
            raise


def copy_request(args: argparse.Namespace) -> None:
    if "/" in args.name or args.name in ("", ".", ".."):
        raise SafeCopyError("request filename is unsafe")
    with ExitStack() as stack:
        source_dir_fd = open_directory(args.source_dir, stack)
        copy_open_file(
            source_dir_fd,
            args.name,
            args.destination,
            args.max_bytes,
            None,
            args.remove_source,
        )


def copy_artifact(args: argparse.Namespace) -> None:
    if not JOB_ID.fullmatch(args.job_id):
        raise SafeCopyError("job ID is invalid")
    with ExitStack() as stack:
        staging_dir_fd = open_directory(args.staging_dir, stack)
        job_dir_fd = os.open(args.job_id, DIRECTORY_FLAGS, dir_fd=staging_dir_fd)
        stack.callback(os.close, job_dir_fd)
        copy_open_file(
            job_dir_fd,
            "myscoutee.deb",
            args.destination,
            args.max_bytes,
            args.expected_bytes,
            args.remove_source,
        )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    subcommands = result.add_subparsers(dest="command", required=True)

    request = subcommands.add_parser("request")
    request.add_argument("--source-dir", required=True)
    request.add_argument("--name", required=True)
    request.add_argument("--destination", required=True)
    request.add_argument("--max-bytes", required=True, type=positive_integer)
    request.add_argument("--remove-source", action="store_true")
    request.set_defaults(handler=copy_request)

    artifact = subcommands.add_parser("artifact")
    artifact.add_argument("--staging-dir", required=True)
    artifact.add_argument("--job-id", required=True)
    artifact.add_argument("--destination", required=True)
    artifact.add_argument("--expected-bytes", required=True, type=positive_integer)
    artifact.add_argument("--max-bytes", required=True, type=positive_integer)
    artifact.add_argument("--remove-source", action="store_true")
    artifact.set_defaults(handler=copy_artifact)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        args.handler(args)
    except (OSError, SafeCopyError) as exc:
        print(f"safe copy failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
