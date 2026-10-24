#!/usr/bin/env python3
"""Check partial-release input rejection before any privileged mutation."""
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

ROOT = (Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve() / 'packaging')


class PartialReleaseInputs(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.release = self.root / 'release'
        self.marker = self.root / 'mutation-boundary'
        server = self.root / 'server'
        server.mkdir()
        (server / 'docker-compose-prod.yml').touch()
        for directory in ['migrations', 'scripts', 'seeds/production_db', 'seeds/demo_db']:
            (self.release / directory).mkdir(parents=True)
        (self.release / 'migrations/006-release-system-defaults.js').touch()
        policy = json.loads((ROOT.parent / 'config/packaging/release/settings.json').read_text())['partialData']
        (self.release / 'partial-data.json').write_text(json.dumps(policy))
        shutil.copyfile(ROOT.parent / 'config/packaging/release-project.json', self.release / 'scripts/release-project.json')
        shutil.copyfile(ROOT.parent / 'config/packaging/release/settings.json', self.release / 'scripts/migration-settings.json')
        selection = (ROOT.parent / 'build/scripts/release-system-seeds.json').read_text()
        (self.release / 'scripts/release-system-seeds.json').write_text(selection)
        self.selected = [row['collection'] for row in json.loads(selection)]
        names = set(self.selected) | {'deploymentConfigurations', 'helpCenterRevisions',
            'helpCenterGuideFields', 'ideaPosts', 'landingSlides', 'emailTemplates', 'notificationTemplates'}
        for database in ['production_db', 'demo_db']:
            for name in names:
                (self.release / 'seeds' / database / (name + '.json')).write_text('[]')
        for name in ['campaigns', 'serviceOfferings', 'users']:
            (self.release / 'seeds/demo_db' / (name + '.json')).write_text('[]')
        self.script = self.root / 'apply.sh'
        self.script.write_text((ROOT.parent / 'config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/apply-partial-release-data.sh').read_text()
            .replace('package_root="/opt/${package_name}"', 'package_root=' + str(self.root)))
        binaries = self.root / 'bin'
        binaries.mkdir()
        # tar is the first mutation boundary. Never let the harness reach Docker.
        for name, body in [('id', 'echo 0'), ('tar', 'touch "$BOUNDARY"; exit 86'),
                           ('docker', 'if [ "$1" = inspect ]; then printf "%s" "${API_RUNNING:-true}"; exit 0; fi\ntouch "$BOUNDARY"; exit 87')]:
            path = binaries / name
            path.write_text('#!/bin/sh\n' + body + '\n')
            path.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(binaries) + ':' + os.environ['PATH'],
                    'BOUNDARY': str(self.marker)}

    def run_inputs(self):
        return subprocess.run(['bash', str(self.script), str(self.release)],
                              env=self.env, capture_output=True, text=True).returncode

    def test_complete_shared_selection_reaches_backup(self):
        self.assertEqual(self.run_inputs(), 86)
        self.assertTrue(self.marker.exists())

    def test_every_selected_seed_is_required_in_both_databases(self):
        for database in ['production_db', 'demo_db']:
            for name in self.selected:
                with self.subTest(database=database, collection=name):
                    path = self.release / 'seeds' / database / (name + '.json')
                    path.unlink()
                    self.assertEqual(self.run_inputs(), 1)
                    self.assertFalse(self.marker.exists())
                    path.write_text('[]')

    def test_missing_or_mismatched_migration_configuration_is_rejected_before_backup(self):
        path = self.release / 'scripts/migration-settings.json'
        original = path.read_bytes()
        path.unlink()
        self.assertEqual(self.run_inputs(), 1)
        self.assertFalse(self.marker.exists())
        path.write_text('{"schemaVersion":1,"partialData":{"mediaManifest":"wrong.json"}}')
        self.assertEqual(self.run_inputs(), 1)
        self.assertFalse(self.marker.exists())
        path.write_bytes(original)

    def test_selected_seed_symlink_is_rejected(self):
        path = self.release / 'seeds/demo_db/communityGroups.json'
        path.unlink()
        path.symlink_to(self.release / 'seeds/production_db/communityGroups.json')
        self.assertEqual(self.run_inputs(), 1)
        self.assertFalse(self.marker.exists())

    def test_missing_demo_user_seed_is_rejected_before_mutation(self):
        (self.release / 'seeds/demo_db/users.json').unlink()
        self.assertEqual(self.run_inputs(), 1)
        self.assertFalse(self.marker.exists())

    def add_media_inputs(self):
        relative = Path('seeds/023-seeded-image-webp/image-replacements.json')
        manifest = self.release / 'migrations' / relative
        manifest.parent.mkdir(parents=True)
        shutil.copyfile(ROOT.parent / 'config/packaging/migrations' / relative, manifest)
        shutil.copyfile(ROOT.parent / 'build/scripts/migrate-seeded-media.py', self.release / 'scripts/migrate-seeded-media.py')
        rows = json.loads(manifest.read_text())['minio']
        for row in rows:
            source = ROOT.parent / 'server/docker/conf/minio/media' / row['key']
            target = self.release / 'media' / row['key']
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        return self.release / 'media' / rows[0]['key']

    def test_complete_media_payload_reaches_backup(self):
        self.add_media_inputs()
        self.assertEqual(self.run_inputs(), 86)

    def test_media_update_requires_stopped_api_before_database_work(self):
        self.add_media_inputs()
        (self.release / 'previous-package-data.tar').touch()
        self.assertEqual(self.run_inputs(), 1)
        self.assertFalse(self.marker.exists())
        self.env['API_RUNNING'] = 'false'
        self.assertEqual(self.run_inputs(), 87)
        self.assertTrue(self.marker.exists())

    def test_missing_or_changed_webp_is_rejected_before_backup(self):
        source = self.add_media_inputs()
        source.write_bytes(b'wrong image')
        self.assertNotEqual(self.run_inputs(), 86)
        self.assertFalse(self.marker.exists())
        source.unlink()
        self.assertNotEqual(self.run_inputs(), 86)
        self.assertFalse(self.marker.exists())

    def test_symbolic_media_source_is_rejected_before_backup(self):
        source = self.add_media_inputs()
        original = source.read_bytes()
        source.unlink()
        external = self.root / 'external.webp'
        external.write_bytes(original)
        source.symlink_to(external)
        self.assertNotEqual(self.run_inputs(), 86)
        self.assertFalse(self.marker.exists())


if __name__ == '__main__':
    unittest.main()
