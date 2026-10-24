#!/usr/bin/env python3
"""Inspect the actual template DEB without installing it or starting a service."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()
case = json.loads((ROOT/'config/packaging/tests/artifact-contract.json').read_text())
package = json.loads((ROOT/'config/packaging/release-project.json').read_text())['packageName']
version = (ROOT/'VERSION').read_text().strip()
artifact = Path(sys.argv[1]) if len(sys.argv)>1 else ROOT / case['artifactPattern'].format(version=version, package=package)
fields = subprocess.check_output(['dpkg-deb','-f',str(artifact),'Package','Version','Architecture'],text=True)
assert fields == f'Package: {package}\nVersion: {version}\nArchitecture: {case["architecture"]}\n',fields
prefix='./opt/'+package+'/'
wanted=['packaging/IMAGE-MANIFEST.json','packaging/scripts/release-project.json',
        'packaging/templates/install-policy.json','packaging/scripts/release-system-seeds.json',
        'packaging/scripts/recovery-project.sh','packaging/scripts/sync-release-system-seeds.js']
content={};names=[];modes={}
process=subprocess.Popen(['dpkg-deb','--fsys-tarfile',str(artifact)],stdout=subprocess.PIPE)
with tarfile.open(fileobj=process.stdout,mode='r|') as stream:
    for entry in stream:
        assert entry.uid==entry.gid==0,entry.name
        assert not entry.issym() and not entry.islnk(),entry.name
        if not entry.isfile():continue
        names.append(entry.name);modes[entry.name]=entry.mode
        if entry.name in [prefix+name for name in wanted]:
            content[entry.name[len(prefix):]]=stream.extractfile(entry).read()
assert process.wait()==0
assert not any(name.startswith(value) for name in names for value in case['forbiddenPrefixes'])
assert not any(name.startswith(prefix+'server/docker/scripts/') for name in names)
assert not any('/e2e_db/' in name or '/dev/' in name or name.endswith('/.env.secrets') for name in names)
assert not any(name.endswith(tuple('/'+value for value in case['forbiddenHelpers'])) for name in names)
policy=json.loads(content['packaging/templates/install-policy.json'])
assert policy['ownedDirectories']==policy['migrateOwnership']==policy['ensureSecrets']==[]
assert len(policy['freshSecrets'])==case['freshSecrets']
assert not any(key.startswith(tuple(case['forbiddenEnvironmentPrefixes'])) for key in policy['environmentDefaults'])
seed_prefix=prefix+'server/docker/conf/mongodb/myscoutee_db/'
seed_names={Path(name).stem for name in names if name.startswith(seed_prefix) and name.endswith('.json')}
assert seed_names==set(case['productionCollections']),seed_names
release_seeds=json.loads(content['packaging/scripts/release-system-seeds.json'])
assert {row['collection'] for row in release_seeds}==set(case['synchronizedCollections'])
manifest=json.loads(content['packaging/IMAGE-MANIFEST.json'])
assert manifest['releaseVersion']==version and manifest['bundled'] is True
assert len(manifest['images'])==case['imageCount']
assert len([name for name in names if name.startswith(prefix+'images/') and name.endswith('.tar')])==case['imageCount']
for row in manifest['images']:
    assert row['reference'].startswith(case['imageRepositoryPrefix']),row
for name in case['executableHelpers']:
    assert modes[prefix+'packaging/scripts/'+name]==0o755,name
for path,body in content.items():
    if path!='packaging/IMAGE-MANIFEST.json':assert body==(ROOT / case['sourceInputs'][path]).read_bytes(),path
with tempfile.TemporaryDirectory(prefix='template-deb-control-') as directory:
    control=Path(directory)
    subprocess.run(['dpkg-deb','-e',str(artifact),directory],check=True)
    for name in ['postinst','prerm']:
        expected = subprocess.check_output(['python3',str(ROOT/'config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py'),str(ROOT/'packaging'),'-','--hook',name])
        assert (control/name).read_bytes()==expected,name
    subprocess.run(['python3',str(ROOT/'config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py'),str(ROOT/'packaging'),str(control/'expected-postrm')],check=True)
    assert (control/'postrm').read_bytes()==(control/'expected-postrm').read_bytes()
    assert '@PACKAGE_' not in (control/'postrm').read_text()
    for name in ['postinst','prerm','postrm']:
        subprocess.run(['bash','-n',str(control/name)],check=True)
        assert (control/name).stat().st_mode & 0o777 == 0o755
print('PASS: actual DEB identity, selected bundled images/catalogs, retained policy, host helpers and rendered maintainer scripts; no unselected runtime payload.')
