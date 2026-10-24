#!/usr/bin/env python3
"""Check the existing internal enqueue entry point with UUID-owned group data."""
import json
from pathlib import Path
import shlex
import sys
import uuid
from pathlib import Path
import os, sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'lib'))
from mongo_test_runtime import run_mongo

ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd()))
import os as _runtime_context_os
_runtime_context_os.environ.setdefault('MYSCOUTEE_BACKEND_SOURCE', str(ROOT))
sys.path.insert(0, str(Path(_runtime_context_os.environ.get('MYSCOUTEE_MICROSERVICES_SOURCE', (ROOT).parent / 'myscoutee-microservices')) / 'tools'))
import workloads as w

w.namespace_owned()
run = 'qa-media-enqueue-' + uuid.uuid4().hex
names = [w.CONFIG['databases'][mode] for mode in ('real', 'demo')]
secrets = json.loads(w.SECRET_FILE.read_text())
ip = w.kube_json('-n', w.NAMESPACE, 'get', 'service', 'media')['spec']['clusterIP']
result = {'point': 20, 'samples': [], 'status': 'FAIL'}

def mongo(body):
    return json.loads(run_mongo('const names=%s,run=%s;\n' % (json.dumps(names), json.dumps(run)) + body, capture=True))

def enqueue(mode):
    request = {'url': 'http://' + ip + ':8080/_internal/v1/media/media-deletion/enqueue',
               'headers': {'Content-Type': 'application/json',
                           'Authorization': 'Bearer ' + secrets['mediaDeletionToken'],
                           'X-MyScoutee-Session-Mode': mode},
               'body': {'baseGroupId': run, 'references': ['/api/media/private?key=private/images/' + run + '/asset/photo/small.webp']}}
    script = "import json,sys,urllib.request;v=json.load(sys.stdin);r=urllib.request.Request(v['url'],data=json.dumps(v['body']).encode(),headers=v['headers']);print(urllib.request.urlopen(r,timeout=15).read().decode())"
    response = w.execute(w.vm.ssh_command('python3 -c ' + shlex.quote(script)), data=json.dumps(request))
    assert json.loads(response.stdout) == {'returned': True}

try:
    for mode, name in zip(('REAL', 'DEMO'), names):
        enqueue(mode)
        first = mongo('print(JSON.stringify(db.getSiblingDB(%s).mediaDeletions.find({baseGroupId:run}).sort({_id:1}).toArray()));' % json.dumps(name))
        assert len(first) == 4 and {row['key'].rsplit('/', 1)[1] for row in first} == {'original', 'small.webp', 'medium.webp', 'large.webp'}
        enqueue(mode)
        second = mongo('print(JSON.stringify(db.getSiblingDB(%s).mediaDeletions.find({baseGroupId:run}).sort({_id:1}).toArray()));' % json.dumps(name))
        assert first == second, 'Duplicate enqueue changed existing intents'
        result['samples'].append({'mode': mode, 'database': name, 'managedVariants': 4, 'duplicateUnchanged': True})
    result['status'] = 'PASS'
finally:
    result['cleanup'] = mongo('print(JSON.stringify(names.map(name=>{const d=db.getSiblingDB(name);d.mediaDeletions.deleteMany({baseGroupId:run});return {name,remaining:d.mediaDeletions.countDocuments({baseGroupId:run})};})));')
    (ROOT / '.e2e-artifacts/functional/template-regression/media-enqueue-kvm.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
