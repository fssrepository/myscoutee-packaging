#!/usr/bin/env python3
"""Check selected install data and generated secrets without touching a host."""
import copy
import json
import re
import subprocess
import tempfile
import os
from pathlib import Path

ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()
source = subprocess.check_output(['python3', str(ROOT / 'config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py'), str(ROOT / 'packaging'), '-', '--hook', 'postinst'], text=True)
validator = re.search(r"jq -e --arg package .*?'\n(.*?)\n' \"\$INSTALL_POLICY\"", source, re.S).group(1)
policy = json.loads((ROOT / 'config/packaging/templates/install-policy.json').read_text())
project = json.loads((ROOT / 'config/packaging/release-project.json').read_text())

def validate(value):
    return subprocess.run(['jq', '-e', '--arg', 'package', project['packageName'],
                           '--argjson', 'uid', str(project['runtimeIdentity']['uid']),
                           '--argjson', 'gid', str(project['runtimeIdentity']['gid']), validator], input=json.dumps(value),
                          text=True, capture_output=True).returncode == 0

assert validate(policy)
minimal = copy.deepcopy(policy)
minimal.update(ownedDirectories=[], migrateOwnership=[], ensureSecrets=[],
               freshSecrets=policy['freshSecrets'][:3], environmentDefaults={},
               requiredMongoCollections=['helpCenterRevisions'],
               mongoSeedFallback='demo_db:*;production_db:helpCenterRevisions')
assert validate(minimal)
for path, value in [('unknown', True), ('ownedDirectories', [{'path': '/tmp/foreign', 'mode': '0700', 'uid': 10001, 'gid': 10001}]),
                    ('environmentDefaults', {'BAD;COMMAND': 'x'}),
                    ('environmentDefaults', {'BAD_VALUE': 'x\nOTHER=changed'}),
                    ('freshSecrets', [{'key': 'KEY', 'encoding': 'shell', 'prefix': ''}]),
                    ('runtimeIdentityMigrations', [{'maximumVersion': '1.0.0', 'uid': 0, 'gid': 10001}]),
                    ('runtimeIdentityMigrations', [{'maximumVersion': '../foreign', 'uid': 10001, 'gid': 10001}])]:
    invalid = copy.deepcopy(policy)
    invalid[path] = value
    assert not validate(invalid), path

functions = '\n'.join(re.search(r'^' + name + r'\(\) \{\n.*?^\}', source,
                               re.M | re.S).group() for name in [
    'generate_secret', 'generate_guid', 'generate_policy_secret',
    'install_generated_secrets_file', 'read_env_file_value', 'upsert_env_value', 'ensure_generated_secret',
    'ensure_mongo_seed_allow_list'])
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    (root / 'etc').mkdir()
    (root / 'opt/packaging/templates').mkdir(parents=True)
    (root / 'functions.sh').write_text(functions.replace('${PACKAGE_ETC}', str(root / 'etc'))
                                     .replace('${PACKAGE_ROOT}', str(root / 'opt')).replace('${PACKAGE_NAME}', 'myscoutee'))
    for selection in [policy, minimal]:
        (root / 'policy.json').write_text(json.dumps(selection))
        keys = [item['key'] for item in selection['freshSecrets']]
        template = root / 'opt/packaging/templates/myscoutee.secrets.env'
        template.write_text('CUSTOM=retained\n' + ''.join(key + '=\n' for key in keys))
        subprocess.run(['bash', '-euc', 'source "$1/functions.sh"; INSTALL_POLICY="$1/policy.json"; install_generated_secrets_file',
                        'test', directory], check=True)
        target = root / 'etc/myscoutee.secrets.env'
        values = dict(line.split('=', 1) for line in target.read_text().splitlines() if line)
        assert values.pop('CUSTOM') == 'retained'
        assert set(values) == set(keys)
        assert target.stat().st_mode & 0o777 == 0o600
        for secret in selection['freshSecrets']:
            pattern = '[a-f0-9]{64}' if secret['encoding'] == 'hex' else '[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-8[a-f0-9]{3}-[a-f0-9]{12}'
            assert re.fullmatch(re.escape(secret['prefix']) + pattern, values[secret['key']])
        before = target.read_bytes()
        subprocess.run(['bash', '-euc', 'source "$1/functions.sh"; ensure_generated_secret "$1/etc/myscoutee.secrets.env" MONGO_APP_PASSWORD replacement',
                        'test', directory], check=True)
        assert target.read_bytes() == before, 'upgrade replaced an existing credential'
    # An older deployment may have the names in another database, multiple
    # production rules, or similarly named collections. None proves coverage.
    (root / 'policy.json').write_text(json.dumps(minimal))
    for current in ['', 'demo_db:helpCenterRevisions;production_db:custom',
                    'production_db:helpCenterRevisionsArchive',
                    'demo_db:*;production_db:custom;production_db:other',
                    'e2e_db:*;demo_db:*']:
        target = root / 'etc/myscoutee.env'
        target.write_text('CUSTOM=retained\nMONGO_IMPORT_ALLOWED_COLLECTIONS_BY_DB=' + current + '\n')
        command = ['bash', '-euc', 'source "$1/functions.sh"; INSTALL_POLICY="$1/policy.json"; ensure_mongo_seed_allow_list', 'test', directory]
        subprocess.run(command, check=True)
        values = dict(line.split('=', 1) for line in target.read_text().splitlines() if line)
        assert values['CUSTOM'] == 'retained'
        rules = values['MONGO_IMPORT_ALLOWED_COLLECTIONS_BY_DB'].split(';')
        production = [rule.split(':', 1)[1] for rule in rules if rule.startswith('production_db:')]
        assert len(production) == 1 and 'helpCenterRevisions' in production[0].split(',')
        for rule in current.split(';'):
            if rule and not rule.startswith('production_db:'):
                assert rule in rules, 'upgrade changed another database rule'
            elif rule:
                assert set(rule.split(':', 1)[1].split(',')).issubset(production[0].split(','))
        before = target.read_bytes()
        subprocess.run(command, check=True)
        assert target.read_bytes() == before, 'second upgrade changed the import rules'
print('PASS: native/minimal install selections, safe policy fields, generated secrets and credential preservation.')
