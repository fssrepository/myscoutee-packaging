#!/usr/bin/env python3
"""Exercise the retained purge worker on one already-running qualification stack.

Uses the existing Mongo/workload transports, owned records in both configured
databases and owned object keys. Stops only MinIO to cause a real dependency
failure, then restarts only the existing identity owner to resume persisted work.
Rule snapshots are restored; no seed or application default is changed.
"""
import hashlib
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
RUN = 'qa-purge-' + uuid.uuid4().hex
BACKUP = ROOT / '.e2e-artifacts/fixtures' / (RUN + '.json')
if TARGET == 'kvm':
    import os as _runtime_context_os
    _runtime_context_os.environ.setdefault('MYSCOUTEE_BACKEND_SOURCE', str(ROOT))
    sys.path.insert(0, str(Path(_runtime_context_os.environ.get('MYSCOUTEE_MICROSERVICES_SOURCE', (ROOT).parent / 'myscoutee-microservices')) / 'tools'))
    import workloads as w
    w.namespace_owned()
    DATABASES = [w.CONFIG['databases'][mode] for mode in ('real', 'demo')]
else:
    assert TARGET == 'monolith'
    # Explicit existing containers prevent accidental use of another project.
    BACKEND = os.environ['MYSCOUTEE_TEST_BACKEND_CONTAINER']
    MINIO = os.environ['MYSCOUTEE_TEST_MINIO_CONTAINER']
    database_names = subprocess.run(['docker', 'exec', BACKEND, 'sh', '-c',
        'printf \"%s\\n\" \"$MONGODB_DATABASE\" \"$MONGODB_DEMO_DATABASE\"'],
        check=True, text=True, capture_output=True)
    DATABASES = database_names.stdout.strip().splitlines()
assert len(set(DATABASES)) == 2 and all(DATABASES), 'Distinct configured databases required'
IDS = [RUN + '-a', RUN + '-b']
KEYS = [RUN + '-real.webp', RUN + '-demo.webp']
HASHES = [hashlib.sha256(('account-purge:' + value).encode()).hexdigest() for value in IDS]


def mongo(body):
    prelude = 'const names=%s,ids=%s,keys=%s,hashes=%s,run=%s;\n' % tuple(
        json.dumps(value) for value in (DATABASES, IDS, KEYS, HASHES, RUN))
    return json.loads(run_mongo(prelude + body, capture=True))


def command(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=180)


def stop(owner):
    if TARGET == 'kvm':
        w.kube('-n', w.NAMESPACE, 'scale', 'deployment/' + owner, '--replicas=0')
        w.kube('-n', w.NAMESPACE, 'wait', '--for=delete', 'pod',
               '-l', 'app.kubernetes.io/name=' + owner, '--timeout=90s')
    else:
        command('docker', 'stop', BACKEND if owner == 'identity' else MINIO)


def start(owner):
    if TARGET == 'kvm':
        w.kube('-n', w.NAMESPACE, 'scale', 'deployment/' + owner, '--replicas=1')
        w.kube('-n', w.NAMESPACE, 'rollout', 'status', 'deployment/' + owner, '--timeout=120s', timeout=150)
    else:
        name = BACKEND if owner == 'identity' else MINIO
        command('docker', 'start', name)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if command('docker', 'inspect', '--format', '{{.State.Health.Status}}', name).stdout.strip() == 'healthy':
                return
            time.sleep(2)
        raise RuntimeError(name + ' did not become healthy')


def media(action):
    script = '''set -eu
export GOMEMLIMIT=48MiB GOMAXPROCS=1
mc alias set qa_purge http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
trap 'mc alias remove qa_purge >/dev/null' EXIT
for key in "$@"; do
  case "$key" in qa-purge-*.webp) ;; *) exit 9;; esac
  object="qa_purge/$MEDIA_BUCKET/$key"
  case "$QA_ACTION" in
    stage) printf 'owned purge qualification object' > "/tmp/$key"; mc cp "/tmp/$key" "$object" >/dev/null; rm "/tmp/$key" ;;
    present) mc stat "$object" >/dev/null ;;
    absent|cleanup)
      if details=$(mc stat --json "$object" 2>&1); then
        [ "$QA_ACTION" = cleanup ] || exit 8
        mc rm --force "$object" >/dev/null
      else
        case "$details" in *'"message":"Object does not exist"'*) ;; *) printf '%s\n' "$details" >&2; exit 7;; esac
      fi ;;
  esac
done
'''
    if TARGET == 'kvm':
        w.kube('-n', w.NAMESPACE, 'exec', '-i', 'deployment/minio', '--',
               'env', 'QA_ACTION=' + action, 'sh', '-s', '--', *KEYS, data=script)
    else:
        subprocess.run(['docker', 'exec', '-i', '-e', 'QA_ACTION=' + action, MINIO,
                        'sh', '-s', '--', *KEYS], input=script, check=True,
                       text=True, capture_output=True, timeout=60)


