#!/usr/bin/env python3
"""Qualify the deployed KVM outbox with its existing typed provider transport.

Only owned synthetic topic notifications are sent to the local receiver. No FCM
credential, real device token or product fallback is added. Restores the worker
environment and scheduling documents, and removes only this run's records.
"""
import hmac
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from pathlib import Path
import os, sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'lib'))
from mongo_test_runtime import run_mongo

ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd()))
import os as _runtime_context_os
_runtime_context_os.environ.setdefault('MYSCOUTEE_BACKEND_SOURCE', str(ROOT))
sys.path.insert(0, str(Path(_runtime_context_os.environ.get('MYSCOUTEE_MICROSERVICES_SOURCE', (ROOT).parent / 'myscoutee-microservices')) / 'tools'))
import workloads as w
assert os.environ.get('MYSCOUTEE_TEST_MONGO_TARGET') == 'kvm'
w.namespace_owned()
RUN = 'qa-push-' + uuid.uuid4().hex
NAMES = [w.CONFIG['databases'][mode] for mode in ('real', 'demo')]
SECRETS = json.loads(w.SECRET_FILE.read_text())
BACKUP = ROOT / '.e2e-artifacts/fixtures' / (RUN + '.json')
OUTPUT = Path(os.environ.get('MYSCOUTEE_TEST_EVIDENCE', ROOT / '.e2e-artifacts' / (RUN + '-result.json')))
provider_attempts = []
counts = {}
lock = threading.Lock()


def mongo(body):
    return json.loads(run_mongo('const names=%s,run=%s;\n' % (json.dumps(NAMES), json.dumps(RUN)) + body, capture=True))


