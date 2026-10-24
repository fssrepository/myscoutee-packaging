#!/usr/bin/env python3
"""Relabel downloaded Registry QA1 artifacts without rebuilding their images.

The historical binary still reports its original build version. The packaged
host qualifier checks that original version independently of the QA package
version. Original image IDs and every config/layer byte are preserved.
"""
import argparse
import os
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile

spec = importlib.util.spec_from_file_location('qa', Path(__file__).with_name('reversion-qa-artifacts.py'))
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)


def replace(path, before, after):
    text = path.read_text()
    if before not in text:
        raise ValueError(f'Expected historical text missing in {path}')
    path.write_text(text.replace(before, after))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    a = p.parse_args()
    if a.output.exists():
        p.error('Use a new output directory; retain original downloads')
    root = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()
    product = json.loads((root / 'config/packaging/container-stack.json').read_text())['packageName']
    versions = json.loads((root / 'config/packaging/release/qa.json').read_text())
    old, new = versions['originalVersion'], versions['version']
    deb = a.source / f'{product}_{old}_amd64.deb'
    client = a.source / f'{product}-client-tools_{old}.tar.gz'
    for path in (deb, client):
        expected = Path(str(path) + '.sha256').read_text().split()[0]
        if path.is_symlink() or qa.digest(path) != expected:
            p.error('Original download does not match its retained checksum')
    if qa.run('dpkg-deb', '-f', deb, 'Package') != product or qa.run('dpkg-deb', '-f', deb, 'Version') != old:
        p.error('Expected original Registry 1.0.0 package')
    a.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=a.output.parent) as td:
        root = Path(td) / 'root'
        qa.run('dpkg-deb', '-R', deb, root)
        pkg = root / 'opt' / product / 'packaging'
        manifest = json.loads((pkg / 'IMAGE-MANIFEST.json').read_text())
        retained = json.loads(json.dumps(manifest['images']))
        for item in manifest['images']:
            source = root / 'opt' / product / item['archive']
            reference = item['reference'].replace(':'+old+'-', ':'+new+'-')
            target = source.with_name(source.name.replace(old, new))
            qa.retag_image(source, target, item['reference'], reference, item['imageId'])
            source.unlink()
            item.update(reference=reference, archive='images/'+target.name,
                        archiveSha256='sha256:'+qa.digest(target))
        manifest['releaseVersion'] = new
        (pkg / 'IMAGE-MANIFEST.json').write_text(json.dumps(manifest, indent=2)+'\n')
        (pkg / 'VERSION').write_text(new+'\n')
        (pkg / 'ORIGINAL-BINARY-VERSION').write_text(old+'\n')
        replace(root/'DEBIAN/control', 'Version: '+old, 'Version: '+new.replace('-', '~'))
        replace(pkg/'templates/registry.env', old, new)
        core = r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
        for path in (root/'DEBIAN/postinst', pkg/'scripts/qualify-deployment.sh'):
            replace(path, core, core[:-1]+r'(-qa\.[1-9][0-9]*)?$')
        qualifier = pkg/'scripts/qualify-deployment.sh'
        replace(qualifier, '"$installed_version" == "$expected_version"', '"${installed_version/\~/-}" == "$expected_version"')
        replace(qualifier, '--arg expectedVersion "$expected_version"', '--arg expectedVersion '+json.dumps(old))
        newclient = Path(td)/f'{product}-client-tools_{new}.tar.gz'
        def installer(raw):
            text = raw.decode().replace(core, core[:-1]+r'(-qa\.[1-9][0-9]*)?$')
            return text.replace('PACKAGE_VERSION="$(dpkg-deb -f "$DEB_PATH" Version)"',
                'PACKAGE_VERSION="$(dpkg-deb -f "$DEB_PATH" Version | tr "~" "-")"').encode()
        qa.rewrite_archive(client, newclient, {'./VERSION': lambda _: (new+'\n').encode(), './install.sh': installer})
        # The historical archive remains inside the package byte-for-byte identical
        # to the separately attached, relabelled client-tools archive.
        embedded = root/'usr/share'/product/client.name
        embedded.unlink()
        shutil.copy2(newclient, embedded.with_name(newclient.name))
        a.output.mkdir()
        shutil.copy2(newclient, a.output/newclient.name)
        newdeb = a.output/f'{product}_{new}_amd64.deb'
        qa.run('dpkg-deb', '--root-owner-group', '-Zgzip', '--build', root, newdeb)
        for path in (newdeb, a.output/newclient.name):
            Path(str(path)+'.sha256').write_text(qa.digest(path)+'  '+path.name+'\n')
        record = {'version': new, 'originalBinaryVersion': old,
                  'originalDebSha256': qa.digest(deb), 'originalClientToolsSha256': qa.digest(client),
                  'imagesUnchanged': True, 'originalImages': retained,
                  'packageSha256': qa.digest(newdeb)}
        (a.output/'REVERSION.json').write_text(json.dumps(record, indent=2)+'\n')
        print(json.dumps(record))


if __name__ == '__main__':
    main()
