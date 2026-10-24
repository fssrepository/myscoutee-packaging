#!/usr/bin/env python3
"""Disposable artifact tests; no Docker, deployment, network or retained keys."""
import base64
import hashlib
import io
import json
import os
import shutil
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2]
ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()
os.environ.setdefault("MYSCOUTEE_PACKAGING_PROJECT_ROOT", str(ROOT))


def call(*args, success=True):
    result = subprocess.run(list(map(str, args)), text=True, capture_output=True)
    if success and result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    if not success and not result.returncode:
        raise AssertionError('Expected rejection')
    return result


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tar_add(archive, name, content):
    data = content if isinstance(content, bytes) else json.dumps(content).encode()
    member = tarfile.TarInfo(name)
    member.size = len(data)
    archive.addfile(member, io.BytesIO(data))


class QaReleaseTest(unittest.TestCase):
    def test_reversion_signatures_and_rejections(self):
        global ROOT
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            original_root = ROOT
            self.addCleanup(globals().__setitem__, 'ROOT', original_root)
            ROOT = work / 'source'
            config = ROOT / 'config/packaging'
            (config / 'release').mkdir(parents=True)
            for relative in ['release-project.json', 'package.json', 'release/qa.json']:
                shutil.copyfile(original_root / 'config/packaging' / relative, config / relative)
                (config / relative).chmod(0o644)
            shutil.copyfile(SOURCE / 'tests/fixtures/update-compatibility.json',
                            config / 'release/update-compatibility-policy.json')
            shutil.copytree(original_root / 'config/packaging/node_modules/@fssrepository/myscoutee-packaging',
                            config / 'node_modules/@fssrepository/myscoutee-packaging')
            environment = patch.dict(os.environ, {'MYSCOUTEE_PACKAGING_PROJECT_ROOT': str(ROOT)})
            environment.start()
            self.addCleanup(environment.stop)
            package = work / 'package'
            packaging = package / 'opt/myscoutee/packaging'
            (package / 'DEBIAN').mkdir(parents=True)
            (packaging / 'templates').mkdir(parents=True)
            (package / 'DEBIAN/control').write_text('Package: myscoutee\nVersion: 1.0.0\nArchitecture: amd64\nMaintainer: QA <qa@example.invalid>\nDescription: QA fixture\n')
            (packaging / 'VERSION').write_text('1.0.0\n')
            (packaging / 'scripts').mkdir()
            guard = b"#!/bin/sh\nprintf '%s' x | grep -Eq '^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$'\n"
            (packaging / 'scripts/qualify-deployment.sh').write_bytes(guard)
            (packaging / 'scripts/start-production.sh').write_bytes(guard)
            (package / 'DEBIAN/postinst').write_bytes(guard)
            (package / 'DEBIAN/postinst').chmod(0o755)
            images = package / 'opt/myscoutee/images'
            images.mkdir()
            config = b'{"architecture":"amd64","rootfs":{"type":"layers","diff_ids":[]}}'
            image_id = hashlib.sha256(config).hexdigest()
            reference = 'myscoutee-api:1.0.0-prod'
            with tarfile.open(images / 'myscoutee-api-1.0.0-prod.tar', 'w') as tar:
                tar_add(tar, 'manifest.json', [{'Config': 'blobs/sha256/' + image_id, 'RepoTags': [reference], 'Layers': []}])
                tar_add(tar, 'index.json', {'manifests': [{'annotations': {'io.containerd.image.name': 'docker.io/library/' + reference, 'org.opencontainers.image.ref.name': '1.0.0-prod'}}]})
                tar_add(tar, 'repositories', {'myscoutee-api': {'1.0.0-prod': image_id}})
                tar_add(tar, 'blobs/sha256/' + image_id, config)
            (packaging / 'templates/myscoutee.env').write_text('MYSCOUTEE_VERSION=1.0.0\nMYSCOUTEE_PRODUCTION_IMAGE=' + reference + '\n')
            (packaging / 'IMAGE-MANIFEST.json').write_text(json.dumps({'releaseVersion': '1.0.0', 'bundled': True, 'images': [{'reference': reference, 'imageId': 'sha256:' + image_id}]}))
            deb = work / 'myscoutee_1.0.0_amd64.deb'
            call('dpkg-deb', '--root-owner-group', '--build', package, deb)
            client = work / 'myscoutee-client-tools_1.0.0.tar.gz'
            with tarfile.open(client, 'w:gz') as tar:
                for name in ('README.md', 'install.env.example', 'install.sh', 'purge.sh', 'forward-localhost.sh', 'remote-transport.sh', 'verify-deployment/run.mjs'):
                    tar_add(tar, './' + name, guard if name == 'install.sh' else b'fixture\n')
                tar_add(tar, './VERSION', b'1.0.0\n')
                tar_add(tar, './verify-release.sh', (ROOT / 'config/packaging/node_modules/@fssrepository/myscoutee-packaging/client-tools/verify-release.sh').read_bytes())
                tar_add(tar, './release-project.sh', (ROOT / 'config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/lib/release-project.sh').read_bytes())
                tar_add(tar, './release-project.json', (ROOT / 'config/packaging/release-project.json').read_bytes())
            before = [sha(deb), sha(client)]
            output = work / 'qa'
            command = ['python3', SOURCE / 'release/qa/reversion-qa-artifacts.py', '--deb', deb, '--deb-sha256', before[0], '--client-tools', client, '--client-tools-sha256', before[1], '--version', '1.0.0-qa.1', '--output-dir', output]
            bad = command.copy()
            bad[bad.index('--deb-sha256') + 1] = '0' * 64
            call(*bad, success=False)
            self.assertFalse(output.exists())
            call(*command)
            call(*command, success=False)
            new_deb = output / 'myscoutee_1.0.0-qa.1_amd64.deb'
            self.assertEqual(call('dpkg-deb', '-f', new_deb, 'Version').stdout.strip(), '1.0.0~qa.1')
            extracted = work / 'extracted'
            call('dpkg-deb', '-x', new_deb, extracted)
            new_packaging = extracted / 'opt/myscoutee/packaging'
            self.assertEqual((new_packaging / 'VERSION').read_text(), '1.0.0-qa.1\n')
            self.assertIn('myscoutee-api:1.0.0-qa.1-prod', (new_packaging / 'templates/myscoutee.env').read_text())
            with tarfile.open(extracted / 'opt/myscoutee/images/myscoutee-api-1.0.0-qa.1-prod.tar') as tar:
                self.assertEqual(tar.extractfile('blobs/sha256/' + image_id).read(), config)
                self.assertEqual(json.load(tar.extractfile('manifest.json'))[0]['RepoTags'], ['myscoutee-api:1.0.0-qa.1-prod'])
                self.assertEqual(json.load(tar.extractfile('index.json'))['manifests'][0]['annotations']['org.opencontainers.image.ref.name'], '1.0.0-qa.1-prod')
            self.assertEqual([sha(deb), sha(client)], before)
            call('dpkg', '--compare-versions', '1.0.0~qa.1', 'lt', '1.0.0~qa.2')
            call('dpkg', '--compare-versions', '1.0.0~qa.2', 'lt', '1.0.0')
            signing = ['python3', SOURCE / 'release/qa/sign-qa-release.py', '--deb', new_deb, '--client-tools', output / 'myscoutee-client-tools_1.0.0-qa.1.tar.gz', '--tag', 'v1.0.0-qa.1', '--minimum-version', '1.0.0-qa.1', '--maximum-version', '1.0.0-qa.1', '--key-directory', work / 'keys', '--create-qa-key']
            call(*signing)
            call(*signing, success=False)
            record = json.loads((output / 'QA-RELEASE.json').read_text())
            self.assertTrue(record['artifactSignaturesVerified'])
            self.assertTrue(record['updateManifestSignatureVerified'])
            envelope = json.loads((output / 'myscoutee-update.json').read_text())
            metadata = json.loads(base64.b64decode(envelope['manifestBase64']))
            self.assertIs(metadata['backup_required'], False)
            metadata['backup_required'] = True
            rejected_source = work / 'backup-required.json'
            rejected_source.write_text(json.dumps(metadata))
            call('python3', Path(os.environ.get('MYSCOUTEE_PACKAGING_SOURCE', ROOT.parent / 'myscoutee-packaging')) / 'release/signing/sign-update-manifest.py',
                 '--compatibility-policy', ROOT / 'config/packaging/release/update-compatibility-policy.json',
                 '--private-key', work / 'keys/qa-release-private.pem',
                 '--manifest', rejected_source, '--output', work / 'rejected.json', success=False)
            self.assertFalse((work / 'rejected.json').exists())
            self.assertFalse(any('private' in path.name for path in output.iterdir()))
            with new_deb.open('ab') as stream:
                stream.write(b'tamper')
            call('bash', ROOT / 'config/packaging/node_modules/@fssrepository/myscoutee-packaging/client-tools/verify-release.sh', new_deb, output / 'myscoutee-release_1.0.0-qa.1.json', output / 'qa-release-public.pem', record['trustedPublicKeySpkiSha256'], success=False)


if __name__ == '__main__':
    unittest.main()