class Receiver(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != '/_internal/v1/platform/firebase-push/single':
            self.send_error(404); return
        if not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + SECRETS['firebasePushDeliveryToken']):
            self.send_error(403); return
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        message = body['message']
        topic = message['topic']
        if not topic.startswith(RUN) or message.get('token'):
            self.send_error(403); return
        with lock:
            counts[topic] = counts.get(topic, 0) + 1
            attempt = counts[topic]
            provider_attempts.append({'topic': topic, 'attempt': attempt, 'payload': message,
                                      'mode': self.headers.get('X-MyScoutee-Session-Mode')})
        response = json.dumps({'code': 'LOCAL_TEST_RETRY'} if attempt == 1 else {'completed': True}).encode()
        self.send_response(503 if attempt == 1 else 200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.end_headers(); self.wfile.write(response)

    def log_message(self, *_):
        pass


def stopped():
    w.kube('-n', w.NAMESPACE, 'scale', 'deployment/communication', '--replicas=0')
    w.kube('-n', w.NAMESPACE, 'wait', '--for=delete', 'pod', '-l', 'app.kubernetes.io/name=communication', '--timeout=90s')


def started():
    w.kube('-n', w.NAMESPACE, 'scale', 'deployment/communication', '--replicas=1')
    w.kube('-n', w.NAMESPACE, 'rollout', 'status', 'deployment/communication', '--timeout=120s', timeout=150)


def set_environment(values):
    w.kube('-n', w.NAMESPACE, 'patch', 'deployment/communication', '--type=json', '-p', json.dumps([
        {'op': 'replace', 'path': '/spec/template/spec/containers/0/env', 'value': values}]))


def enqueue(mode, topic, once=False):
    command = {'context': {'active': False, 'groupId': None}, 'operationId': topic if once else None,
               'intent': {'type': 'qa-push', 'entityType': 'qa', 'entityId': topic,
                          'recipientScope': 'topic:' + topic, 'recipientUserIds': [RUN + '-member'],
                          'title': 'Local outbox qualification', 'body': 'Owned test notification',
                          'clickUrl': '/home', 'iconUrl': None, 'badgeUrl': None, 'tag': topic,
                          'payload': {'fixture': RUN, 'topicThreshold': '1'}, 'createdUser': RUN}}
    request = {'url': 'http://' + service_ip + ':8080/_internal/v1/notifications/outbox/' + ('enqueue-once' if once else 'enqueue'),
               'headers': {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + SECRETS['notificationDeliveryToken'],
                           'X-MyScoutee-Session-Mode': mode}, 'body': command}
    script = "import json,sys,urllib.request;v=json.load(sys.stdin);r=urllib.request.Request(v['url'],data=json.dumps(v['body']).encode(),headers=v['headers']);print(urllib.request.urlopen(r,timeout=30).read().decode())"
    result = w.execute(w.vm.ssh_command('python3 -c ' + shlex.quote(script)), data=json.dumps(request))
    response = json.loads(result.stdout)
    assert response['completed'] and response['receipt'], response
    return response['receipt']['id']


def items():
    return mongo('print(JSON.stringify(names.flatMap(name=>db.getSiblingDB(name).notificationOutbox.find({createdUser:run}).toArray())));')


def await_items(predicate, label, seconds=100):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        found = items()
        if len(found) == 4 and all(predicate(item) for item in found):
            return found
        time.sleep(2)
    raise AssertionError(label + ': ' + json.dumps(found))


original = w.kube_json('-n', w.NAMESPACE, 'get', 'deployment', 'communication')['spec']['template']['spec']['containers'][0]['env']
assert not any(e['name'] == 'MYSCOUTEE_REMOTE_FIREBASE_PUSH_DELIVERY_URL' for e in original), 'Unexpected provider override'
service_ip = w.kube_json('-n', w.NAMESPACE, 'get', 'service', 'communication')['spec']['clusterIP']
snapshots = mongo('''print(JSON.stringify(names.map(name=>{
 const d=db.getSiblingDB(name);
 if(d.notificationOutbox.countDocuments({status:{$in:['pending','running']}}))throw Error('Unowned pending work in '+name);
 const rule=d.notificationRuleConfigs.findOne({ruleKey:'notification-outbox',baseGroupId:null});
 if(!rule)throw Error('Missing native outbox rule');
 return {name,rule:EJSON.stringify(rule,{relaxed:false})};
})));''')
BACKUP.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
BACKUP.write_text(json.dumps({'run': RUN, 'environment': original, 'snapshots': snapshots})); BACKUP.chmod(0o600)
server = ThreadingHTTPServer(('192.168.174.1', 18992), Receiver)
threading.Thread(target=server.serve_forever, daemon=True).start()
evidence = {'target': 'template-kvm', 'run': RUN, 'provider': 'local typed FirebasePushDelivery receiver', 'checks': {}}
try:
    mongo('for(const name of names)db.getSiblingDB(name).notificationRuleConfigs.updateOne({ruleKey:"notification-outbox",baseGroupId:null},{$set:{enabled:false}});print("true");')
    mongo('for(const name of names)db.getSiblingDB(name).users.insertOne({_id:run,userId:run+"-member",name:"Owned push recipient",status:"A",profileStatus:"active",qaFixture:run});print("true");')
    stopped()
    set_environment(original + [{'name': 'MYSCOUTEE_REMOTE_FIREBASE_PUSH_DELIVERY_URL', 'value': 'http://192.168.174.1:18992'}])
    started()
    print('Provider bound through existing transport; staging owned REAL/DEMO notifications.', flush=True)
    for mode in ['REAL', 'DEMO']:
        topic = RUN + '-' + mode + '-collapse'
        first = enqueue(mode, topic); second = enqueue(mode, topic)
        assert first == second, 'Identical pending notifications must collapse'
        topic = RUN + '-' + mode + '-once'
        first = enqueue(mode, topic, True); second = enqueue(mode, topic, True)
        assert first == second, 'Operation ID must be idempotent'
    assert len(items()) == 4
    evidence['checks']['collapseAndOperationId'] = True
    # Simulate already-snapshotted pending push work while live Firebase remains disabled.
    # This is an owned test fixture, not an authentication/configuration fallback.
    mongo('''for(const name of names){const d=db.getSiblingDB(name);
 d.notificationOutbox.updateMany({createdUser:run},{$set:{firebaseDeliveryRequested:true}});
 d.notificationRuleConfigs.updateOne({ruleKey:'notification-outbox',baseGroupId:null},{$set:{enabled:true,
 'timing.intervalSeconds':1,'timing.intervalMinutes':0,'timing.intervalAmount':1,'timing.intervalUnit':'seconds',
 'runState.currentStatus':'idle','runState.nextRunAt':null}});
}print("true");''')
    failed = await_items(lambda item: item['status'] == 'pending' and item['retryCount'] == 1, 'Expected durable first failure')
    assert all(item['nextRetryAt'] > item['updatedDate'] for item in failed)
    evidence['checks']['failedAttemptPersistsRetry'] = True
    with lock:
        assert len(provider_attempts) == 4 and all(value == 1 for value in counts.values()), 'Transport must not retry sends itself'
    print('First provider failures persisted; reconstructing the existing worker.', flush=True)
    stopped()
    mongo('for(const name of names)db.getSiblingDB(name).notificationOutbox.updateMany({createdUser:run},{$set:{nextRetryAt:new Date(Date.now()-1000).toISOString()}});print("true");')
    started()
    delivered = await_items(lambda item: item['status'] == 'sent', 'Expected delivered retry')
    assert {item['_id'] for item in delivered} == {item['_id'] for item in failed}
    assert all(item['retryCount'] == 1 for item in delivered)
    evidence['checks']['sameDurableItemsAfterRestart'] = True
    for mode in ['REAL', 'DEMO']:
        topic = RUN + '-' + mode + '-once'
        receipt = enqueue(mode, topic, True)
        assert receipt in {item['_id'] for item in delivered}
    time.sleep(7)
    with lock:
        assert len(provider_attempts) == 8 and all(value == 2 for value in counts.values()), 'Completed work sent more than once'
        for event in provider_attempts:
            assert '-' + event['mode'] + '-' in event['topic'], 'REAL/DEMO provider routing mismatch'
        evidence['attempts'] = list(provider_attempts)
    evidence['checks']['completedOperationReplayDoesNotSendAgain'] = True
    evidence['checks']['realDemoIsolation'] = True
finally:
    stopped()
    mongo('''for(const snapshot of %s){const d=db.getSiblingDB(snapshot.name);
 d.notificationOutbox.deleteMany({createdUser:run});
 d.userNotifications.deleteMany({recipientUserId:run+'-member'});
 d.users.deleteMany({qaFixture:run});
 const rule=EJSON.parse(snapshot.rule,{relaxed:false});d.notificationRuleConfigs.replaceOne({_id:rule._id},rule);
}print("true");''' % json.dumps(snapshots))
    set_environment(original)
    started()
    server.shutdown(); server.server_close()
    BACKUP.unlink()
    evidence['cleanup'] = True
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(evidence, indent=2) + '\n')
print('DONE deployed local-provider push: collapse, enqueue-once, durable failure/restart/retry, no duplicate delivery, REAL/DEMO isolation; original runtime restored.', flush=True)
