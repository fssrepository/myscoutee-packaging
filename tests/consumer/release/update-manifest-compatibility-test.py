#!/usr/bin/env python3
"""Catalog compatibility: preserve old releases, require the new worker for seven images."""
import importlib.util
from pathlib import Path
import unittest
import json
import os
import tempfile
ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()
SOURCE = Path(__file__).resolve().parents[3]
POLICY = SOURCE / 'tests/fixtures/update-compatibility.json'
spec = importlib.util.spec_from_file_location('sign_update', SOURCE / 'release/signing/sign-update-manifest.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)

class Compatibility(unittest.TestCase):
    def check(self, version, minimum, maximum):
        signing.validate_compatibility(dict(release_version=version, minimum_compatible_version=minimum, maximum_compatible_version=maximum), POLICY)
    def test_old_release_unchanged(self):
        self.check('1.0.2', '1.0.0', '1.0.1')
    def test_old_worker_cannot_be_advertised_for_mcp_release(self):
        for version in ['1.3.0-qa.1', '1.3.0', '1.3.1']:
            with self.assertRaisesRegex(ValueError, 'signed client installer'):
                self.check(version, '1.0.2', '1.3.0')
    def test_new_worker_can_update(self):
        self.check('1.3.0', '1.3.0-qa.1', '1.3.0')
        self.check('1.3.1', '1.3.0', '1.3.0')
    def test_malformed_and_inverted_ranges_fail(self):
        for minimum, maximum in [('1.3', '1.3.0'), ('1.3.1','1.3.0'), ('01.3.0','1.3.0')]:
            with self.assertRaises(ValueError): self.check('1.3.1',minimum,maximum)
    def test_independent_project_uses_its_own_history(self):
        with tempfile.TemporaryDirectory() as directory:
            policy = Path(directory) / 'policy.json'
            policy.write_text(json.dumps({'schemaVersion': 1, 'requirements': []}))
            signing.validate_compatibility(dict(release_version='1.3.0',
                minimum_compatible_version='1.0.0', maximum_compatible_version='1.2.0'), policy)
    def test_missing_policy_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(FileNotFoundError):
                signing.validate_compatibility(dict(release_version='1.0.1',
                    minimum_compatible_version='1.0.0', maximum_compatible_version='1.0.0'),
                    Path(directory) / 'missing.json')
    def test_invalid_policy_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            policy = Path(directory) / 'policy.json'
            for value in [{}, {'schemaVersion': True, 'requirements': []},
                          {'schemaVersion': 1, 'requirements': [{}]},
                          {'schemaVersion': 1, 'requirements': [{'releaseAtLeast': '1.3', 'installedAtLeast': '1.0.0', 'reason': 'Invalid'}]}]:
                policy.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    signing.validate_compatibility(dict(release_version='1.0.1',
                        minimum_compatible_version='1.0.0', maximum_compatible_version='1.0.0'), policy)
if __name__ == '__main__': unittest.main()
