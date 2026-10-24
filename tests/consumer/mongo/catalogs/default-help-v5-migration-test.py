#!/usr/bin/env python3
"""Verify the actual v5 help upgrade on isolated data in the running Mongo."""
import json
import sys
from pathlib import Path
from pathlib import Path
import os, sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'lib'))
from mongo_test_runtime import run_mongo

root = (Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'build')
CONTRACT = json.loads((Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'config/packaging/tests/contract-inputs.json').read_text())['contracts']['default-help-v5-migration-test']
CONTRACT_INPUTS = CONTRACT['inputs']
CONTRACT_EXPECTATIONS = CONTRACT.get('expectations', {})
source = (root.parent / CONTRACT_INPUTS['packaging_migrations_013_default_help_v5_js']).read_text()
seeds = json.loads((root.parent / CONTRACT_INPUTS['seeds_013_default_help_v5_helpCenterRevisions_json']).read_text())
script = 'const packagedHelpSeeds=' + json.dumps(seeds) + ';\n' + r'''
const testDb = db.getSiblingDB('qa_help_v5_' + new ObjectId().toHexString());
const targets = packagedHelpSeeds.filter(row => row.version === 5);
const common = row => row.baseGroupId == null;
const oldRows = version => packagedHelpSeeds.filter(row => common(row) && row.version === version)
    .map(row => ({...row, active: true}));
const snapshot = collection => EJSON.stringify(collection.find().sort({_id: 1}).toArray());
function check(ok, message) { if (!ok) throw Error(message); }
function migrate(db, input = packagedHelpSeeds) {
    const require = () => ({readFileSync: () => JSON.stringify(input)});
    SOURCE
}
const untouched = [
    {_id: 'private-policy', documentType: 'privacy', active: true, title: 'Operator privacy'},
    {_id: 'private-terms', documentType: 'terms', active: false, title: 'Operator terms'},
    {_id: 'private-guide', documentType: 'explanation', contextKey: 'custom', active: true, title: 'Custom guide'},
    {_id: 'other-group-help', baseGroupId: 'custom-group', documentType: 'help', lang: 'en', version: 2, active: true, title: 'Other group'}
];
function baseline(rows) {
    testDb.helpCenterRevisions.drop();
    testDb.helpCenterRevisions.insertMany([...rows, ...untouched]);
}
function checkUntouched() {
    for (const row of untouched) check(EJSON.stringify(testDb.helpCenterRevisions.findOne({_id: row._id})) === EJSON.stringify(row),
        'unrelated document changed: ' + row._id);
}
try {
    testDb.users.insertOne({_id: 'retained-user', guideEnabled: false, helpPreferences: {custom: true}});
    testDb.privacyConsents.insertOne({_id: 'retained-consent', version: 7});
    testDb.helpCenterGuideFields.insertOne({_id: 'retained-guide-field', screenKey: 'custom'});
    const retained = ['users', 'privacyConsents', 'helpCenterGuideFields']
        .map(name => [name, snapshot(testDb.getCollection(name))]);

    for (const version of [1, 3, 4]) {
        baseline(oldRows(version));
        testDb.helpCenterRevisions.createIndex({documentType: 1, lang: 1, contextKey: 1, version: -1},
            {name: 'help_revision_document_lang_context_version', unique: true});
        const started = Date.now(); migrate(testDb);
        for (const target of targets) check(testDb.helpCenterRevisions.findOne({_id: target._id}).active === true,
            'v' + version + ' upgrade missing active target: ' + target._id);
        for (const old of oldRows(version)) check(testDb.helpCenterRevisions.findOne({_id: old._id}).active === false,
            'obsolete default remains active');
        const indexes = testDb.helpCenterRevisions.getIndexes();
        check(indexes.some(i => i.name === 'help_revision_group_document_lang_context_version' && i.unique), 'group unique index missing');
        check(!indexes.some(i => i.name === 'help_revision_document_lang_context_version'), 'old index still blocks group help');
        const upgraded = snapshot(testDb.helpCenterRevisions); migrate(testDb);
        check(snapshot(testDb.helpCenterRevisions) === upgraded, 'repeat changed upgraded help');
        checkUntouched();
        print('PASS v' + version + ' -> v5: EN/HU and all seeded scopes, old index, repeat, retained data; update+repeat ms=' + (Date.now() - started));
    }

    baseline(oldRows(3).map(row => ({...row, title: 'Operator custom help'}))); migrate(testDb);
    for (const row of oldRows(3)) check(testDb.helpCenterRevisions.findOne({_id: row._id}).active === true, 'custom help deactivated');
    check(testDb.helpCenterRevisions.countDocuments({baseGroupId: null, version: 5, active: true}) === 0, 'custom choice replaced');
    print('PASS customized older defaults preserved; v5 offered inactive');

    baseline(oldRows(4).map(row => ({...row, active: false}))); migrate(testDb);
    check(testDb.helpCenterRevisions.countDocuments({baseGroupId: null, documentType: 'help', active: true}) === 0, 'disabled help reactivated');
    print('PASS deliberately disabled help preserved');

    const target = targets.find(row => row._id === 'help-default-v5');
    baseline([{...target, _id: 'operator-v5', title: 'Custom v5'}]); migrate(testDb);
    check(!testDb.helpCenterRevisions.findOne({_id: target._id}), 'operator version5 collision overwritten');
    check(testDb.helpCenterRevisions.findOne({_id: 'operator-v5'}).active === true, 'operator version5 deactivated');
    print('PASS version5 collision preserves operator revision');

    baseline(targets.map(row => ({...row, active: false}))); const disabled = snapshot(testDb.helpCenterRevisions);
    migrate(testDb); check(snapshot(testDb.helpCenterRevisions) === disabled, 'existing inactive v5 changed');
    baseline(targets.map(row => ({...row, title: 'Customized v5'}))); const customized = snapshot(testDb.helpCenterRevisions);
    migrate(testDb); check(snapshot(testDb.helpCenterRevisions) === customized, 'existing custom v5 changed');
    print('PASS existing inactive/custom v5 preserved in every scope');

    baseline([{...target, _id: 'operator-v6', version: 6}]); migrate(testDb);
    check(testDb.helpCenterRevisions.findOne({_id: 'operator-v6'}).active === true, 'newer help deactivated');
    check(testDb.helpCenterRevisions.findOne({_id: target._id}).active === false, 'newer help downgraded to v5');
    print('PASS newer help not downgraded');

    baseline([...oldRows(3), ...targets]); migrate(testDb);
    check(testDb.helpCenterRevisions.countDocuments({documentType: 'help', baseGroupId: null, version: 3, active: true}) === 0,
        'interrupted insertion did not finish deactivation');
    print('PASS retry completes insertion/deactivation interruption');

    baseline(packagedHelpSeeds); const current = snapshot(testDb.helpCenterRevisions);
    migrate(testDb); check(snapshot(testDb.helpCenterRevisions) === current, 'current v5 seed changed');
    print('PASS current seeded v5 is unchanged');

    baseline([]); migrate(testDb);
    check(testDb.helpCenterRevisions.countDocuments({_id: {$in: targets.map(row => row._id)}, active: true}) === contractExpectations.activeHelpCount, 'empty installation missing v5');
    print('PASS empty help installation receives all six v5 revisions');

    baseline(oldRows(3)); const before = snapshot(testDb.helpCenterRevisions); let rejected = false;
    try { migrate(testDb, packagedHelpSeeds.filter(row => row._id !== target._id)); } catch (error) {
        rejected = error.message.includes('Missing canonical help v5 seeds');
    }
    check(rejected && snapshot(testDb.helpCenterRevisions) === before, 'invalid input was not rejected before data mutation');
    checkUntouched();
    for (const [name, before] of retained) check(snapshot(testDb.getCollection(name)) === before, 'unrelated collection changed: ' + name);
    print('PASS missing seed rejected; Privacy/Terms/guides/consents/users/custom groups retained');
} finally { testDb.dropDatabase(); }
'''.replace('SOURCE', source)
if '--print-script' in sys.argv:
    print(script)
else:
    script = 'const contractExpectations=' + json.dumps(CONTRACT_EXPECTATIONS) + ';\n' + script
run_mongo(script)
