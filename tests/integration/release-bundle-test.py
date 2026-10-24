#!/usr/bin/env python3
"""Real signatures over disposable packages; never use deployment keys or hosts."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT', Path.cwd())).resolve()
SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_bundle', SOURCE / 'release/signing/prepare-release.py')
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class ReleaseBundle(unittest.TestCase):
    def test_native_and_minimal_project_complete_catalog(self):
        for project in ('myscoutee', 'sample-template'):
            with self.subTest(project=project), tempfile.TemporaryDirectory() as directory:
                work = Path(directory)
                source = work / 'source'
                for relative in ('config/packaging/release/update-compatibility-policy.json',
                                 'config/packaging/release-project.json'):
                    target = source / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    origin = ROOT / relative
                    if relative == 'config/packaging/release-project.json' and (ROOT / 'config/packaging/release-project.json').exists():
                        origin = ROOT / 'config/packaging/release-project.json'
                    shutil.copyfile(origin, target)
                    target.chmod(0o644)
                dependency = 'config/packaging/node_modules/@fssrepository/myscoutee-packaging'
                shutil.copytree(ROOT / dependency, source / dependency)
                shutil.copyfile(ROOT / 'config/packaging/package.json', source / 'config/packaging/package.json')
                policy_path = source / 'config/packaging/release-project.json'
                policy = json.loads(policy_path.read_text())
                policy['packageName'] = project
                if project != 'myscoutee':
                    policy['images'] = [row for row in policy['images']
                                        if row['service'] not in ('registry-demo', 'payment-simulator')]
                    for row in policy['images']:
                        row['repository'] = row['repository'].replace('myscoutee-', project + '-')
                        row['sinceVersion'] = '1.0.0'
                policy_path.write_text(json.dumps(policy))
                output = work / 'release'
                output.mkdir()
                package = work / 'package'
                (package / 'DEBIAN').mkdir(parents=True)
                (package / 'DEBIAN/control').write_text(
                    f'Package: {project}\nVersion: 1.0.0\nArchitecture: amd64\n'
                    'Maintainer: Test <test@example.invalid>\nDescription: Signing fixture\n')
                marker = package / f'opt/{project}/packaging/VERSION'
                marker.parent.mkdir(parents=True)
                marker.write_text('1.0.0\n')
                deb = output / f'{project}_1.0.0_amd64.deb'
                subprocess.run(['dpkg-deb', '--root-owner-group', '--build', package, deb],
                               check=True, stdout=subprocess.DEVNULL)
                client = work / 'client'
                client.mkdir()
                for name in ('README.md', 'install.env.example', 'install.sh', 'purge.sh',
                             'forward-localhost.sh', 'remote-transport.sh', 'verify-deployment/run.mjs'):
                    target = client / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text('fixture\n')
                for name in ('release-project.sh', 'release-project.json'):
                    origin = source / ('config/packaging/release-project.json' if name.endswith('.json') else dependency + '/release/lib/release-project.sh')
                    shutil.copyfile(origin, client / name)
                for name in ('verify-release.sh', 'client-project.sh'):
                    shutil.copyfile(source / dependency / 'client-tools' / name, client / name)
                (client / 'VERSION').write_text('1.0.0\n')
                archive = output / f'{project}-client-tools_1.0.0.tar.gz'
                with tarfile.open(archive, 'w:gz') as stream:
                    stream.add(client, arcname='.')
                key = work / 'test-private.pem'
                subprocess.run(['openssl', 'genpkey', '-algorithm', 'Ed25519', '-out', key], check=True)
                key.chmod(0o600)
                args = (deb, archive, key, 'v1.0.0', '1.0.0', '1.0.0', 'example/' + project, 'stable', source)
                record = bundle.prepare_release(*args)
                self.assertTrue(record['artifactSignaturesVerified'])
                self.assertTrue(record['updateManifestSignatureVerified'])
                self.assertIn('myscoutee-update.json', record['upload'])
                self.assertTrue(all((output / name).is_file() for name in record['upload']))
                self.assertFalse(any('private' in name for name in record['upload']))
                envelope = json.loads((output / 'myscoutee-update.json').read_text())
                catalog = json.loads(base64.b64decode(envelope['manifestBase64'], validate=True))
                self.assertEqual(catalog['artifact_sha256'], 'sha256:' + hashlib.sha256(deb.read_bytes()).hexdigest())
                self.assertEqual(catalog['artifact_size_bytes'], deb.stat().st_size)
                self.assertEqual(catalog['artifact_url'], f'https://github.com/example/{project}/releases/download/v1.0.0/{deb.name}')
                self.assertFalse(catalog['backup_required'])
                before = {name: (output / name).read_bytes() for name in record['upload']}
                with self.assertRaisesRegex(ValueError, 'already exists'):
                    bundle.prepare_release(*args)
                self.assertEqual(before, {name: (output / name).read_bytes() for name in record['upload']})
                with self.assertRaisesRegex(ValueError, 'Tag/channel'):
                    bundle.prepare_release(deb, archive, key, 'v1.0.1', *args[4:])
                message, signature = work / 'message', work / 'signature'
                message.write_bytes(b'myscoutee-update-catalog-v1\n' + base64.b64decode(envelope['manifestBase64']) + b' ')
                signature.write_bytes(base64.b64decode(envelope['signature']))
                check = subprocess.run(['openssl', 'pkeyutl', '-verify', '-pubin', '-inkey', output / 'release-public.pem', '-rawin', '-in', message, '-sigfile', signature], capture_output=True)
                self.assertNotEqual(check.returncode, 0, 'Modified catalog bytes must fail signature verification')



if __name__ == '__main__':
    unittest.main()
