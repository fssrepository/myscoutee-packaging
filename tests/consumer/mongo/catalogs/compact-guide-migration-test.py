#!/usr/bin/env python3
"""Run the actual compact-guide migration against a unique disposable Mongo collections."""
import os
import json
import subprocess
from pathlib import Path
root = (Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'build')
CONTRACT = json.loads((Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'config/packaging/tests/contract-inputs.json').read_text())['contracts']['compact-guide-migration-test']
CONTRACT_INPUTS = CONTRACT['inputs']
CONTRACT_EXPECTATIONS = CONTRACT.get('expectations', {})
seed_dir = root.parent / CONTRACT_INPUTS['conf_mongodb_myscoutee_db']
revisions = json.loads((seed_dir / 'helpCenterRevisions.json').read_text())
fields = json.loads((seed_dir / 'helpCenterGuideFields.json').read_text())
source = '{\n' + (root.parent / CONTRACT_INPUTS['packaging_migrations_010_compact_explanation_guides_js']).read_text() + '\n}\n{\n' + (root.parent / CONTRACT_INPUTS['packaging_migrations_011_granular_rating_guides_js']).read_text() + '\n}'
script = 'const packagedRevisions=' + json.dumps(revisions) + '; const packagedFields=' + json.dumps(fields) + ';\n' + r'''
const prefix = 'qa_compact_guide_' + new ObjectId().toHexString() + '_';
const testDb = Object.fromEntries(['helpCenterRevisions','helpCenterGuideFields','users'].map(name => [name,db.getCollection(prefix + name)]));
function check(value, message) { if (!value) throw Error(message); }
function migrate(db) {
    const require = () => ({readFileSync: path => JSON.stringify(path.endsWith('/helpCenterGuideFields.json') ? packagedFields : packagedRevisions)});
    SOURCE
}
const targets = packagedRevisions.filter(row => row.documentType === 'explanation' && row.version === 4);
const target = targets.find(row => packagedRevisions.some(old => old.documentType === 'explanation'
    && old.version === 1 && old.contextKey === row.contextKey && old.lang === row.lang));
const old = packagedRevisions.find(row => row.documentType === 'explanation' && row.version === 1
    && row.contextKey === target.contextKey && row.lang === target.lang);
function baseline() {
    testDb.helpCenterRevisions.deleteMany({}); testDb.helpCenterGuideFields.deleteMany({});
    testDb.helpCenterRevisions.insertMany([{...old, active:true}, {_id:'privacy-retain',documentType:'privacy',active:true,title:'retain'}]);
}
try {
    testDb.helpCenterRevisions.createIndex({documentType:1,lang:1,contextKey:1,version:-1},{unique:true});
    testDb.users.insertMany([{_id:'explicit-off',guideEnabled:false},{_id:'missing-guide-setting'}]);
    const usersBefore=EJSON.stringify(testDb.users.find().sort({_id:1}).toArray());
    baseline(); migrate(testDb);
    check(testDb.helpCenterRevisions.countDocuments({documentType:'explanation',version:4,active:true})===contractExpectations.compactRevisionCount,'compact defaults missing');
    check(testDb.helpCenterGuideFields.countDocuments({})===packagedFields.length,'guide fields missing');
    check(testDb.helpCenterRevisions.findOne({_id:old._id}).active===false,'old active default retained');
    check(testDb.helpCenterGuideFields.countDocuments({id:'rating-details'})===contractExpectations.ratingGuideFieldCount,'rating guide steps missing');
    const before=EJSON.stringify(testDb.helpCenterRevisions.find().sort({_id:1}).toArray());
    migrate(testDb);check(EJSON.stringify(testDb.helpCenterRevisions.find().sort({_id:1}).toArray())===before,'repeat changed revisions');
    baseline();testDb.helpCenterRevisions.updateOne({_id:old._id},{$set:{title:'Operator custom'}});migrate(testDb);
    check(testDb.helpCenterRevisions.findOne({_id:old._id}).active===true,'custom default deactivated');
    check(testDb.helpCenterRevisions.findOne({_id:target._id}).active===false,'custom selection replaced');
    baseline();testDb.helpCenterRevisions.updateOne({_id:old._id},{$set:{active:false}});migrate(testDb);
    check(testDb.helpCenterRevisions.findOne({_id:target._id}).active===false,'explicit inactive choice replaced');
    baseline();testDb.helpCenterRevisions.insertOne({...target,_id:'operator-v4',title:'Custom v4'});migrate(testDb);
    check(!testDb.helpCenterRevisions.findOne({_id:target._id}),'operator version collision overwritten');
    baseline();testDb.helpCenterRevisions.insertOne(target);migrate(testDb);
    check(testDb.helpCenterRevisions.findOne({_id:old._id}).active===false,'interrupted insertion not completed');
    check(testDb.helpCenterRevisions.findOne({_id:'privacy-retain'}).title==='retain','privacy changed');
    check(EJSON.stringify(testDb.users.find().sort({_id:1}).toArray())===usersBefore,'user preferences changed');
    testDb.helpCenterRevisions.deleteMany({});migrate(testDb);
    check(testDb.helpCenterRevisions.countDocuments({version:4,active:true})===contractExpectations.compactRevisionCount,'fresh installation incomplete');
    print('PASS compact guides: defaults, fresh install, retry, interrupted migration, custom/inactive/version collision, guide-field indexes, retained users/privacy.');
} finally { Object.values(testDb).forEach(collection => collection.drop()); }
'''.replace('SOURCE', source)
script = 'const contractExpectations=' + json.dumps(CONTRACT_EXPECTATIONS) + ';\n' + script
subprocess.run(['docker','exec','-i','mongodb','sh','-c',
    'exec mongosh --quiet --username "$MONGO_APP_USERNAME" --password "$MONGO_APP_PASSWORD" '
    '--authenticationDatabase "$MONGO_APP_DATABASE" "$MONGO_APP_DATABASE" --file /dev/stdin'],input=script,text=True,check=True)