def wait_jobs(status):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        jobs = mongo('print(JSON.stringify(names.map((name,i)=>db.getSiblingDB(name).accountPurgeJobs.findOne({userHash:hashes[i]}))));')
        if all(job and job['status'] == status for job in jobs):
            return jobs
        time.sleep(2)
    raise AssertionError('Purge jobs did not reach ' + status + ': ' + json.dumps(jobs))


# Refuse to run the accelerated schedule over anyone else's eligible work.
before = mongo('''
const snapshots=names.map(name=>{
 const d=db.getSiblingDB(name);
 if(d.users.countDocuments({profileStatus:{$in:['deleted','onboarding']},deletedAtIso:{$lte:new Date(Date.now()-30*86400000).toISOString()}}))throw Error('Unowned expired accounts: '+name);
 if(d.accountPurgeJobs.countDocuments({status:{$in:['pending','running','failed']}}))throw Error('Unowned pending purge jobs: '+name);
 const rule=d.notificationRuleConfigs.findOne({ruleKey:'account-purge',baseGroupId:null});
 if(!rule)throw Error('Missing native purge rule');
 return {name,rule:EJSON.stringify(rule,{relaxed:false}),users:d.users.countDocuments()};
});print(JSON.stringify(snapshots));
''')
BACKUP.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
BACKUP.write_text(json.dumps({'run': RUN, 'target': TARGET, 'snapshots': before}, indent=2))
BACKUP.chmod(0o600)
staged = False
minio_stopped = False
identity_stopped = False
evidence = {'target': TARGET, 'databases': DATABASES, 'run': RUN}
output = Path(os.environ.get('MYSCOUTEE_TEST_EVIDENCE', ROOT / '.e2e-artifacts' / (RUN + '-result.json')))
try:
    staged = True
    media('stage')
    mongo('''
for(let i=0;i<names.length;i++){
 const d=db.getSiblingDB(names[i]),expired=ids[i],peer=ids[1-i],now=Date.now();
 // Same business IDs in both databases, with opposite expiry, detect mode leaks.
 for(const [id,days] of [[expired,31],[peer,1]])d.users.insertOne({
  _id:run+'-physical-'+id,userId:id,name:id,profileStatus:'deleted',status:'D',
  deletedAtIso:new Date(now-days*86400000).toISOString(),images:id===expired?[keys[i]]:[],
  accountPurgePendingCounterTracked:id===expired,qaFixture:run});
 for(const c of ['privacyConsents','userSessionActions','accountDeletionWarnings'])
  for(const id of ids)d[c].insertOne({_id:run+'-'+id,userId:id,qaFixture:run});
 for(const c of ['integrationTokens','mcpAuthorizations','mcpEventSubscriptions','integrationWebhookDeliveries'])
  for(const id of ids)d[c].insertOne({_id:run+'-'+id,ownerUserId:id,tokenHash:run+'-'+id,status:'revoked',qaFixture:run});
 d.userNotifications.insertMany([
  {_id:run+'-expired-inbox',recipientUserId:expired,qaFixture:run},
  {_id:run+'-peer-inbox',recipientUserId:peer,senderUserId:expired,message:'Private',payload:{senderUserId:expired},qaFixture:run}]);
 d.helpCenterRevisions.insertOne({_id:run,createdUser:expired,updatedUser:peer,qaFixture:run});
 d.chats.insertOne({_id:run,id:run,ownerUserId:peer,memberIds:ids,qaFixture:run});
 for(const id of ids)d.chatMessages.insertOne({_id:run+'-'+id,id:run+'-'+id,chatId:run,
  sender:id,senderAvatar:{id,name:id},messageSenderUserIds:[id],text:id===expired?'Private':'Keep this text',
  sentAtIso:new Date(now).toISOString(),qaFixture:run});
 d.notificationRuleConfigs.updateOne({ruleKey:'account-purge',baseGroupId:null},{$set:{
  enabled:true,runState:{pendingCount:1},'timing.mode':'interval','timing.intervalSeconds':1,
  'timing.intervalAmount':1,'timing.intervalUnit':'seconds',scheduleSlots:[]}});
}print('true');
''')
    print('Fixture staged: opposite expiry in REAL/DEMO; actual object-store failure next.', flush=True)
    stop('minio')
    minio_stopped = True
    stop('identity')
    identity_stopped = True
    start('identity')
    identity_stopped = False
    failed = wait_jobs('failed')
    for job in failed:
        assert job['stage'] == 'profile-media' and job['retryCount'] == 1
        assert job.get('nextRetryAtIso') and job.get('lastError')
    assert mongo('print(JSON.stringify(names.every(name=>db.getSiblingDB(name).users.countDocuments({userId:{$in:ids}})===2)));')
    evidence['failure'] = [{'stage': j['stage'], 'retryCount': j['retryCount'],
                            'nextRetryAtIso': j['nextRetryAtIso']} for j in failed]
    print('DONE: dependency failure retained both accounts and durable retries in both databases.', flush=True)
    start('minio')
    minio_stopped = False
    media('present')
    # Move only this fixture's recorded retry timestamps forward; leave production delay unchanged.
    mongo('''for(let i=0;i<names.length;i++)db.getSiblingDB(names[i]).accountPurgeJobs.updateOne(
{userHash:hashes[i],status:'failed'},{$set:{nextRetryAtIso:new Date(Date.now()-1000).toISOString()}});print('true');''')
    stop('identity')
    identity_stopped = True
    start('identity')
    identity_stopped = False
    completed = wait_jobs('completed')
    assert all(a['_id'] == b['_id'] for a, b in zip(failed, completed)), 'Persisted jobs must be resumed'
    assert all(j.get('userId') is None and j['retryCount'] == 1 for j in completed)
    evidence['cleanup'] = mongo('''
const checks=names.map((name,i)=>{
 const d=db.getSiblingDB(name),expired=ids[i],peer=ids[1-i];
 function check(ok,label){if(!ok)throw Error(name+': '+label);}
 check(!d.users.findOne({userId:expired}),'expired member removed');
 check(!!d.users.findOne({userId:peer}),'recent member retained');
 for(const c of ['privacyConsents','userSessionActions','accountDeletionWarnings']){
  check(!d[c].countDocuments({userId:expired}),c+' removed');check(d[c].countDocuments({userId:peer})===1,c+' peer retained');}
 for(const c of ['integrationTokens','mcpAuthorizations','mcpEventSubscriptions','integrationWebhookDeliveries']){
  check(!d[c].countDocuments({ownerUserId:expired}),c+' removed');check(d[c].countDocuments({ownerUserId:peer})===1,c+' peer retained');}
 check(!d.userNotifications.findOne({_id:run+'-expired-inbox'}),'inbox removed');
 const notification=d.userNotifications.findOne({_id:run+'-peer-inbox'});
 check(notification.senderUserId==='deleted-user'&&Object.keys(notification.payload).length===0,'peer notification anonymized');
 check(d.helpCenterRevisions.findOne({_id:run}).createdUser==='deleted-user','help author anonymized');
 check(JSON.stringify(d.chats.findOne({_id:run}).memberIds)===JSON.stringify([peer]),'chat membership');
 const removed=d.chatMessages.findOne({id:run+'-'+expired});check(removed.text===''&&!!removed.deletedAtIso,'message redacted');
 check(d.chatMessages.findOne({id:run+'-'+peer}).text==='Keep this text','peer message retained');
 check(d.notificationRuleConfigs.findOne({ruleKey:'account-purge',baseGroupId:null}).runState.pendingCount===0,'pending counter');
 check(d.accountPurgeJobs.countDocuments({userHash:{$in:hashes}})===1,'no duplicate/cross-mode job');
 return {database:name,expiredRemoved:true,recentRetained:true,cleanupOwners:true,pendingCount:0};
});print(JSON.stringify(checks));
''')
    media('absent')
    evidence['samePersistedJobsResumed'] = True
    evidence['ownedMediaDeleted'] = True
    output.write_text(json.dumps(evidence, indent=2) + '\n')
    print('DONE: restart resumed both persisted jobs; owned media/references removed, peers retained.', flush=True)
