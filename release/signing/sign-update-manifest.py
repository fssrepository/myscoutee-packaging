#!/usr/bin/env python3
"""Sign standalone update metadata for the myscoutee-update.json GitHub asset.

The input uses the existing update_manifest fields (snake_case). Package
version/channel/size/hash/signature must match sign-release-artifacts.sh output.
The existing release key is supplied explicitly; no key is generated or copied.
"""
import argparse
import base64
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile


VERSION_PATTERN = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-qa\.(0|[1-9][0-9]*))?')


def validate_compatibility(document, policy_path):
    """The catalog governs the installed worker, not the signed SSH installer."""
    values = []
    for field in ('release_version', 'minimum_compatible_version', 'maximum_compatible_version'):
        value = document.get(field, '')
        if not isinstance(value, str) or not VERSION_PATTERN.fullmatch(value):
            raise ValueError(f'Invalid {field}')
        values.append(value.replace('-', '~'))
    version, minimum, maximum = values
    def compare(a, operation, b):
        return subprocess.run(['dpkg', '--compare-versions', a, operation, b], check=False).returncode == 0
    if compare(minimum, 'gt', maximum):
        raise ValueError('The update compatibility range is inverted')
    # Product history belongs to the versioned policy; the signer enforces it.
    # Missing or malformed policy must never silently disable compatibility checks.
    policy = json.loads(Path(policy_path).read_text())
    if (not isinstance(policy, dict) or set(policy) != {'schemaVersion', 'requirements'}
            or type(policy['schemaVersion']) is not int or policy['schemaVersion'] != 1
            or not isinstance(policy['requirements'], list)):
        raise ValueError('Invalid update compatibility policy')
    for rule in policy['requirements']:
        if (not isinstance(rule, dict)
                or set(rule) != {'releaseAtLeast', 'installedAtLeast', 'reason'}
                or not isinstance(rule['reason'], str) or not rule['reason'].strip()
                or any(not isinstance(rule[key], str) or not VERSION_PATTERN.fullmatch(rule[key])
                       for key in ('releaseAtLeast', 'installedAtLeast'))):
            raise ValueError('Invalid update compatibility requirement')
        if (compare(version, 'ge', rule['releaseAtLeast'].replace('-', '~'))
                and compare(minimum, 'lt', rule['installedAtLeast'].replace('-', '~'))):
            raise ValueError(rule['reason'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--private-key', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--compatibility-policy', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Output already exists; refusing to replace published metadata')
    if args.private_key.is_symlink() or not args.private_key.is_file():
        parser.error('The existing signing key must be a regular file')
    manifest = args.manifest.read_bytes()
    if len(manifest) > 128 * 1024:
        parser.error('Update manifest is too large')
    document = json.loads(manifest)
    if document.get('manifest_version') != '1' or document.get('backup_required') is not False:
        parser.error('Expected update manifest v1 without an automatic data backup')
    try:
        validate_compatibility(document, args.compatibility_policy)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix='myscoutee-update-sign-') as directory:
        work = Path(directory)
        message = work / 'message'
        message.write_bytes(b'myscoutee-update-catalog-v1\n' + manifest)
        signature = subprocess.check_output([
            'openssl', 'pkeyutl', '-sign', '-inkey', str(args.private_key),
            '-passin', 'pass:', '-rawin', '-in', str(message)])
        if len(signature) != 64:
            parser.error('Expected a 64-byte Ed25519 signature')
        envelope = {'schemaVersion': 1, 'manifestBase64': base64.b64encode(manifest).decode(),
                    'signature': base64.b64encode(signature).decode()}
        with args.output.open('x') as target:
            json.dump(envelope, target, indent=2)
            target.write('\n')
    args.output.chmod(0o644)


if __name__ == '__main__':
    main()
