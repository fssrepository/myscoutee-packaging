#!/usr/bin/env python3
"""Check project-selected dev directories without changing deployed data."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile

ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()
SCRIPT = ROOT / 'server/docker/scripts/prepare_dev_runtime_directories.sh'


def prepare(root, names):
    env = {**os.environ, 'MYSCOUTEE_RUNTIME_UID': str(os.getuid()),
           'MYSCOUTEE_RUNTIME_GID': str(os.getgid()), 'MYSCOUTEE_RUNTIME_DIRECTORIES': names}
    return subprocess.run(['sh', str(SCRIPT), str(root)], env=env,
                          text=True, capture_output=True)


with tempfile.TemporaryDirectory() as directory:
    base = Path(directory)
    native_names = ['configuration', 'registry-demo-keys', 'registry-demo-state', 'release-simulator']
    for case, names in [('native', native_names), ('template', ['configuration'])]:
        target = base / case
        result = prepare(target, ' '.join(names))
        assert result.returncode == 0, result.stderr
        assert sorted(p.name for p in target.iterdir()) == sorted(names)
        for name in names:
            assert stat.S_IMODE((target / name).stat().st_mode) == 0o700
        retained = target / 'configuration/retained-key'
        retained.write_bytes(b'previous deployment value')
        retained.chmod(0o640)
        before = retained.stat()
        assert prepare(target, ' '.join(names)).returncode == 0
        assert retained.read_bytes() == b'previous deployment value'
        assert retained.stat() == before, 'Existing content metadata changed'

    # Validate every selected path before creating/chowning any directory.
    unsafe = base / 'unsafe'
    unsafe.mkdir()
    (unsafe / 'linked').symlink_to(base / 'template/configuration')
    for names in ['new linked', 'new ../outside', 'new /absolute', 'new *', ' ', '']:
        assert prepare(unsafe, names).returncode != 0, names
        assert not (unsafe / 'new').exists(), names
    (unsafe / 'file').write_text('retained')
    assert prepare(unsafe, 'new file').returncode != 0
    assert not (unsafe / 'new').exists()
    assert (unsafe / 'file').read_text() == 'retained'

print('PASS: native/template directory selection, idempotence, retained files, and fail-before-mutation path guards.')
