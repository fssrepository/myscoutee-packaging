#!/usr/bin/env python3
"""Verify the demo-only migration using a disposable database on existing Mongo."""
import os
import json
import subprocess
import sys
from pathlib import Path
root = (Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'build')
CONTRACT = json.loads((Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'config/packaging/tests/contract-inputs.json').read_text())['contracts']['demo-profile-details-migration-test']
CONTRACT_INPUTS = CONTRACT['inputs']
CONTRACT_EXPECTATIONS = CONTRACT.get('expectations', {})
source = (root.parent / CONTRACT_INPUTS['packaging_migrations_009_demo_profile_details_js']).read_text()
seeds = json.loads((root.parent / CONTRACT_INPUTS['mongodb_demo_db_users_json']).read_text())
script = 'const seeds=EJSON.parse(' + json.dumps(json.dumps(seeds)) + ');\n' + r'''
const testDb = db.getSiblingDB('qa_demo_details_' + new ObjectId().toHexString());
function check(ok, message) { if (!ok) throw Error(message); }
function migrate(name) {
    const db = {getName: () => name, users: testDb.users};
    const require = () => ({readFileSync: () => EJSON.stringify(seeds)});
    SOURCE
}
try {
    const candidates = seeds.filter(row => row.profileDetails?.length);
    testDb.users.insertMany(candidates.map(({profileDetails, ...row}) => row));
    const initial = EJSON.stringify(testDb.users.find().sort({_id:1}).toArray());
    migrate('production_db');
    check(initial === EJSON.stringify(testDb.users.find().sort({_id:1}).toArray()), 'production data changed');
    testDb.users.updateOne({_id:candidates[0]._id}, {$set:{profileDetails:[]}});
    testDb.users.updateOne({_id:candidates[1]._id}, {$set:{profileDetails:[{title:'Custom',rows:[]}]}});
    testDb.users.updateOne({_id:candidates[2]._id}, {$set:{name:'Retained custom name'}});
    migrate('demo_db');
    check(testDb.users.findOne({_id:candidates[0]._id}).profileDetails.length === 0, 'explicit empty overwritten');
    check(testDb.users.findOne({_id:candidates[1]._id}).profileDetails[0].title === 'Custom', 'custom overwritten');
    check(!testDb.users.findOne({_id:candidates[2]._id}).profileDetails, 'renamed profile changed');
    for (const seed of candidates.slice(3)) {
        check(EJSON.stringify(testDb.users.findOne({_id:seed._id}).profileDetails) === EJSON.stringify(seed.profileDetails), 'seed mismatch');
    }
    const after = EJSON.stringify(testDb.users.find().sort({_id:1}).toArray());
    migrate('demo_db');
    check(after === EJSON.stringify(testDb.users.find().sort({_id:1}).toArray()), 'repeat changed data');
    check(testDb.users.countDocuments({}) === 50, 'unexpected user insertion');
    print('PASS demo profile migration:47 initialized, empty/custom/renamed retained, production unchanged, repeat exact');
} finally { testDb.dropDatabase(); }
'''.replace('SOURCE', source)
if '--print-script' in sys.argv:
    print(script)
else:
    subprocess.run(['docker', 'exec', '-i', 'mongodb', 'sh', '-c',
        'exec mongosh --quiet --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" '
        '--authenticationDatabase admin production_db --file /dev/stdin'], input=script, text=True, check=True)
