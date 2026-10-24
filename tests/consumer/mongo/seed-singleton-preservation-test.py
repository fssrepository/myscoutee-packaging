#!/usr/bin/env python3
"""Check the real singleton seed importer on the one running Mongo deployment.

Uses a unique disposable database; never imports into application databases.
The existing workload transport provides KVM access; no runtime is started.
MYSCOUTEE_TEST_SEED_ROOT optionally selects another source repository while
keeping this repository's runtime transport.
"""
import base64
import os
from pathlib import Path
import shlex
import subprocess
import sys
import uuid

ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()
SOURCE = Path(os.environ.get('MYSCOUTEE_TEST_SEED_ROOT', ROOT)) / 'server/docker/conf/mongodb'
identifier = 'qa_seed_preservation_' + uuid.uuid4().hex
files = ['mongo_import.sh', 'mongo-seed-policy.inc',
         'myscoutee_db/appSettings.json', 'myscoutee_db/deploymentConfigurations.json']
stage = '\n'.join('mkdir -p "$stage/' + str(Path(name).parent) + '"\nprintf %s ' +
                  shlex.quote(base64.b64encode((SOURCE / name).read_bytes()).decode()) +
                  ' | base64 -d > "$stage/' + name + '"' for name in files)
script = r'''set -euo pipefail
stage=$(mktemp -d /tmp/qa-seed-preservation.XXXXXX)
cleanup() {
  mongosh --host "$MONGO_IMPORT_HOST" --quiet --file /dev/stdin <<'JS'
if(!db.getSiblingDB('admin').auth(process.env.MONGO_INITDB_ROOT_USERNAME,process.env.MONGO_INITDB_ROOT_PASSWORD))throw Error('Authentication failed');
const name=process.env.QA_SEED_DATABASE;
if(!/^qa_seed_preservation_[a-f0-9]{32}$/.test(name))throw Error('Unsafe cleanup target');
const t=db.getSiblingDB(name);t.dropAllUsers();t.dropDatabase();
JS
  rm -rf -- "$stage"
}
trap cleanup EXIT
__STAGE__
export MONGO_APP_DATABASE="$QA_SEED_DATABASE"
export MONGO_IMPORT_ALLOWED_COLLECTIONS_BY_DB="$QA_SEED_DATABASE:appSettings,deploymentConfigurations"
export MONGO_IMPORT_ALL_SEED_DATABASES=false
mongosh --host "$MONGO_IMPORT_HOST" --quiet --file /dev/stdin <<'JS'
if(!db.getSiblingDB('admin').auth(process.env.MONGO_INITDB_ROOT_USERNAME,process.env.MONGO_INITDB_ROOT_PASSWORD))throw Error('Authentication failed');
const t=db.getSiblingDB(process.env.QA_SEED_DATABASE);
if(t.getCollectionNames().length)throw Error('Test database already exists');
t.createUser({user:process.env.MONGO_APP_USERNAME,pwd:process.env.MONGO_APP_PASSWORD,roles:[{role:'dbOwner',db:process.env.QA_SEED_DATABASE}]});
JS
import_controls() {
  for collection in appSettings deploymentConfigurations; do
    MONGO_IMPORT_SINGLE_FILE="$stage/myscoutee_db/$collection.json" bash "$stage/mongo_import.sh" > "$stage/import.log" 2>&1 || { cat "$stage/import.log"; return 1; }
  done
}
import_controls
mongosh --host "$MONGO_IMPORT_HOST" --quiet --file /dev/stdin <<'JS'
if(!db.getSiblingDB('admin').auth(process.env.MONGO_INITDB_ROOT_USERNAME,process.env.MONGO_INITDB_ROOT_PASSWORD))throw Error('Authentication failed');
const t=db.getSiblingDB(process.env.QA_SEED_DATABASE);
if(t.appSettings.countDocuments({_id:'app-settings-global'})!==1||t.deploymentConfigurations.countDocuments({_id:'deployment-configuration'})!==1)throw Error('Fresh seed missing');
t.appSettings.updateOne({_id:'app-settings-global'},{$set:{adminEmails:['retained@qa.invalid'],adminAccessEnabled:false,custom:'keep'}});
t.deploymentConfigurations.updateOne({_id:'deployment-configuration'},{$set:{'branding.productName':'Retained operator','branding.logoUrl':'/media?key=images/operator/qa.png',custom:'keep'}});
t.users.insertOne({_id:'untouched-user',images:['images/profiles/qa.png']});
t.qaControls.insertOne({_id:'before',app:EJSON.stringify(t.appSettings.findOne()),deployment:EJSON.stringify(t.deploymentConfigurations.findOne()),user:EJSON.stringify(t.users.findOne())});
JS
for replace in false true; do
  export MONGO_IMPORT_REPLACE_COLLECTIONS="$replace"
  import_controls
done
# An empty configuration seed must not clear an existing operator singleton.
printf '[]\n' > "$stage/myscoutee_db/appSettings.json"
printf '[]\n' > "$stage/myscoutee_db/deploymentConfigurations.json"
import_controls
mongosh --host "$MONGO_IMPORT_HOST" --quiet --file /dev/stdin <<'JS'
if(!db.getSiblingDB('admin').auth(process.env.MONGO_INITDB_ROOT_USERNAME,process.env.MONGO_INITDB_ROOT_PASSWORD))throw Error('Authentication failed');
const t=db.getSiblingDB(process.env.QA_SEED_DATABASE),before=t.qaControls.findOne({_id:'before'});
if(EJSON.stringify(t.appSettings.findOne())!==before.app)throw Error('Administrator configuration overwritten');
if(EJSON.stringify(t.deploymentConfigurations.findOne())!==before.deployment)throw Error('Deployment configuration overwritten');
if(EJSON.stringify(t.users.findOne())!==before.user)throw Error('Unrelated user changed');
print('DONE: fresh seed, normal/replacement/empty reimport preserve administrator/deployment settings and unrelated user.');
JS
'''.replace('__STAGE__', stage)
target = os.environ.get('MYSCOUTEE_TEST_MONGO_TARGET', 'monolith')
if target == 'kvm':
    import os as _runtime_context_os
    _runtime_context_os.environ.setdefault('MYSCOUTEE_BACKEND_SOURCE', str(ROOT))
    sys.path.insert(0, str(Path(_runtime_context_os.environ.get('MYSCOUTEE_MICROSERVICES_SOURCE', (ROOT).parent / 'myscoutee-microservices')) / 'tools'))
    import workloads as w
    import mongo_replica
    w.namespace_owned()
    host = w.CONFIG['databases']['replicaSet'] + '/mongodb:27017,mongodb-secondary:27017' if w.CONFIG.get('mongoReplicaSet') else '127.0.0.1'
    result = w.kube('-n', w.NAMESPACE, 'exec', '-i', mongo_replica.member_target(), '--',
                    'env', 'QA_SEED_DATABASE=' + identifier, 'MONGO_IMPORT_HOST=' + host,
                    'bash', '-s', data=script, check=False, timeout=120)
else:
    if target != 'monolith': raise ValueError('Unknown Mongo test target')
    container = os.environ['MYSCOUTEE_TEST_MONGO_CONTAINER']
    result = subprocess.run(['docker', 'exec', '-i', '-e', 'QA_SEED_DATABASE=' + identifier,
                             '-e', 'MONGO_IMPORT_HOST=127.0.0.1', container, 'bash', '-s'],
                            input=script, text=True, capture_output=True, timeout=120)
print(result.stdout, end='')
if result.returncode:
    print(result.stderr, file=sys.stderr, end='')
    raise SystemExit(result.returncode)