finally:
    if minio_stopped:
        start('minio')
    if identity_stopped:
        start('identity')
    if staged:
        restore = json.dumps(before)
        mongo('''
const saved=''' + restore + ''';
for(const row of saved){const d=db.getSiblingDB(row.name),rule=EJSON.parse(row.rule,{relaxed:false});
 d.notificationRuleConfigs.replaceOne({_id:rule._id},rule);
 for(const c of ['privacyConsents','userSessionActions','accountDeletionWarnings','integrationTokens',
  'mcpAuthorizations','mcpEventSubscriptions','integrationWebhookDeliveries','userNotifications',
  'helpCenterRevisions','chats','chatMessages','users'])d[c].deleteMany({$or:[{qaFixture:run},{_id:{$regex:'^'+run}}]});
 d.accountPurgeJobs.deleteMany({userHash:{$in:hashes}});
 if(d.users.countDocuments()!==row.users)throw Error('Fixture cleanup user count: '+row.name);
 if(EJSON.stringify(d.notificationRuleConfigs.findOne({_id:rule._id}),{relaxed:false})!==row.rule)throw Error('Rule not restored');
}print('true');
''')
        media('cleanup')
    BACKUP.unlink()
    print('DONE: owned fixture removed and original schedules restored.', flush=True)
evidence['fixtureRemovedAndSchedulesRestored'] = True
output.write_text(json.dumps(evidence, indent=2) + '\n')
print('DONE account purge runtime: ' + TARGET + '; evidence ' + str(output), flush=True)
