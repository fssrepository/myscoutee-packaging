#!/usr/bin/env python3
"""Exercise the real installed mc client on an owned disposable bucket only."""
import os
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import uuid

ROOT = (Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'build')
CONTRACT = json.loads((Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'config/packaging/tests/contract-inputs.json').read_text())['contracts']['seeded-media-integration-test']
CONTRACT_INPUTS = CONTRACT['inputs']
CONTRACT_EXPECTATIONS = CONTRACT.get('expectations', {})
spec = importlib.util.spec_from_file_location('media_migration', ROOT.parent / 'build/scripts/migrate-seeded-media.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
manifest = ROOT.parent / CONTRACT_INPUTS['seeds_023_seeded_image_webp_image_replacements_json']
media = ROOT.parent / 'server/docker/conf/minio/media'
module.migrate('check-inputs', manifest, media)
store = module.Minio()
bucket = 'msc126-media-test-' + uuid.uuid4().hex
store.root = 'myscoutee/' + bucket + '/'
container_fixture = '/tmp/' + bucket + '.png'
module.run('docker', 'exec', 'minio', 'mc', 'mb', store.root)
try:
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        fixture = directory / 'old.png'
        fixture.write_bytes(b'owned disposable migration fixture')
        checksum = hashlib.sha256(fixture.read_bytes()).hexdigest()
        data = json.loads(manifest.read_text())
        previous = next(row for row in data['minio'] if 'previousKey' in row)
        previous['previousSha256'] = checksum
        test_manifest = directory / 'manifest.json'
        test_manifest.write_text(json.dumps(data))
        module.run('docker', 'cp', str(fixture), 'minio:' + container_fixture)
        for key in [previous['previousKey'], 'images/retained-upload/original']:
            module.run('docker', 'exec', 'minio', 'mc', 'cp', container_fixture, store.root + key)
        module.migrate('prepare', test_manifest, media, store)
        module.migrate('prepare', test_manifest, media, store)
        module.migrate('retire', test_manifest, media, store)
        module.migrate('retire', test_manifest, media, store)
        assert store.stat(previous['previousKey']) is None
        retained = store.stat('images/retained-upload/original')
        assert store.sha256('images/retained-upload/original', retained) == checksum
        print('PASS real MinIO: all 25 WebPs, hashes/MIME, missing-object detection, retry, PNG retirement, retained upload')
finally:
    # This bucket name was created above by this invocation, never deployment data.
    module.run('docker', 'exec', 'minio', 'mc', 'rb', '--force', store.root)
    module.run('docker', 'exec', 'minio', 'rm', '-f', container_fixture)
