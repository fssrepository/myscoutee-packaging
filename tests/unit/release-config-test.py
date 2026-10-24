#!/usr/bin/env python3
"""Exercise configured release inputs without building or running applications."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('social_filters', ROOT / 'release/audit/render-social-filters.py')
filters = importlib.util.module_from_spec(spec)
spec.loader.exec_module(filters)
DEFAULTS = json.loads((ROOT / 'release/lib/defaults.json').read_text())


class ReleaseConfiguration(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.config = self.root / 'config/packaging/release'
        self.config.mkdir(parents=True)

    def test_overrides_keep_shared_defaults_and_existing_debian_image_owner(self):
        (self.config / 'settings.json').write_text(json.dumps({
            'schemaVersion': 1, 'build': {'frontendScript': 'build:custom'}}))
        debian = self.root / 'config/packaging/debian'
        debian.mkdir()
        (debian / 'lifecycle.json').write_text(json.dumps({'schemaVersion': 1,
            'requiredImages': [{'environment': 'MONGO_IMAGE', 'default': 'registry.invalid/mongo:fixture', 'label': 'MongoDB'}]}))
        output = subprocess.check_output(['bash', '-c',
            'source "$1"; release_config_load "$2"; release_config_value .build.frontendScript; '
            'release_config_value .build.nginxNativeImage; release_official_image MONGO_IMAGE',
            '_', str(ROOT / 'release/lib/release-config.sh'), str(self.root)], text=True)
        self.assertEqual(output.splitlines(), ['build:custom', DEFAULTS['build']['nginxNativeImage'], 'registry.invalid/mongo:fixture'])

    def test_malformed_settings_fail(self):
        (self.config / 'settings.json').write_text('{"schemaVersion": 2}')
        result = subprocess.run(['bash', '-c', 'source "$1"; release_config_load "$2"',
            '_', str(ROOT / 'release/lib/release-config.sh'), str(self.root)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_default_social_exceptions_retain_text_and_exact_seed_matching(self):
        text, seeds = filters.render(DEFAULTS['audit'])
        for name, source in [('text', text), ('seeds', seeds)]:
            (self.root / name).write_text(source)
        url = 'https://www.instagram.com/myscoutee'
        self.assertEqual(subprocess.check_output(['sed', '-f', str(self.root / 'text')], input=url.upper().encode()), b'')
        self.assertEqual(subprocess.check_output(['sed', '-f', str(self.root / 'seeds')], input=json.dumps(url).encode()), b'""')
        longer = json.dumps(url + '/custom')
        self.assertEqual(subprocess.check_output(['sed', '-f', str(self.root / 'seeds')], input=longer.encode()).decode(), longer)

    def test_custom_urls_are_literals_in_sed(self):
        url = 'https://instagram.com/profile.name?x=1+2[3]#anchor'
        text, _ = filters.render({'allowedSocialUrls': [url], 'allowedSeedSocialUrls': []})
        path = self.root / 'filter'
        path.write_text(text)
        self.assertEqual(subprocess.check_output(['sed', '-f', str(path)], input=url.encode()), b'')
        other = url.replace('profile.name', 'profileXname')
        self.assertEqual(subprocess.check_output(['sed', '-f', str(path)], input=other.encode()).decode(), other)
        with self.assertRaises(ValueError):
            filters.render({'allowedSocialUrls': ['https://example.invalid/\ninvalid'], 'allowedSeedSocialUrls': []})

    def archive_audit(self, name, body, policy=None):
        archive = self.root / 'application.jar'
        with zipfile.ZipFile(archive, 'w') as output:
            output.writestr(name, body)
        args = ['python3', str(ROOT / 'release/audit/audit-nested-archive.py'), str(archive)]
        if policy is not None:
            selected = self.root / 'settings.json'
            selected.write_text(json.dumps(policy))
            args.append(str(selected))
        return subprocess.run(args, capture_output=True).returncode

    def test_nested_archives_use_selected_exceptions_without_allowing_credentials(self):
        name = 'BOOT-INF/classes/application.json'
        custom_url = 'https://instagram.com/custom-product'
        self.assertEqual(self.archive_audit(name, custom_url), 1)
        policy = json.loads(json.dumps(DEFAULTS))
        policy['audit']['allowedSocialUrls'] = [custom_url]
        self.assertEqual(self.archive_audit(name, custom_url, policy), 0)
        self.assertEqual(self.archive_audit(name, 'https://instagram.com/another-product', policy), 1)
        self.assertEqual(self.archive_audit('BOOT-INF/classes/firebase-service-account.json', '{}', policy), 1)
        self.assertEqual(self.archive_audit('com/google/api/client/googleapis/google.p12', b'unreviewed credential', policy), 1)
        self.assertEqual(self.archive_audit(name, 'someone@gmail.com', policy), 1)


if __name__ == '__main__':
    unittest.main()
