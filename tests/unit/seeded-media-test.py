#!/usr/bin/env python3
"""Exercise guarded object preparation/retirement without touching a real bucket."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('media_migration', ROOT / 'runtime/data/migrate-seeded-media.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Store:
    def __init__(self, objects):
        self.objects = copy.deepcopy(objects)
        self.writes = []

    def stat(self, key):
        return {'metadata': {'Content-Type': self.objects[key][1]}} if key in self.objects else None

    def sha256(self, key, _metadata):
        return hashlib.sha256(self.objects[key][0]).hexdigest()

    def put(self, path, key):
        self.writes.append(('put', key))
        self.objects[key] = (path.read_bytes(), 'image/webp')

    def remove(self, key):
        self.writes.append(('remove', key))
        del self.objects[key]


class SeededMedia(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.old = b'known PNG'
        self.new = b'RIFF0000WEBPknown replacement'
        self.row = {'previousKey': 'images/system/room.png', 'key': 'images/system/room.webp',
                    'previousSha256': hashlib.sha256(self.old).hexdigest(),
                    'sha256': hashlib.sha256(self.new).hexdigest()}
        self.manifest = self.root / 'manifest.json'
        self.write_manifest([self.row])
        self.source = self.root / self.row['key']
        self.source.parent.mkdir(parents=True)
        self.source.write_bytes(self.new)
        self.store = Store({self.row['previousKey']: (self.old, 'image/png'),
                            'images/owner/upload/original': (b'user original', 'image/jpeg')})

    def write_manifest(self, rows):
        self.manifest.write_text(json.dumps({'schemaVersion': 1, 'minio': rows}))

    def migrate(self, phase):
        module.migrate(phase, self.manifest, self.root, self.store)

    def test_prepare_then_retire_retry_preserves_user_original(self):
        self.migrate('prepare')
        self.assertIn(self.row['previousKey'], self.store.objects)
        self.migrate('prepare')
        self.migrate('retire')
        self.migrate('retire')
        self.assertEqual(self.store.writes, [('put', self.row['key']), ('remove', self.row['previousKey'])])
        self.assertEqual(self.store.objects['images/owner/upload/original'][0], b'user original')

    def test_wrong_mime_on_exact_replacement_is_repaired(self):
        self.store.objects[self.row['key']] = (self.new, 'application/octet-stream')
        self.migrate('prepare')
        self.assertEqual(self.store.objects[self.row['key']][1], 'image/webp')

    def test_customized_old_or_replacement_fails_before_writes(self):
        for key in ['previousKey', 'key']:
            with self.subTest(key=key):
                self.store.objects[self.row[key]] = (b'custom', 'image/webp')
                with self.assertRaises(RuntimeError):
                    self.migrate('prepare')
                self.assertEqual(self.store.writes, [])
                self.store.objects.pop(self.row[key])

    def test_retirement_requires_verified_replacement(self):
        with self.assertRaises(RuntimeError):
            self.migrate('retire')
        self.assertEqual(self.store.writes, [])

    def test_customized_old_after_prepare_is_retained(self):
        self.migrate('prepare')
        self.store.objects[self.row['previousKey']] = (b'new custom image', 'image/png')
        self.migrate('retire')
        self.assertIn(self.row['previousKey'], self.store.objects)

    def test_new_article_variant_needs_no_previous_minio_object(self):
        self.write_manifest([{key: value for key, value in self.row.items() if not key.startswith('previous')}])
        self.migrate('prepare')
        self.migrate('retire')
        self.assertIn(self.row['previousKey'], self.store.objects)

    def test_all_inputs_validated_before_any_object_write(self):
        self.write_manifest([self.row, {**self.row, 'key': 'images/system/missing.webp'}])
        with self.assertRaises(FileNotFoundError):
            self.migrate('prepare')
        self.assertEqual(self.store.writes, [])

    def test_checksum_and_unsafe_path_rejected_without_store(self):
        for change in [{'key': 'images/system/../upload.webp'}, {'sha256': '0' * 64}]:
            self.write_manifest([{**self.row, **change}])
            with self.assertRaises(ValueError):
                module.migrate('check-inputs', self.manifest, self.root)

    def test_absence_is_distinct_from_transport_and_authentication_failure(self):
        self.assertTrue(module.missing_object({'error': {'cause': {'message': 'Object does not exist', 'error': {}}}}))
        self.assertTrue(module.missing_object({'error': {'code': 'NoSuchKey'}}))
        self.assertFalse(module.missing_object({'error': {'code': 'AccessDenied'}}))
        self.assertFalse(module.missing_object({'error': {'message': 'connection refused'}}))


if __name__ == '__main__':
    unittest.main()
