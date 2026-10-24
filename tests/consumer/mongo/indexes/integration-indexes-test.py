#!/usr/bin/env python3
"""Exercise integration indexes on disposable databases in the existing runtime."""
import json
from pathlib import Path
import re
import os, sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'lib'))
from mongo_test_runtime import run_mongo

root = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()
case = json.loads((root / 'config/packaging/tests/integration-indexes.json').read_text())
mongo = root / 'server/docker/conf/mongodb'
migration = (root / 'config/packaging/migrations/012-integration-indexes.js').read_text()
policy = (mongo / 'mongo-seed-policy.inc').read_text()
branch = policy[policy.index('    integrationTokens|'):policy.index('    users)', policy.index('    integrationTokens|'))]
seed = branch.split('--eval "\n', 1)[1].split('\n" >/dev/null', 1)[0]
bootstrap = '\n'.join(line.strip().replace('portalDb.', 'db.') for line in
    (mongo / 'db_init.js').read_text().splitlines()
    if re.match(r'\s*portalDb\.(' + '|'.join(re.escape(name) for name in case['collections']) + r')\.createIndex\(', line))
assert bootstrap.count('.createIndex(') == case['indexCount']
assert 'ensure_collection_indexes "${target_db}" "integrationTokens"' in policy.split('ensure_runtime_indexes() {', 1)[1]
sources = {'fresh-init': bootstrap, 'seed-runtime-indexes': seed, 'retained-migration': migration}
script = 'const testCase=' + json.dumps(case) + ';\nconst sources={' + ',\n'.join(json.dumps(name) + ': function(db){\n' + source + '\n}'
    for name, source in sources.items()) + '};\n' + r'''
const prefix='qa_indexes_'+new ObjectId().toHexString()+'_';
const names=testCase.collections;
function check(ok,message){if(!ok)throw Error(message);}
let reference;
for(const [path,execute] of Object.entries(sources)) {
 const target=db.getSiblingDB(prefix+path.replaceAll('-','_'));
 try {
  const tokens=target.integrationTokens;
  tokens.insertMany(Array.from({length:128},(_,i)=>({_id:'key-'+i,tokenHash:'hash-'+i,
   ownerUserId:'owner-'+i,createdAtIso:'2026-01-01T00:00:00Z',preserve:'credential-metadata'})));
  for(const name of names.slice(1))target.getCollection(name).insertOne({_id:'retained',
   ownerUserId:'owner',expiresAt:new Date(Date.now()+86400000),deleteAfter:new Date(Date.now()+86400000),preserve:'data'});
  const snapshot=()=>names.map(name=>EJSON.stringify(target.getCollection(name).find().sort({_id:1}).toArray()));
  const before=snapshot();
  check(tokens.find({tokenHash:'hash-64'}).explain('executionStats').executionStats.totalDocsExamined===128,'unindexed baseline');
  execute(target);execute(target);
  check(JSON.stringify(snapshot())===JSON.stringify(before),path+': documents changed');
  const indexes=names.map(name=>target.getCollection(name).getIndexes().sort((a,b)=>a.name.localeCompare(b.name)));
  check(indexes.reduce((count,rows)=>count+rows.length-1,0)===testCase.indexCount,path+': missing indexes');
  if(reference)check(EJSON.stringify(indexes)===reference,path+': initialization/migration definitions differ');
  else reference=EJSON.stringify(indexes);
  check(indexes[0].find(i=>i.name==='integration_token_hash')?.unique===true,'hash must remain unique');
  for(const [collection,index] of testCase.ttlIndexes)
   check(indexes[collection].find(i=>i.name===index)?.expireAfterSeconds===0,'TTL changed');
  const query=tokens.find({tokenHash:'hash-64'}).explain('executionStats');
  check(query.executionStats.totalDocsExamined===1,'key lookup must examine one document');
  check(JSON.stringify(query.queryPlanner.winningPlan).includes('integration_token_hash'),'key lookup must use its index');
  target.dropDatabase();execute(target);
  if(testCase.rejectUnselectedCollections)check(JSON.stringify(target.getCollectionNames().sort())===JSON.stringify([...names].sort()),'unselected product collection created');
  check(names.every(name=>target.getCollection(name).countDocuments({})===0),'fresh database has invented data');
  target.dropDatabase();tokens.insertMany([{_id:'a',tokenHash:'duplicate'},{_id:'b',tokenHash:'duplicate'}]);
  let rejected=false;try{execute(target);}catch(error){rejected=error.code===11000;}
  check(rejected,'duplicate credentials must stop migration');
  check(tokens.countDocuments({})===2,'conflicting credentials were removed');
  print('PASS '+path+': '+testCase.indexCount+' indexes; retained data; repeat; empty database; duplicate refusal; lookup 128 -> 1 documents.');
 } finally { target.dropDatabase(); }
}
'''
run_mongo(script)
