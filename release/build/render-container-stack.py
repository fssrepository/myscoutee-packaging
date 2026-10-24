#!/usr/bin/env python3
"""Bind standalone container packaging mechanisms to public project metadata.

This source view contains rendered implementations, never forwarding scripts.
Installed paths and lifecycle behavior are supplied by the original templates.
"""
import json
import os
from pathlib import Path
import re
import tempfile

PACKAGE = Path(__file__).resolve().parents[2]


def load(project):
    config = project / 'config/packaging'
    metadata = json.loads((config / 'container-stack.json').read_text())
    if metadata.get('schemaVersion') != 1:
        raise ValueError('Invalid container-stack configuration')
    name = metadata['packageName']
    if not re.fullmatch(r'[a-z][a-z0-9-]{1,63}', name):
        raise ValueError('Invalid package name')
    if metadata['images'] != {'registry': name, 'nginx': name + '-nginx'}:
        raise ValueError('Image repositories must match the selected package identity')
    display = metadata['displayName']
    if not re.fullmatch(r'[A-Za-z0-9 ._-]{1,100}', display):
        raise ValueError('Invalid display name')
    identity = metadata['runtimeIdentity']
    if any(type(identity[k]) is not int or not 1 <= identity[k] <= 65534 for k in ['uid', 'gid']):
        raise ValueError('Invalid runtime identity')
    for value in metadata['signatureDomains'].values():
        if not re.fullmatch(r'[a-z][a-z0-9-]{1,127}', value):
            raise ValueError('Invalid signature domain')
    for key in ['verifierSource', 'documentationSource']:
        relative(metadata[key])
    return metadata


def relative(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_.\-/]+', value) or value.startswith('/') or any(part in ['', '.', '..'] for part in value.split('/')):
        raise ValueError('Invalid source path')
    return value


def stage(project):
    project = Path(project).resolve()
    meta = load(project)
    tokens = {'PACKAGE_NAME': meta['packageName'], 'DISPLAY_NAME': meta['displayName'],
              'NGINX_IMAGE': meta['images']['nginx'],
              'RUNTIME_UID': str(meta['runtimeIdentity']['uid']), 'RUNTIME_GID': str(meta['runtimeIdentity']['gid']),
              'PACKAGE_DOMAIN': meta['signatureDomains']['package'], 'CLIENT_DOMAIN': meta['signatureDomains']['clientTools'],
              'VERIFIER_SOURCE': meta['verifierSource'], 'DOCUMENTATION_SOURCE': meta['documentationSource']}
    inputs = {
        'scripts/package-production.sh': PACKAGE / 'release/build/package-container-stack.sh',
        'scripts/build-production.sh': PACKAGE / 'release/build/build-container-stack.sh',
        'scripts/image-content-fingerprint.sh': PACKAGE / 'release/lib/image-content-fingerprint.sh',
        'debian/control': project / 'config/packaging/debian/control',
        f"systemd/{meta['packageName']}.service": PACKAGE / 'systemd/container-stack/stack.service',
    }
    for name in ['postinst', 'prerm', 'postrm']:
        inputs['debian/' + name] = PACKAGE / 'debian/container-stack' / name
    for name in ['registry-compose.sh', 'qualify-deployment.sh']:
        inputs['scripts/' + name] = PACKAGE / 'runtime/host/container-stack' / name
    for name in ['install.sh', 'purge.sh', 'verify-release.sh', 'README.md']:
        inputs['client-tools/' + name] = PACKAGE / 'client-tools/provisioned' / name
    for name in ['forward-localhost.sh', 'remote-transport.sh']:
        inputs['client-tools/' + name] = PACKAGE / 'client-tools' / name
    for name in ['install.env.example', 'deployment.env.example', 'forward.json']:
        inputs['client-tools/' + name] = project / 'config/packaging/client-tools' / name
    verifier = project / meta['verifierSource']
    for name in ['README.md', 'run.mjs', 'checks.mjs', 'lib/assertions.mjs', 'lib/http.mjs']:
        inputs['verify-deployment/' + name] = verifier / name
    selection = json.loads((project / 'config/packaging/tests/selection.json').read_text())
    for test in selection['tests'].values():
        path = relative(test['path'])
        if test['owner'] == 'package' and path.startswith('tests/consumer/'):
            inputs['packaging-tests/' + path.removeprefix('tests/consumer/')] = PACKAGE / path
    contents = {}
    for name, source in inputs.items():
        if source.is_symlink() or not source.is_file():
            raise ValueError(f'Missing/unsafe source input: {source}')
        text = source.read_text()
        for key, value in tokens.items():
            text = text.replace('@@' + key + '@@', value)
        if re.search(r'@@[A-Z_]+@@', text):
            raise ValueError(f'Unbound configuration in {source}')
        contents[name] = text
    output = project / 'build'
    for name, text in contents.items():
        target = output / name
        if target.is_symlink() or any(parent.is_symlink() for parent in target.parents if parent != project.parent):
            raise ValueError(f'Symlink output is not allowed: {target}')
        target.parent.mkdir(parents=True, exist_ok=True)
        mode = 0o755 if name.endswith('.sh') or name.startswith('debian/') and not name.endswith('/control') else 0o644
        with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(text.encode())
            os.fchmod(stream.fileno(), mode)
        temporary.replace(target)
    return contents


if __name__ == '__main__':
    import sys
    stage(sys.argv[1])
