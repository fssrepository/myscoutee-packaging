#!/usr/bin/env python3
# Source-checkout package audit; deliberately not installed by the DEB.
"""Fail-closed credential, key, and deployment-identifier audit for ZIP/JAR payloads."""

from __future__ import annotations

import io
import json
import hashlib
import re
import sys
import zipfile
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'signing'))
from private_key_material import contains_private_key_material


MAX_ENTRIES = 100_000
MAX_TOTAL_UNCOMPRESSED = 2 * 1024 * 1024 * 1024
MAX_NESTED_ARCHIVE = 512 * 1024 * 1024
MAX_DEPTH = 3

FORBIDDEN_PATH = re.compile(
    r"(^|/)(firebase-service-account\.json|\.env\.secrets|"
    r"application-secrets\.ya?ml|[^/]*(client-secret|provider-credentials)"
    r"[^/]*\.json|id_(rsa|dsa|ecdsa|ed25519)|"
    r"deployment-private-key\.pem|registry-demo-signing-key\.pem|"
    r"[^/]*\.(p12|pfx|jks|keystore))$",
    re.IGNORECASE,
)
DEFAULT_POLICY = json.loads((Path(__file__).resolve().parent.parent / 'lib/defaults.json').read_text())['audit']
PERSONAL_EMAIL = re.compile(DEFAULT_POLICY['nestedArchive']['consumerEmailPattern'].encode(), re.IGNORECASE)
PERSONAL_SOCIAL_PROFILE = re.compile(DEFAULT_POLICY['nestedArchive']['personalSocialPattern'].encode(), re.IGNORECASE)
PUBLIC_PRODUCT_SOCIAL_PROFILES = tuple(value.encode() for value in DEFAULT_POLICY['allowedSocialUrls'])
FIXED_BOOTSTRAP_PASSWORD_HASH = re.compile(
    rb"operator[-_]bootstrap[-_]password[-_]sha256[=:][ \t]*[0-9a-f]{64}",
    re.IGNORECASE,
)
FIXED_BOOTSTRAP_EMAIL = re.compile(
    rb"operator[-_]bootstrap[-_]email[=:][ \t]*"
    rb"operator-[0-9a-f]{24}@deployment\.invalid",
    re.IGNORECASE,
)
TEXT_KEY_EXTENSIONS = {
    ".cfg",
    ".conf",
    ".env",
    ".json",
    ".key",
    ".p8",
    ".pem",
    ".properties",
    ".xml",
    ".yaml",
    ".yml",
}
NESTED_EXTENSIONS = {".jar", ".war", ".zip"}
PUBLIC_TRUSTSTORE_PATHS = set(DEFAULT_POLICY['nestedArchive']['publicTruststorePaths'])
# Reviewed certificate-only payloads remain pinned by digest, never by filename.
PUBLIC_TRUSTSTORE_SHA256 = DEFAULT_POLICY['nestedArchive']['publicTruststoreSha256']


class AuditBudget:
    def __init__(self) -> None:
        self.entries = 0
        self.uncompressed = 0

    def add(self, info: zipfile.ZipInfo) -> None:
        self.entries += 1
        self.uncompressed += info.file_size
        if self.entries > MAX_ENTRIES:
            raise ValueError("nested archive entry limit exceeded")
        if self.uncompressed > MAX_TOTAL_UNCOMPRESSED:
            raise ValueError("nested archive uncompressed-size limit exceeded")


def normalized_name(raw_name: str) -> str:
    name = raw_name.replace("\\", "/").lstrip("/")
    path = PurePosixPath(name)
    if any(part in {"", ".", ".."} for part in path.parts):
        raise ValueError("unsafe nested archive member path")
    return str(path)


def contains_private_key_marker(entry: zipfile.ZipExtFile) -> bool:
    return contains_private_key_material(entry)


def contains_personal_email(entry: zipfile.ZipExtFile) -> bool:
    overlap = b""
    while True:
        chunk = entry.read(1024 * 1024)
        if not chunk:
            return False
        candidate = overlap + chunk
        if PERSONAL_EMAIL.search(candidate):
            return True
        overlap = candidate[-256:]


def contains_personal_social_profile(entry: zipfile.ZipExtFile, profiles=PUBLIC_PRODUCT_SOCIAL_PROFILES) -> bool:
    overlap = b""
    while True:
        chunk = entry.read(1024 * 1024)
        if not chunk:
            return False
        candidate = overlap + chunk
        scrubbed = candidate
        for public_profile in profiles:
            scrubbed = scrubbed.replace(public_profile, b"")
        if PERSONAL_SOCIAL_PROFILE.search(scrubbed):
            return True
        overlap = candidate[-512:]


def contains_fixed_bootstrap_password_hash(entry: zipfile.ZipExtFile) -> bool:
    overlap = b""
    while True:
        chunk = entry.read(1024 * 1024)
        if not chunk:
            return False
        candidate = overlap + chunk
        if FIXED_BOOTSTRAP_PASSWORD_HASH.search(candidate):
            return True
        overlap = candidate[-256:]


