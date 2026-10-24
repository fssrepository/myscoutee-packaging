#!/usr/bin/env python3
"""Prepare a signed QA GitHub release; never upload, install, or start an update.

The QA-only private key stays outside the repository and release directory.
Existing package signatures and hashes are produced by the normal release tools.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()
PACKAGE = Path(__file__).resolve().parents[2]


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deb', type=Path, required=True)
    parser.add_argument('--client-tools', type=Path, required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--minimum-version', required=True)
    parser.add_argument('--maximum-version', required=True)
    parser.add_argument('--key-directory', type=Path, required=True)
    parser.add_argument('--create-qa-key', action='store_true')
    args = parser.parse_args()
    PRODUCT = json.loads((ROOT / 'config/packaging/release-project.json').read_text())['packageName']
    os.umask(0o077)
    key_dir = args.key_directory.resolve()
    if key_dir.is_relative_to(ROOT) or not re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-qa\.(0|[1-9][0-9]*)', args.tag):
        parser.error('Use an external QA key directory and a versioned QA tag')
    version = run('dpkg-deb', '-f', args.deb, 'Version').replace('~', '-')
    if args.tag != f'v{version}':
        parser.error('Tag must match the actual Debian prerelease version')
    output = args.deb.resolve().parent
    if args.client_tools.resolve().parent != output or key_dir.is_relative_to(output):
        parser.error('Both artifacts must share a release directory; key storage must be outside it')
    if any((output / name).exists() for name in ('QA-RELEASE.json', 'myscoutee-update.json', f'{PRODUCT}-release_{version}.json')):
        parser.error('Signed output already exists; refusing to overwrite it')
    # Limit compatibility to canonical versions accepted by the release tooling.
    for value in (args.minimum_version, args.maximum_version):
        if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-qa\.(0|[1-9][0-9]*))?', value):
            parser.error('Compatibility versions must be canonical core or QA versions')
    if subprocess.run(['dpkg', '--compare-versions', args.minimum_version.replace('-', '~'),
                       'gt', args.maximum_version.replace('-', '~')]).returncode == 0:
        parser.error('Minimum compatible version exceeds maximum')
    key_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if key_dir.stat().st_mode & 0o077:
        parser.error('QA key directory must have mode 0700')
    key = key_dir / 'qa-release-private.pem'
    if key.is_symlink():
        parser.error('QA private key must not be a symbolic link')
    if not key.exists():
        if not args.create_qa_key:
            parser.error('No retained QA key; explicitly use --create-qa-key for first preparation')
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'Ed25519', '-out', str(key)], check=True)
        key.chmod(0o600)
    if key.is_symlink() or not key.is_file() or key.stat().st_mode & 0o077:
        parser.error('QA private key must be a regular protected file')
    import importlib.util
    spec = importlib.util.spec_from_file_location('release_bundle', PACKAGE / 'release/signing/prepare-release.py')
    bundle = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bundle)
    record = bundle.prepare_release(args.deb, args.client_tools, key, args.tag,
                                    args.minimum_version, args.maximum_version,
                                    json.loads((ROOT / 'config/packaging/release/qa.json').read_text())['repository'], 'qa', ROOT)
    record['purpose'] = 'QA only; not a production vendor trust root'
    public_key = output / 'release-public.pem'
    # Retain the historical QA filename as well as the shared bundle's public key.
    import shutil
    shutil.copyfile(public_key, output / 'qa-release-public.pem')
    record['upload'].remove('release-public.pem')
    (output / 'QA-RELEASE.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
