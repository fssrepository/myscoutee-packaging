#!/usr/bin/env python3
"""Run the existing catalog oracle on one already-running Mongo container.

Read large pinned JSON inputs as data, without embedding them in JavaScript ASTs.
Never start an application, database, VM or build owner.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid
from pathlib import Path
import os, sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'lib'))
from mongo_test_runtime import run_mongo

ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd()))
CONTRACT = json.loads((Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'config/packaging/tests/contract-inputs.json').read_text())['contracts']['release-catalog-parity-runtime-test']
CONTRACT_INPUTS = CONTRACT['inputs']
CONTRACT_EXPECTATIONS = CONTRACT.get('expectations', {})
CONTAINER = os.environ.get('MYSCOUTEE_TEST_MONGO_CONTAINER', 'mongodb')
DIRECTORY = '/tmp/qa-release-catalogs-' + uuid.uuid4().hex
HEAP_MIB = 384
if os.environ.get('MYSCOUTEE_TEST_MONGO_TARGET', 'monolith') != 'monolith':
    raise ValueError('This file-backed test requires the selected local Mongo container')

def run(*command):
    return subprocess.run(command, cwd=ROOT, check=True)

run('docker', 'exec', CONTAINER, 'mkdir', '-m', '700', DIRECTORY)
try:
    copies = [
        (CONTRACT_INPUTS['migrations_seeds_016_release_catalog_parity'], DIRECTORY + '/016'),
        (CONTRACT_INPUTS['seeds_017_release_catalog_refresh_catalog_updates_json'], DIRECTORY + '/catalog-updates.json'),
        *[(CONTRACT_INPUTS['mongodb_myscoutee_db__name_json'].format(name=name), DIRECTORY + '/current-' + name + '.json')
          for name in ('helpCenterRevisions', 'helpCenterGuideFields')]
    ]
    for source, target in copies:
        run('docker', 'cp', source, CONTAINER + ':' + target)
    result = subprocess.run(['node', '--max-old-space-size=' + str(HEAP_MIB),
                             str(Path(__file__).with_name('release-catalog-parity-test.mjs')), '--print-script',
                             '--input-directory=' + DIRECTORY, *(['--refresh-only'] if '--refresh-only' in sys.argv else [])], cwd=ROOT, capture_output=True, text=True, check=True)
    run_mongo(result.stdout, node_heap_mib=HEAP_MIB)
finally:
    run('docker', 'exec', CONTAINER, 'rm', '-rf', '--', DIRECTORY)