def contains_fixed_bootstrap_email(entry: zipfile.ZipExtFile) -> bool:
    overlap = b""
    while True:
        chunk = entry.read(1024 * 1024)
        if not chunk:
            return False
        candidate = overlap + chunk
        if FIXED_BOOTSTRAP_EMAIL.search(candidate):
            return True
        overlap = candidate[-256:]


def is_application_owned_text(name: str, suffix: str) -> bool:
    return (
        suffix in TEXT_KEY_EXTENSIONS
        and (
            name.startswith("BOOT-INF/classes/")
            or name.startswith("WEB-INF/classes/")
            or name.startswith("public/")
            or name.startswith("static/")
        )
    )


def audit_zip(
    source: str | io.BytesIO,
    label: str,
    budget: AuditBudget,
    depth: int,
    public_profiles=PUBLIC_PRODUCT_SOCIAL_PROFILES,
) -> None:
    try:
        archive = zipfile.ZipFile(source)
    except (OSError, zipfile.BadZipFile) as exc:
        raise ValueError(f"invalid nested archive: {label}") from exc

    with archive:
        for info in archive.infolist():
            budget.add(info)
            name = normalized_name(info.filename)
            if info.is_dir():
                continue
            if FORBIDDEN_PATH.search(name) and name not in PUBLIC_TRUSTSTORE_PATHS:
                approved_digest = PUBLIC_TRUSTSTORE_SHA256.get(name)
                if (approved_digest is None or info.file_size > 1024 * 1024
                        or hashlib.sha256(archive.read(info)).hexdigest() != approved_digest):
                    raise ValueError(f"forbidden credential path in nested archive: {label}!/{name}")

            suffix = PurePosixPath(name).suffix.lower()
            if suffix in TEXT_KEY_EXTENSIONS:
                with archive.open(info, "r") as entry:
                    if contains_private_key_marker(entry):
                        raise ValueError(
                            f"private key material in nested archive: {label}!/{name}"
                        )
            if is_application_owned_text(name, suffix):
                with archive.open(info, "r") as entry:
                    if contains_personal_email(entry):
                        raise ValueError(
                            "personal deployment email in application archive: "
                            f"{label}!/{name}"
                        )
                with archive.open(info, "r") as entry:
                    if contains_personal_social_profile(entry, public_profiles):
                        raise ValueError(
                            "personal social-page URL in application archive: "
                            f"{label}!/{name}"
                        )
                with archive.open(info, "r") as entry:
                    if contains_fixed_bootstrap_password_hash(entry):
                        raise ValueError(
                            "fixed Operator bootstrap password digest in application archive: "
                            f"{label}!/{name}"
                        )
                with archive.open(info, "r") as entry:
                    if contains_fixed_bootstrap_email(entry):
                        raise ValueError(
                            "fixed Operator bootstrap subject in application archive: "
                            f"{label}!/{name}"
                        )

            if suffix not in NESTED_EXTENSIONS or depth >= MAX_DEPTH:
                continue
            if info.file_size > MAX_NESTED_ARCHIVE:
                raise ValueError(f"nested archive member is too large to audit: {label}!/{name}")
            with archive.open(info, "r") as entry:
                nested = io.BytesIO(entry.read())
            audit_zip(nested, f"{label}!/{name}", budget, depth + 1, public_profiles)


def main() -> int:
    global PERSONAL_EMAIL, PERSONAL_SOCIAL_PROFILE, PUBLIC_TRUSTSTORE_PATHS, PUBLIC_TRUSTSTORE_SHA256
    if len(sys.argv) not in (2, 3):
        print("Usage: audit-nested-archive.py <zip-or-jar> [release-settings.json]", file=sys.stderr)
        return 2
    try:
        profiles = PUBLIC_PRODUCT_SOCIAL_PROFILES
        if len(sys.argv) == 3:
            policy = json.loads(Path(sys.argv[2]).read_text())['audit']
            nested = policy['nestedArchive']
            PERSONAL_EMAIL = re.compile(nested['consumerEmailPattern'].encode(), re.IGNORECASE)
            PERSONAL_SOCIAL_PROFILE = re.compile(nested['personalSocialPattern'].encode(), re.IGNORECASE)
            PUBLIC_TRUSTSTORE_PATHS = set(nested['publicTruststorePaths'])
            PUBLIC_TRUSTSTORE_SHA256 = nested['publicTruststoreSha256']
            values = policy['allowedSocialUrls']
            if not isinstance(values, list) or not all(isinstance(value, str) and value.startswith(('https://', 'http://')) for value in values):
                raise ValueError('Invalid social URL exceptions')
            profiles = tuple(value.encode() for value in values)
        audit_zip(sys.argv[1], sys.argv[1], AuditBudget(), 0, profiles)
    except (ValueError, KeyError, TypeError, OSError, re.error) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
