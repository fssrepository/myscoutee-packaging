#!/usr/bin/env python3
"""Exercise the real help migration in a disposable DB on an existing QA Mongo."""
import json
import sys
from pathlib import Path
from pathlib import Path
import os, sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'lib'))
from mongo_test_runtime import run_mongo

root = (Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'build')
CONTRACT = json.loads((Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'config/packaging/tests/contract-inputs.json').read_text())['contracts']['default-help-migration-test']
CONTRACT_INPUTS = CONTRACT['inputs']
CONTRACT_EXPECTATIONS = CONTRACT.get('expectations', {})
source = (root.parent / CONTRACT_INPUTS['packaging_migrations_008_default_help_v3_js']).read_text()
seeds = json.loads((root.parent / CONTRACT_INPUTS['seeds_008_default_help_v3_helpCenterRevisions_json']).read_text())
current = json.loads((root.parent / CONTRACT_INPUTS['mongodb_myscoutee_db_helpCenterRevisions_json']).read_text())
current = [row for row in current if row.get('documentType') == 'help']
script = 'const packagedHelpSeeds=' + json.dumps(seeds) + ';\nconst currentHelpSeeds=' + json.dumps(current) + ';\n' + r'''
const testDb = db.getSiblingDB('qa_help_upgrade_' + new ObjectId().toHexString());
function check(value, message) { if (!value) throw Error(message); }
function migrate(db) {
    const require = () => ({readFileSync: () => JSON.stringify(packagedHelpSeeds)});
    SOURCE
}
const old = packagedHelpSeeds.filter(row => row.documentType === 'help' && row.version === 1)
    .map(row => ({...row, active: true}));
const latest = packagedHelpSeeds.filter(row => row.documentType === 'help' && row.version === 3);
function baseline() {
    testDb.helpCenterRevisions.deleteMany({});
    testDb.helpCenterRevisions.insertMany(old);
    testDb.helpCenterRevisions.insertOne({_id: 'private-policy', documentType: 'privacy', active: true, text: 'retain'});
}
try {
    testDb.helpCenterRevisions.createIndex({baseGroupId: 1, documentType: 1, lang: 1, contextKey: 1, version: -1}, {unique: true});
    testDb.users.insertOne({_id: 'retained-user', name: 'retain'});
    baseline(); migrate(testDb);
    check(testDb.helpCenterRevisions.countDocuments({documentType: 'help', version: 3, active: true}) === contractExpectations.activeHelpCount, 'HU/EN v3 not activated');
    check(testDb.helpCenterRevisions.countDocuments({documentType: 'help', version: 1, active: true}) === 0, 'old defaults still active');
    const before = EJSON.stringify(testDb.helpCenterRevisions.find().sort({_id: 1}).toArray());
    migrate(testDb);
    check(EJSON.stringify(testDb.helpCenterRevisions.find().sort({_id: 1}).toArray()) === before, 'repeat changed help');

    baseline(); testDb.helpCenterRevisions.updateOne({_id: old[0]._id}, {$set: {title: 'Operator custom help'}});
    migrate(testDb);
    check(testDb.helpCenterRevisions.findOne({_id: old[0]._id}).active === true, 'custom help deactivated');
    check(testDb.helpCenterRevisions.findOne({_id: latest.find(row => row.lang === old[0].lang)._id}).active === false, 'custom selection replaced');

    baseline(); testDb.helpCenterRevisions.updateMany({documentType: 'help'}, {$set: {active: false}});
    migrate(testDb);
    check(testDb.helpCenterRevisions.countDocuments({documentType: 'help', active: true}) === 0, 'deliberately disabled help reactivated');

    baseline(); const custom = {...latest[0], _id: 'operator-v3', title: 'Retained v3'};
    testDb.helpCenterRevisions.insertOne(custom); migrate(testDb);
    check(testDb.helpCenterRevisions.findOne({_id: custom._id}).title === custom.title, 'version collision replaced operator content');
    check(!testDb.helpCenterRevisions.findOne({_id: latest[0]._id}), 'colliding package version inserted');

    baseline(); testDb.helpCenterRevisions.insertMany(latest); migrate(testDb);
    check(testDb.helpCenterRevisions.countDocuments({documentType: 'help', version: 1, active: true}) === 0, 'interrupted migration did not finish');
    testDb.helpCenterRevisions.updateOne({_id: latest[0]._id}, {$set: {active: false}}); migrate(testDb);
    check(testDb.helpCenterRevisions.findOne({_id: latest[0]._id}).active === false, 'existing v3 selection overwritten');
    check(testDb.helpCenterRevisions.findOne({_id: 'private-policy'}).text === 'retain', 'privacy changed');
    check(testDb.users.findOne().name === 'retain', 'user changed');

    testDb.helpCenterRevisions.deleteMany({}); migrate(testDb);
    check(testDb.helpCenterRevisions.countDocuments({version: 3, active: true}) === contractExpectations.activeHelpCount, 'fresh help missing');

    // Current imports intentionally supersede v3 with v5. Running an old step
    // for the first time must preserve every current default and group selection.
    testDb.helpCenterRevisions.deleteMany({});
    testDb.helpCenterRevisions.insertMany(currentHelpSeeds);
    const currentBefore = EJSON.stringify(testDb.helpCenterRevisions.find().sort({_id: 1}).toArray());
    migrate(testDb);
    check(EJSON.stringify(testDb.helpCenterRevisions.find().sort({_id: 1}).toArray()) === currentBefore,
        'current v5 or inactive historical/group revisions changed');
    print('PASS help migration: HU/EN upgrade, fresh state, repeat, interrupted retry, custom/disabled help, version conflict, retained privacy/users and unchanged current v5/group help');
} finally { testDb.dropDatabase(); }
'''.replace('SOURCE', source)
if '--print-script' in sys.argv:
    print(script)
else:
    script = 'const contractExpectations=' + json.dumps(CONTRACT_EXPECTATIONS) + ';\n' + script
run_mongo(script)
