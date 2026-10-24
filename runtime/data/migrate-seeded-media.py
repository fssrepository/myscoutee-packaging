#!/usr/bin/env python3
"""Prepare/retire exact package-owned media through the existing MinIO client.

Used by the normal migration runner and container-only release updates. Never
mirror a bucket or delete user uploads, upload originals or customized objects.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import uuid


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def missing_object(value):
    if isinstance(value, dict):
        # The packaged mc version emits this cause without an S3 error code.
        if value.get('message') == 'Object does not exist' and value.get('error') == {}:
            return True
        return any((key.lower() == 'code' and item in ('NoSuchKey', 'NoSuchObject', 'NotFound'))
                   or missing_object(item) for key, item in value.items())
    if isinstance(value, list):
        return any(missing_object(item) for item in value)
    return False


class Minio:
    def __init__(self):
        bucket = run('docker', 'exec', 'minio', 'sh', '-c',
                     'printf "%s" "${MEDIA_BUCKET:-myscoutee-media}"').decode()
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', bucket):
            raise ValueError('Invalid installed media bucket')
        self.root = 'myscoutee/' + bucket + '/'

    def stat(self, key):
        result = subprocess.run(['docker', 'exec', 'minio', 'mc', 'stat', '--json', self.root + key],
                                capture_output=True)
        value = json.loads(result.stdout)
        if result.returncode:
            if missing_object(value):
                return None
            raise RuntimeError('Cannot inspect package media object')
        return value

    def sha256(self, key, metadata):
        # A changed package key could contain custom data. Do not read an
        # unbounded object just to decide whether it is the retired default.
        if metadata.get('size', 0) > 16 * 1024 * 1024:
            return None
        return hashlib.sha256(run('docker', 'exec', 'minio', 'mc', 'cat', self.root + key)).hexdigest()

    def put(self, path, key):
        temporary = '/tmp/myscoutee-seeded-media-' + uuid.uuid4().hex + '.webp'
        try:
            run('docker', 'cp', str(path), 'minio:' + temporary)
            run('docker', 'exec', 'minio', 'mc', 'cp', '--attr', 'Content-Type=image/webp',
                temporary, self.root + key)
        finally:
            run('docker', 'exec', 'minio', 'rm', '-f', temporary)

    def remove(self, key):
        run('docker', 'exec', 'minio', 'mc', 'rm', '--force', self.root + key)


def migrate(phase, manifest, media_root, store=None):
    data = json.loads(manifest.read_text())
    rows = data.get('minio')
    if data.get('schemaVersion') != 1 or not isinstance(rows, list) or not 0 < len(rows) <= 64:
        raise ValueError('Invalid seeded-image upgrade manifest')
    sources = []
    for row in rows:
        for key in ('key', *(['previousKey'] if 'previousKey' in row else [])):
            value = row[key]
            if not re.fullmatch(r'images/system/[a-zA-Z0-9_./-]+', value) or any(
                    part in ('', '.', '..') for part in value.split('/')):
                raise ValueError('Only exact package-owned system image keys are allowed')
        if ('previousKey' in row and not row['previousKey'].endswith('.png')) or not row['key'].endswith('.webp'):
            raise ValueError('Expected a PNG-to-WebP package upgrade')
        for key in ('sha256', *(['previousSha256'] if 'previousKey' in row else [])):
            if not re.fullmatch(r'[0-9a-f]{64}', row[key]):
                raise ValueError('Invalid package image checksum')
        source = media_root / row['key']
        if source.is_symlink() or not source.resolve().is_relative_to(media_root.resolve()):
            raise ValueError('Unsafe package media path')
        content = source.read_bytes()
        if (hashlib.sha256(content).hexdigest() != row['sha256']
                or content[:4] != b'RIFF' or content[8:12] != b'WEBP'):
            raise ValueError('Packaged WebP does not match its recorded checksum/type')
        sources.append((row, source))
    if phase == 'check-inputs':
        return
    if store is None:
        store = Minio()
    for row, source in sources:
        previous = store.stat(row['previousKey']) if 'previousKey' in row else None
        previous_matches = previous is None or store.sha256(row['previousKey'], previous) == row['previousSha256']
        if phase == 'prepare' and not previous_matches:
            raise RuntimeError('Customized package PNG retained; resolve its references before migration')
        current = store.stat(row['key'])
        valid = current is not None and store.sha256(row['key'], current) == row['sha256']
        if current is not None and not valid:
            raise RuntimeError('Customized replacement key retained; refusing to overwrite it')
        correct_type = current is not None and current.get('metadata', {}).get('Content-Type') == 'image/webp'
        if (not valid or not correct_type) and phase == 'prepare':
            store.put(source, row['key'])
            current = store.stat(row['key'])
            valid = current is not None and store.sha256(row['key'], current) == row['sha256']
        if not valid or current.get('metadata', {}).get('Content-Type') != 'image/webp':
            raise RuntimeError('Replacement WebP must be stored and verified before references/PNG retirement')
        if phase == 'retire':
            if previous is not None:
                if previous_matches:
                    store.remove(row['previousKey'])
                else:
                    print('Retained customized object at package key: ' + row['previousKey'])
    print('Seeded media ' + phase + ': ' + str(len(rows)) + ' verified replacement(s).')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['check-inputs', 'prepare', 'retire'])
    parser.add_argument('manifest', type=Path)
    parser.add_argument('media_root', type=Path)
    args = parser.parse_args()
    if args.phase != 'check-inputs' and os.geteuid() != 0:
        parser.error('Run on the deployment host as root')
    migrate(args.phase, args.manifest, args.media_root)
