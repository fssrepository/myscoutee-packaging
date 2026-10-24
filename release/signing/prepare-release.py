#!/usr/bin/env python3
"""Prepare a complete signed release using the canonical artifact/catalog signers.

Requires an explicitly supplied existing key. Does not create keys, upload,
install, or modify a deployment. The result lists the only publishable files.
"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
from types import SimpleNamespace

SOURCE = Path(__file__).resolve().parents[2]


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def prepare_release(deb, client_tools, key, tag, minimum_version, maximum_version,
                    repository, channel, project_root):
    project_root = Path(project_root).resolve()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Expected a GitHub owner/repository')
    for path in (deb, client_tools, key):
        if path.is_symlink() or not path.is_file():
            raise ValueError('Inputs must be regular non-symlink files')
    args = SimpleNamespace(deb=deb, client_tools=client_tools, tag=tag,
                           minimum_version=minimum_version, maximum_version=maximum_version)
    version = run('dpkg-deb', '-f', deb, 'Version').replace('~', '-')
    if tag != 'v' + version or (channel == 'stable' and '-qa.' in version):
        raise ValueError('Tag/channel must match the actual Debian version')
    project_policy = project_root / 'config/packaging/release-project.json'
    if not project_policy.exists():
        project_policy = project_root / 'packaging/scripts/release-project.json'
    project = json.loads(project_policy.read_text())['packageName']
    output = deb.resolve().parent
    if client_tools.resolve().parent != output or key.resolve().is_relative_to(output):
        raise ValueError('Artifacts must share an output directory; keep the key outside it')
    names = ['RELEASE.json', 'update-manifest.source.json', 'myscoutee-update.json',
             f'{project}-release_{version}.json', 'release-public.pem']
    if any((output / name).exists() or (output / name).is_symlink() for name in names):
        raise ValueError('Signed output already exists; refusing to replace it')
    run('bash', SOURCE / 'release/signing/sign-release-artifacts.sh', '--project-root', project_root,
        '--private-key', key, '--deb', args.deb.resolve(),
        '--client-tools', args.client_tools.resolve(), '--channel', channel, '--output-dir', output)
    package_manifest = json.loads((output / f'{project}-release_{version}.json').read_text())
    artifact = next(item for item in package_manifest['artifacts'] if item['purpose'] == 'debian-package')
    public_key = output / 'release-public.pem'
    run('openssl', 'pkey', '-in', key, '-pubout', '-out', public_key)
    public_der = subprocess.check_output(['openssl', 'pkey', '-pubin', '-in', str(public_key), '-outform', 'DER'])
    manifest = {
        'manifest_version': '1', 'release_version': version, 'channel': channel,
        'published_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'minimum_compatible_version': args.minimum_version,
        'maximum_compatible_version': args.maximum_version,
        'artifact_url': f'https://github.com/{repository}/releases/download/{args.tag}/{artifact["filename"]}',
        'artifact_size_bytes': artifact['sizeBytes'], 'artifact_sha256': artifact['sha256'],
        'package_signing_key_id': package_manifest['signingKeyId'],
        'package_signature': artifact['signature'],
        'release_notes_url': f'https://github.com/{repository}/releases/tag/{args.tag}',
        'backup_required': False, 'expected_downtime_seconds': 300, 'status': 'AVAILABLE',
        'supersedes_version': args.maximum_version if version != args.maximum_version else '', 'superseded_by_version': '', 'revocation_reason': ''
    }
    source = output / 'update-manifest.source.json'
    source.write_text(json.dumps(manifest, indent=2) + '\n')
    run('python3', SOURCE / 'release/signing/sign-update-manifest.py', '--private-key', key,
        '--compatibility-policy', project_root / 'config/packaging/release/update-compatibility-policy.json',
        '--manifest', source, '--output', output / 'myscoutee-update.json')
    fingerprint = 'sha256:' + hashlib.sha256(public_der).hexdigest()
    for path in (args.deb.resolve(), args.client_tools.resolve()):
        run('node', project_root / 'config/packaging/node_modules/@fssrepository/myscoutee-packaging/bin/packaging.mjs',
            '--project-root', project_root, 'client', 'verify-release', path,
            output / f'{project}-release_{version}.json', public_key, fingerprint)
    envelope = json.loads((output / 'myscoutee-update.json').read_text())
    with tempfile.TemporaryDirectory(prefix='qa-sign-verify-') as temp:
        message, signature = Path(temp) / 'message', Path(temp) / 'signature'
        message.write_bytes(b'myscoutee-update-catalog-v1\n' + base64.b64decode(envelope['manifestBase64'], validate=True))
        signature.write_bytes(base64.b64decode(envelope['signature'], validate=True))
        run('openssl', 'pkeyutl', '-verify', '-pubin', '-inkey', public_key,
            '-rawin', '-in', message, '-sigfile', signature)
    checksums = []
    for path in (args.deb.resolve(), args.client_tools.resolve()):
        with path.open('rb') as stream:
            hasher = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                hasher.update(chunk)
            checksum = hasher.hexdigest()
        name = path.name + '.sha256'
        (output / name).write_text(f'{checksum}  {path.name}\n')
        (output / name).chmod(0o644)
        checksums.append(name)
    record = {'tag': tag, 'version': version, 'channel': channel, 'repository': repository,
              'artifactSha256': artifact['sha256'], 'trustedPublicKeySpkiSha256': fingerprint,
              'upload': [artifact['filename'], client_tools.name, f'{project}-release_{version}.json',
                         'myscoutee-update.json', 'release-public.pem', *checksums],
              'privateKeyPublished': False, 'artifactSignaturesVerified': True,
              'updateManifestSignatureVerified': True}
    (output / 'RELEASE.json').write_text(json.dumps(record, indent=2) + '\n')
    public_key.chmod(0o644)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ('deb', 'client-tools', 'private-key'):
        parser.add_argument('--' + option, type=Path, required=True)
    for option in ('tag', 'minimum-version', 'maximum-version', 'repository'):
        parser.add_argument('--' + option, required=True)
    parser.add_argument('--channel', choices=['stable', 'qa'], required=True)
    parser.add_argument('--project-root', type=Path, required=True)
    args = parser.parse_args()
    record = prepare_release(args.deb, args.client_tools, args.private_key, args.tag,
                             args.minimum_version, args.maximum_version,
                             args.repository, args.channel, args.project_root)
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
