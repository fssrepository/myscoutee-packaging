#!/usr/bin/env python3
"""Reversion downloaded QA artifacts without rebuilding their application images.

Requires independently checked input hashes. Writes a new directory and never
uploads, installs, executes package scripts, or edits the source artifacts.
"""
import argparse
import os
import copy
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()
PACKAGE = Path(__file__).resolve().parents[2]
QA_VERSION = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-qa\.(0|[1-9][0-9]*)')


def stream_digest(stream, algorithm='sha256'):
    result = hashlib.new(algorithm)
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        result.update(chunk)
    return result


def digest(path):
    with path.open('rb') as stream:
        return stream_digest(stream).hexdigest()


def run(*args):
    return subprocess.check_output(list(map(str, args)), text=True).strip()


def json_bytes(value):
    return (json.dumps(value, indent=2) + '\n').encode()


def allow_qa_version(raw, debian=True):
    """Narrow compatibility edit for the original installer/qualifier guard."""
    text = raw.decode()
    core = r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
    if text.count(core) != 1:
        raise ValueError('Expected exactly one original Debian version guard')
    suffix = r'(~qa\.(0|[1-9][0-9]*))?$' if debian else r'(-qa\.(0|[1-9][0-9]*))?$'
    return text.replace(core, core[:-1] + suffix).replace(
        'plain SemVer core', 'SemVer core or <core>' + ('~' if debian else '-') + 'qa.<number>').encode()


def rewrite_archive(source, target, replacements):
    """Copy archive entries, changing only explicitly named metadata entries."""
    remaining = set(replacements)
    with tarfile.open(source, 'r:*') as src, tarfile.open(target, 'w:gz' if str(target).endswith('.gz') else 'w') as dst:
        for member in src:
            if member.name in replacements:
                if member.name not in remaining or not member.isfile():
                    raise ValueError(f'Duplicate or non-regular metadata: {member.name}')
                remaining.remove(member.name)
                data = replacements[member.name](src.extractfile(member).read())
                member = copy.copy(member)
                member.size = len(data)
                dst.addfile(member, io.BytesIO(data))
            else:
                dst.addfile(member, src.extractfile(member) if member.isfile() else None)
    if remaining:
        raise ValueError(f'Missing metadata: {sorted(remaining)}')


