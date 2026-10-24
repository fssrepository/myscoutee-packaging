#!/usr/bin/env python3
"""Assemble the existing flat host-tool payload from categorized source files."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile

PACKAGE = Path(__file__).resolve().parents[2]


def selected_sources(project):
    project = Path(project).resolve()
    selection = json.loads((project / 'config/packaging/runtime-inputs.json').read_text())
    common = json.loads((PACKAGE / 'runtime/sources.json').read_text())['files']
    names = selection['files']
    overrides = selection['projectSources']
    package_overrides = selection.get('packageSources', {})
    if (selection['schemaVersion'] != 1 or not isinstance(names, list)
            or len(names) != len(set(names)) or not isinstance(overrides, dict)
            or not isinstance(package_overrides, dict)
            or not set(overrides).issubset(names)
            or not set(package_overrides).issubset(names)
            or set(overrides).intersection(package_overrides)):
        raise ValueError('Invalid runtime input selection')
    result = {}
    for name in sorted(names):
        if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.-]*', name):
            raise ValueError('Invalid runtime filename')
        owner = project if name in overrides else PACKAGE
        relative = Path(overrides[name] if name in overrides else
                        package_overrides[name] if name in package_overrides else common[name])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Invalid runtime source path')
        source = owner / relative
        if source.is_symlink() or not source.resolve().is_relative_to(owner) or not source.is_file():
            raise ValueError(f'Unsafe or missing runtime input: {name}')
        result[name] = source
    return result


def stage(project, destination):
    sources = selected_sources(project)
    destination = Path(destination)
    if destination.is_symlink():
        raise ValueError('Runtime output directory must not be a symbolic link')
    destination.mkdir(parents=True, exist_ok=True)
    policy_owner = (Path(project) / 'config/packaging/release-project.json').stat()
    for name, source in sources.items():
        target = destination / name
        mode = 0o755 if target.suffix in ('.sh', '.py') else 0o644
        content = source.read_bytes()
        if target.is_symlink():
            raise ValueError('Runtime output must not be a symbolic link')
        if target.is_file() and target.read_bytes() == content and target.stat().st_mode & 0o777 == mode:
            continue
        with tempfile.NamedTemporaryFile(dir=destination, prefix='.' + name + '.', delete=False) as temporary:
            temporary.write(content)
            path = Path(temporary.name)
        try:
            path.chmod(mode)
            if os.geteuid() == 0:
                os.chown(path, policy_owner.st_uid, policy_owner.st_gid)
            os.replace(path, target)
        finally:
            path.unlink(missing_ok=True)
    return sources


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('project', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    try:
        stage(args.project, args.destination)
    except (ValueError, KeyError, TypeError, OSError) as error:
        sys.exit(f'Cannot stage runtime inputs: {error}')
