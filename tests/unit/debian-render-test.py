#!/usr/bin/env python3
"""Compare the extracted hooks to captured original product outputs."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('debian_renderer', ROOT / 'release/build/render-debian.py')
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)
FIXTURES = json.loads((ROOT / 'tests/fixtures/debian-products.json').read_text())


class DebianControl(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.packaging = self.root / 'packaging'
        self.packaging.mkdir()
        self.config = self.root / 'config/packaging'
        (self.config / 'debian').mkdir(parents=True)
        self.select('myscoutee-backend')

    def write(self, name, value):
        (self.config / name).write_text(json.dumps(value))

    def select(self, name):
        self.product = copy.deepcopy(FIXTURES[name])
        self.write('release-project.json', self.product['release'])
        self.write('debian/control.json', self.product['control'])
        self.write('debian/purge-policy.json', self.product['purge'])

    def test_original_control_and_all_four_hooks_are_byte_identical(self):
        for product in FIXTURES:
            self.select(product)
            for hook, sha in self.product['files'].items():
                with self.subTest(product=product, hook=hook):
                    content = renderer.render(self.packaging, hook).encode()
                    self.assertEqual(hashlib.sha256(content).hexdigest(), sha)
                    if hook != 'control':
                        subprocess.run(['bash', '-n'], input=content, check=True)

    def test_product_overrides_change_only_selected_constants(self):
        original = renderer.render(self.packaging, 'postinst')
        self.write('debian/lifecycle.json', {'schemaVersion': 1, 'bootstrapTls': {'days': 30},
                   'requiredImages': [{'environment': 'CACHE_IMAGE', 'default': 'registry.example/cache:2', 'label': 'Cache'}]})
        actual = renderer.render(self.packaging, 'postinst')
        expected = original.replace('-days 3650', '-days 30').replace(
            '  ensure_docker_image "$(config_value MONGO_IMAGE mongo:8.0.4)" "MongoDB"\n'
            '  ensure_docker_image "$(config_value REDIS_IMAGE redis:8.6.1-alpine)" "Redis"',
            '  ensure_docker_image "$(config_value CACHE_IMAGE registry.example/cache:2)" "Cache"')
        self.assertEqual(actual, expected)
        self.write('debian/lifecycle.json', {'schemaVersion': 1, 'requiredImages': []})
        self.assertNotIn('  ensure_docker_image "$(config_value ', renderer.render(self.packaging, 'postinst'))

    def test_control_overrides_and_candidate_identity(self):
        self.write('debian/control.json', {**self.product['control'], 'Maintainer': 'Operator <ops@example.org>'})
        actual = renderer.render(self.packaging, 'control', '2.0.0~qa.1', 'arm64')
        self.assertIn('Package: myscoutee\nVersion: 2.0.0~qa.1\n', actual)
        self.assertIn('Architecture: arm64\nMaintainer: Operator <ops@example.org>\n', actual)

    def test_unsafe_lifecycle_configuration_is_rejected(self):
        for value in [
            {'bootstrapTls': {'subject': '/CN=$(touch /tmp/forbidden)'}},
            {'bootstrapTls': {'privateKey': '../key'}},
            {'bootstrapTls': {'certificate': 'nginx-nopass.key'}},
            {'bootstrapTls': {'days': True}},
            {'bootstrapTls': {'days': 0}},
            {'bootstrapTls': {'unknown': 'value'}},
            {'requiredImages': [{'environment': 'MONGO_IMAGE', 'default': 'mongo:8;id', 'label': 'MongoDB'}]},
            {'requiredImages': [{'environment': 'MONGO_IMAGE', 'default': 'mongo:8', 'label': '$(id)'}]},
            {'mongoDatabase': "production_db:'"},
            {'unknown': 'value'},
        ]:
            with self.subTest(value=value):
                self.write('debian/lifecycle.json', {'schemaVersion': 1, **value})
                with self.assertRaises((ValueError, TypeError)):
                    renderer.render(self.packaging, 'postinst')

    def test_purge_inventory_is_validated_and_empty_selection_is_supported(self):
        self.write('debian/purge-policy.json', {'schemaVersion': 1, 'volumes': []})
        self.assertIn("done <<'PACKAGE_VOLUME_RULES'\n\nPACKAGE_VOLUME_RULES", renderer.render(self.packaging))
        volume = self.product['purge']['volumes'][0]
        for volumes in [[volume, volume], [{**volume, 'default': '../foreign'}],
                        [{**volume, 'environment': 'VALUE;id'}], [{**volume, 'unknown': True}]]:
            with self.subTest(volumes=volumes):
                self.write('debian/purge-policy.json', {'schemaVersion': 1, 'volumes': volumes})
                with self.assertRaises(ValueError):
                    renderer.render(self.packaging)

    def test_control_field_injection_and_identity_rejected(self):
        for metadata in [{'Maintainer': 'ops\nDepends: injected'}, {'Description': 'valid\nBad-Field: value'},
                         {'Package': 'foreign'}, {'Description': ''}]:
            self.write('debian/control.json', {**self.product['control'], **metadata})
            with self.subTest(metadata=metadata), self.assertRaises(ValueError):
                renderer.render(self.packaging, 'control')
        self.write('release-project.json', {**self.product['release'], 'packageName': '../foreign'})
        with self.assertRaises(ValueError):
            renderer.render(self.packaging, 'preinst')

    def test_cli_validates_every_file_before_writing(self):
        output = self.root / 'control'
        output.mkdir()
        self.write('debian/purge-policy.json', {'schemaVersion': 1, 'volumes': 'invalid'})
        result = subprocess.run(['python3', str(ROOT / 'release/build/render-debian.py'),
                                 str(self.packaging), str(output), '--hook', 'all'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(output.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