def retag_image(source, target, old_reference, new_reference, expected_image_id):
    with tarfile.open(source) as archive:
        manifest = json.load(archive.extractfile('manifest.json'))
        if len(manifest) != 1 or manifest[0]['RepoTags'] != [old_reference]:
            raise ValueError(f'Unexpected image references in {source.name}')
        config = archive.extractfile(manifest[0]['Config']).read()
        if 'sha256:' + hashlib.sha256(config).hexdigest() != expected_image_id:
            raise ValueError('Image config does not match the retained image ID')
        names = set(archive.getnames())
    old_tag, new_tag = old_reference.split(':')[1], new_reference.split(':')[1]

    def docker_manifest(raw):
        value = json.loads(raw)
        value[0]['RepoTags'] = [new_reference]
        return json_bytes(value)

    def oci_index(raw):
        value = json.loads(raw)
        for item in value['manifests']:
            annotations = item.get('annotations', {})
            for key, text in list(annotations.items()):
                if text == old_tag:
                    annotations[key] = new_tag
                elif text == old_reference or text == 'docker.io/library/' + old_reference:
                    annotations[key] = text.replace(old_reference, new_reference)
        return json_bytes(value)

    def repositories(raw):
        value = json.loads(raw)
        repository = old_reference.split(':')[0]
        value[repository][new_tag] = value[repository].pop(old_tag)
        return json_bytes(value)

    changes = {'manifest.json': docker_manifest}
    if 'index.json' in names:
        changes['index.json'] = oci_index
    if 'repositories' in names:
        changes['repositories'] = repositories
    rewrite_archive(source, target, changes)
    # Verify every retained layer/config/blob byte, not just the declared image ID.
    with tarfile.open(source) as src, tarfile.open(target) as dst:
        if src.getnames() != dst.getnames():
            raise ValueError('Image archive members changed unexpectedly')
        for item in src:
            if item.isfile() and item.name not in changes:
                before = stream_digest(src.extractfile(item)).digest()
                after = stream_digest(dst.extractfile(item.name)).digest()
                if before != after:
                    raise ValueError(f'Image content changed: {item.name}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deb', type=Path, required=True)
    parser.add_argument('--deb-sha256', required=True)
    parser.add_argument('--client-tools', type=Path, required=True)
    parser.add_argument('--client-tools-sha256', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    PRODUCT = json.loads((ROOT / 'config/packaging/release-project.json').read_text())['packageName']
    if not QA_VERSION.fullmatch(args.version):
        parser.error('Expected <core>-qa.<number>, for example 1.0.0-qa.1')
    for path, expected in [(args.deb, args.deb_sha256), (args.client_tools, args.client_tools_sha256)]:
        if path.is_symlink() or not path.is_file() or digest(path) != expected:
            parser.error(f'Input is not a regular file matching the expected SHA-256: {path}')
    if args.output_dir.exists():
        parser.error('Output directory already exists; source/release replacement is forbidden')
    version = run('dpkg-deb', '-f', args.deb, 'Version')
    architecture = run('dpkg-deb', '-f', args.deb, 'Architecture')
    if run('dpkg-deb', '-f', args.deb, 'Package') != PRODUCT or args.version.split('-')[0] != version:
        parser.error('Expected an original myscoutee package with the matching stable core version')
    args.output_dir.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.qa-reversion-', dir=args.output_dir.parent) as temp:
        work = Path(temp)
        package = work / 'package'
        output = work / 'output'
        output.mkdir()
        run('dpkg-deb', '--raw-extract', args.deb, package)
        packaging = package / 'opt' / PRODUCT / 'packaging'
        manifest_path = packaging / 'IMAGE-MANIFEST.json'
        manifest = json.loads(manifest_path.read_text())
        if manifest['releaseVersion'] != version or not manifest['bundled']:
            raise ValueError('Original image manifest does not match the package')
        retained_images = copy.deepcopy(manifest['images'])
        environment = packaging / ('templates/' + PRODUCT + '.env')
        env = environment.read_text()
        for entry in manifest['images']:
            old = entry['reference']
            if f':{version}-' not in old:
                raise ValueError(f'Unexpected bundled image reference: {old}')
            new = old.replace(f':{version}-', f':{args.version}-')
            images = package / 'opt' / PRODUCT / 'images'
            source = images / (old.replace(':', '-') + '.tar')
            target = images / (new.replace(':', '-') + '.tar')
            retag_image(source, target, old, new, entry['imageId'])
            source.unlink()
            entry['reference'] = new
            env = env.replace(old, new)
        env = env.replace(f'MYSCOUTEE_VERSION={version}\n', f'MYSCOUTEE_VERSION={args.version}\n')
        environment.write_text(env)
        manifest['releaseVersion'] = args.version
        manifest_path.write_bytes(json_bytes(manifest))
        (packaging / 'VERSION').write_text(args.version + '\n')
        qualifier = packaging / 'scripts/qualify-deployment.sh'
        qualifier.write_bytes(allow_qa_version(qualifier.read_bytes()))
        for script in (package / 'DEBIAN/postinst', packaging / 'scripts/start-production.sh'):
            script.write_bytes(allow_qa_version(script.read_bytes(), debian=False))
        control = package / 'DEBIAN/control'
        control.write_text(re.sub(r'^Version: .*$', 'Version: ' + args.version.replace('-', '~'), control.read_text(), flags=re.M))
        md5sums = package / 'DEBIAN/md5sums'
        if md5sums.exists():
            lines = []
            for path in sorted(package.rglob('*')):
                relative = path.relative_to(package)
                if relative.parts[0] != 'DEBIAN' and path.is_file() and not path.is_symlink():
                    with path.open('rb') as stream:
                        lines.append(stream_digest(stream, 'md5').hexdigest() + '  ' + str(relative))
            md5sums.write_text('\n'.join(lines) + '\n')
        deb = output / f'{PRODUCT}_{args.version}_{architecture}.deb'
        run('dpkg-deb', '--root-owner-group', '-Zgzip', '--build', package, deb)
        with tarfile.open(args.client_tools) as archive:
            if archive.extractfile('./VERSION').read().decode().strip() != version:
                raise ValueError('Original client-tools version mismatch')
        client_tools = output / f'{PRODUCT}-client-tools_{args.version}.tar.gz'
        rewrite_archive(args.client_tools, client_tools, {
            './VERSION': lambda _: (args.version + '\n').encode(),
            './verify-release.sh': lambda _: (PACKAGE / 'client-tools/verify-release.sh').read_bytes(),
            './install.sh': allow_qa_version,
        })
        record = {'version': args.version, 'debianVersion': args.version.replace('-', '~'),
                  'originalDebSha256': args.deb_sha256, 'originalClientToolsSha256': args.client_tools_sha256,
                  'imagesBefore': retained_images, 'imagesAfter': manifest['images'],
                  'imagePayloadBytesPreserved': True,
                  'applicationCodeChanged': False,
                  'packageScriptChange': 'QA version guards in postinst, start-production.sh and qualify-deployment.sh',
                  'clientToolsChange': 'VERSION, prerelease-aware verify-release.sh and install.sh version guard',
                  'artifacts': {p.name: digest(p) for p in (deb, client_tools)}}
        (output / 'REVERSION.json').write_bytes(json_bytes(record))
        output.rename(args.output_dir)
    print(args.output_dir)


if __name__ == '__main__':
    main()
