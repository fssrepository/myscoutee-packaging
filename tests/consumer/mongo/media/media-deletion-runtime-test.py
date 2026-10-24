#!/usr/bin/env python3
"""Exercise the existing scheduled deletion worker with UUID-owned queue records.

Uses the native Mongo fixture transport and existing MinIO bootstrap alias. No
application endpoints, retry settings or storage implementation are replaced.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

from pathlib import Path
import os, sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'lib'))
from mongo_test_runtime import run_mongo

ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd()))
TARGET = os.environ.get('MYSCOUTEE_TEST_MONGO_TARGET', 'monolith')
RUN = 'qa-deletion-' + uuid.uuid4().hex
if TARGET == 'kvm':
    import os as _runtime_context_os
    _runtime_context_os.environ.setdefault('MYSCOUTEE_BACKEND_SOURCE', str(ROOT))
    sys.path.insert(0, str(Path(_runtime_context_os.environ.get('MYSCOUTEE_MICROSERVICES_SOURCE', (ROOT).parent / 'myscoutee-microservices')) / 'tools'))
    import workloads as w
    w.namespace_owned()
    NAMES = [w.CONFIG['databases'][mode] for mode in ('real', 'demo')]
else:
    NAMES = [os.environ.get('E2E_DATABASE', 'demo_db')]


def mongo(body):
    return json.loads(run_mongo('const names=%s,run=%s;\n' % (json.dumps(NAMES), json.dumps(RUN)) + body, capture=True))


def storage(action, key):
    script = ('printf fixture | mc pipe "${MINIO_SEED_ALIAS:-myscoutee}/${MEDIA_BUCKET}/$1" >/dev/null'
              if action == 'put' else
              'mc rm --force "${MINIO_SEED_ALIAS:-myscoutee}/${MEDIA_BUCKET}/$1" >/dev/null'
              if action == 'remove' else
              'mc stat "${MINIO_SEED_ALIAS:-myscoutee}/${MEDIA_BUCKET}/$1" >/dev/null 2>&1')
    args = ['sh', '-c', script, 'owned-media-fixture', key]
    if TARGET == 'kvm':
        return w.kube('-n', w.NAMESPACE, 'exec', 'deployment/minio', '--', *args, check=False).returncode
    return subprocess.run(['docker', 'exec', os.environ['E2E_MINIO_CONTAINER'], *args], check=False).returncode


snapshot = mongo("""
const result=[];
for(const name of names){const d=db.getSiblingDB(name);
 if(d.mediaDeletions.countDocuments({status:{$in:['pending','retry','processing']}}))throw Error('Unowned pending media work');
 const rule=d.notificationRuleConfigs.findOne({ruleKey:'media-deletion',baseGroupId:null});
 if(!rule)throw Error('Media job baseline missing');
 result.push({name,rule});
} print(JSON.stringify(result.map(r=>({name:r.name,rule:EJSON.stringify(r.rule,{relaxed:false})}))));
""")
directory = ROOT / '.e2e-artifacts/functional/template-regression'
directory.mkdir(parents=True, exist_ok=True)
backup = directory / (RUN + '-restore.json')
backup.write_text(json.dumps(snapshot)); backup.chmod(0o600)
keys = []
result = {'target': TARGET, 'run': RUN, 'databases': {}, 'status': 'FAIL'}
try:
    for name in NAMES:
        for variant in ['original', 'small.webp', 'medium.webp', 'large.webp']:
            key = f'private/images/{RUN}/{name}/image/{variant}'
            keys.append(key)
            assert storage('put', key) == 0
    mongo("""
for(const name of names){const d=db.getSiblingDB(name),past=new Date(Date.now()-86400000);
 const keys=['original','small.webp','medium.webp','large.webp'].map(v=>'private/images/'+run+'/'+name+'/image/'+v);
 for(let i=0;i<101;i++)keys.push('private/documents/'+run+'/'+name+'/missing-'+i+'.pdf');
 d.mediaDeletions.insertMany(keys.map((key,i)=>({_id:run+':'+i,baseGroupId:null,key,createdAt:past,nextAttemptAt:past,attempts:0,status:'pending'})));
 d.mediaDeletions.insertOne({_id:run+':expired',baseGroupId:null,key:'private/documents/'+run+'/'+name+'/unknown.pdf',createdAt:past,nextAttemptAt:past,attempts:3,status:'processing',claim:run});
 d.notificationRuleConfigs.updateOne({ruleKey:'media-deletion',baseGroupId:null},{$set:{enabled:true,'timing.time':'00:00','timing.intervalMinutes':0,'timing.intervalSeconds':1,'timing.intervalAmount':1,'timing.intervalUnit':'seconds',runState:{}}});
} print(JSON.stringify({staged:true}));
""")
    deadline = time.monotonic() + 45
    while True:
        state = mongo("""
print(JSON.stringify(names.map(name=>{const d=db.getSiblingDB(name);return {name,
 rows:d.mediaDeletions.find({_id:{$regex:'^'+run+':'}}).toArray(),
 history:d.notificationRuleConfigs.findOne({ruleKey:'media-deletion',baseGroupId:null}).runHistory};})));
""")
        if all(len(entry['rows']) == 1 and entry['rows'][0]['status'] == 'failed' for entry in state):
            break
        if time.monotonic() > deadline:
            raise AssertionError('Scheduled worker did not finish owned queue: ' + json.dumps([
                {'name': entry['name'], 'remaining': len(entry['rows']),
                 'states': sorted({row['status'] for row in entry['rows']})} for entry in state]))
        time.sleep(1)
    for entry in state:
        failed = entry['rows'][0]
        assert failed['attempts'] == 3 and failed['lastError'] == 'OutcomeUnknown'
        counts = [row['processedCount'] for row in entry['history'] if row.get('processedCount', 0) > 0]
        assert sorted(counts[:2]) == [5, 100], counts
        result['databases'][entry['name']] = {'processedBatches': counts[:2], 'expiredFinalLease': 'failed/OutcomeUnknown/3 attempts'}
    assert all(storage('stat', key) != 0 for key in keys), 'Owned image objects remain'
    result['status'] = 'PASS'
finally:
    mongo('const snapshot=%s;\n' % json.dumps(snapshot) + """
for(const original of snapshot){const d=db.getSiblingDB(original.name),rule=EJSON.parse(original.rule,{relaxed:false});
 d.mediaDeletions.deleteMany({_id:{$regex:'^'+run+':'}});
 d.notificationRuleConfigs.replaceOne({_id:rule._id},rule);
} print(JSON.stringify({restored:true}));
""")
    for key in keys:
        storage('remove', key)
    result['cleanup'] = mongo("""
print(JSON.stringify(names.map(name=>({name,remaining:db.getSiblingDB(name).mediaDeletions.countDocuments({_id:{$regex:'^'+run+':'}})}))));
""")
    (directory / ('media-' + TARGET + '.json')).write_text(json.dumps(result, indent=2) + '\n')
    if all(entry['remaining'] == 0 for entry in result['cleanup']):
        backup.unlink()
    print(json.dumps(result))
