#!/usr/bin/env python3
# Source-checkout package audit helper; deliberately not installed by the DEB.
"""Detect complete ASCII-armored private-key payloads without marker-only false positives."""

from __future__ import annotations

import base64
import binascii
import re
import sys
from typing import BinaryIO


CHUNK_SIZE = 1024 * 1024
MAX_ARMORED_BLOCK_SIZE = 4 * 1024 * 1024
BEGIN_MARKER = re.compile(
    rb"-----BEGIN ((?:[A-Z0-9]+ )*PRIVATE KEY|PGP PRIVATE KEY BLOCK)-----\r?\n"
)
BASE64_LINE = re.compile(rb"^[A-Za-z0-9+/]+={0,2}$")


def _has_encoded_payload(body: bytes) -> bool:
    payload_lines: list[bytes] = []
    in_armor_headers = True
    for raw_line in body.splitlines():
        line = raw_line.strip()
        if not line:
            in_armor_headers = False
            continue
        if in_armor_headers and b":" in line:
            continue
        in_armor_headers = False
        if line.startswith(b"="):
            continue
        if not BASE64_LINE.fullmatch(line):
            return False
        payload_lines.append(line)

    encoded = b"".join(payload_lines)
    if len(encoded) < 24:
        return False
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError):
        return False
    return len(decoded) >= 16


def contains_private_key_material(stream: BinaryIO) -> bool:
    buffer = b""
    eof = False
    while not eof:
        chunk = stream.read(CHUNK_SIZE)
        eof = not chunk
        buffer += chunk

        while True:
            begin = BEGIN_MARKER.search(buffer)
            if begin is None:
                buffer = buffer[-256:]
                break

            label = begin.group(1)
            end_marker = b"-----END " + label + b"-----"
            end = buffer.find(end_marker, begin.end())
            if end < 0:
                if len(buffer) - begin.start() > MAX_ARMORED_BLOCK_SIZE:
                    return True
                buffer = buffer[begin.start():]
                break

            if _has_encoded_payload(buffer[begin.end():end]):
                return True
            buffer = buffer[end + len(end_marker):]

    return False


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: private_key_material.py <file> [<file> ...]", file=sys.stderr)
        return 2
    try:
        for path in sys.argv[1:]:
            with open(path, "rb") as source:
                if contains_private_key_material(source):
                    print(path)
                    return 0
    except OSError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
