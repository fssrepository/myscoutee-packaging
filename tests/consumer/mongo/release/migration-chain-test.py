#!/usr/bin/env python3
"""Emit a real Mongo chain test for an existing local/remote QA container."""
import os
from pathlib import Path
import json
root=(Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'build')
CONTRACT = json.loads((Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'config/packaging/tests/contract-inputs.json').read_text())['contracts']['migration-chain-test']
CONTRACT_INPUTS = CONTRACT['inputs']
CONTRACT_EXPECTATIONS = CONTRACT.get('expectations', {})
sources={p.name:p.read_text() for p in (root.parent / 'config/packaging/migrations').glob('*.js')}
inputs={str(p.relative_to(root.parent / 'config/packaging/migrations')):p.read_text() for p in (root.parent / CONTRACT_INPUTS['packaging_migrations_seeds']).glob('*/*.json')}
runner=(root.parent/'build/scripts/run-data-migrations.js').read_text()
print('const sources='+json.dumps(sources)+';')
print('const inputs='+json.dumps(inputs)+';')
print('const runner='+json.dumps(runner)+';')
print('const helpSeeds='+json.dumps(json.loads((root.parent/CONTRACT_INPUTS['mongodb_myscoutee_db_helpCenterRevisions_json']).read_text()))+';')
print('const guideFields='+json.dumps(json.loads((root.parent/CONTRACT_INPUTS['mongodb_myscoutee_db_helpCenterGuideFields_json']).read_text()))+';')
print(r'''
const fs=require('fs');
const root=fs.mkdtempSync('/tmp/qa-migration-chain-');
fs.mkdirSync(root+'/migrations');fs.mkdirSync(root+'/seeds');
fs.writeFileSync(root+'/runner.js',runner);
fs.writeFileSync(root+'/seeds/deploymentConfigurations.json',JSON.stringify([{_id:'deployment-configuration',payment:{exchangeRateUrl:'https://rates.example/daily'}}]));
fs.writeFileSync(root+'/seeds/helpCenterRevisions.json',JSON.stringify(helpSeeds));
fs.writeFileSync(root+'/seeds/helpCenterGuideFields.json',JSON.stringify(guideFields));
process.env.MYSCOUTEE_MIGRATION_DIRECTORY=root+'/migrations';
process.env.MYSCOUTEE_MIGRATION_SEED_DIRECTORY=root+'/seeds';
function run(database){
 for(const [name,source] of Object.entries(sources))fs.writeFileSync(root+'/migrations/'+name,source);
 for(const [name,source] of Object.entries(inputs)){
  fs.mkdirSync(require('path').dirname(root+'/migrations/'+name),{recursive:true});
  fs.writeFileSync(root+'/migrations/'+name,source);
 }
 db=database;load(root+'/runner.js');
}
function check(ok,msg){if(!ok)throw Error(msg);}
try{
for(const schema of [3,4,5]){
 const d=db.getSiblingDB('qa_chain_'+new ObjectId().toHexString());
 try{
  d.deploymentConfigurations.insertOne({_id:'deployment-configuration',schemaVersion:schema,version:7,payment:{credentialEnvelope:'retain'},...(schema===5?{integration:{publicBaseUrl:'custom'}}:{})});
  run(d);check(d.schemaMigrations.countDocuments({})===Object.keys(sources).length,'missing migration receipts');
  check(d.deploymentConfigurations.findOne().schemaVersion===5,'schema not migrated');
  check(d.helpCenterRevisions.countDocuments({documentType:'help',version:5,active:true,lang:{$in:['en','hu']}})===6,'current HU/EN v5 help missing after upgrade');
  check(d.helpCenterRevisions.countDocuments({documentType:'help',version:{$lt:5},active:true})===0,'obsolete help still active after upgrade');
  check(process.env.MYSCOUTEE_MIGRATION_SEED_DIRECTORY===root+'/seeds','release seed directory not restored');
  check(d.schemaMigrations.findOne({_id:'008-default-help-v3'}).seedSha256.length===64,'pinned input checksum missing');
  check(d.schemaMigrations.findOne({_id:'013-default-help-v5'}).seedSha256.length===64,'v5 input checksum missing');
  const before=EJSON.stringify(d.deploymentConfigurations.findOne());
  run(d);check(EJSON.stringify(d.deploymentConfigurations.findOne())===before,'repeat changed data');
  const id=Object.keys(sources).sort()[1];sources[id]+='\n// tampered';let rejected=false;
  try{run(d);}catch(e){rejected=true;}check(rejected,'applied migration modification accepted');sources[id]=sources[id].replace('\n// tampered','');
  const input=Object.keys(inputs)[0],original=inputs[input];inputs[input]+='\n';rejected=false;
  try{run(d);}catch(e){rejected=e.message.includes('Applied migration seeds changed:');}
  check(rejected,'applied seed modification accepted');inputs[input]=original;
  // Receipts written by released runners have no seed checksum and remain valid.
  d.schemaMigrations.updateOne({_id:'008-default-help-v3'},{$unset:{seedSha256:''}});
  const legacy=EJSON.stringify(d.schemaMigrations.findOne({_id:'008-default-help-v3'}));
  run(d);check(EJSON.stringify(d.schemaMigrations.findOne({_id:'008-default-help-v3'}))===legacy,'legacy receipt rewritten');
  print('PASS ordered migration chain from schema'+schema+': original inputs, repeat, source/input checksums and legacy receipts');
 }finally{d.dropDatabase();}
}
const retainedDb=db.getSiblingDB('qa_chain_retained_'+new ObjectId().toHexString());
try{
 retainedDb.deploymentConfigurations.insertOne({_id:'deployment-configuration',schemaVersion:5,version:9,payment:{credentialEnvelope:'retain'}});
 retainedDb.helpCenterRevisions.insertMany(helpSeeds.filter(row=>row.documentType==='help'&&row.version===3)
  .map(row=>({...row,active:true})));
 for(const [name,source] of Object.entries(sources).filter(([name])=>name!=='013-default-help-v5.js')){
  retainedDb.schemaMigrations.insertOne({_id:name.replace(/\.js$/,''),sha256:require('crypto').createHash('sha256').update(source).digest('hex'),appliedAt:new Date('2026-10-01T00:00:00Z')});
 }
 const receiptsBefore=EJSON.stringify(retainedDb.schemaMigrations.find().sort({_id:1}).toArray());
 run(retainedDb);
 check(retainedDb.helpCenterRevisions.countDocuments({documentType:'help',version:5,active:true,lang:{$in:['en','hu']}})===6,'recorded old chain did not advance help to v5');
 check(retainedDb.helpCenterRevisions.countDocuments({documentType:'help',version:3,active:true})===0,'recorded old chain left v3 active');
 check(EJSON.stringify(retainedDb.schemaMigrations.find({_id:{$ne:'013-default-help-v5'}}).sort({_id:1}).toArray())===receiptsBefore,'old receipts changed during v5 upgrade');
 print('PASS already-recorded migrations remain unchanged; missing v5 step runs');
}finally{retainedDb.dropDatabase();}
const currentDb=db.getSiblingDB('qa_chain_current_'+new ObjectId().toHexString());
try{
 currentDb.helpCenterRevisions.insertMany(helpSeeds.filter(row=>row.documentType==='help'));
 const helpBefore=EJSON.stringify(currentDb.helpCenterRevisions.find().sort({_id:1}).toArray());
 run(currentDb);
 check(EJSON.stringify(currentDb.helpCenterRevisions.find({documentType:'help'}).sort({_id:1}).toArray())===helpBefore,'full chain changed currently seeded v5 help');
 print('PASS complete chain preserves already-seeded current v5 help');
}finally{currentDb.dropDatabase();}
const d=db.getSiblingDB('qa_chain_failure_'+new ObjectId().toHexString());
try{
 d.deploymentConfigurations.insertOne({_id:'deployment-configuration',schemaVersion:4,version:0,payment:{}});
 const id=Object.keys(sources).sort()[1],original=sources[id];sources[id]='throw Error("injected failure")';
 let failed=false;try{run(d);}catch(e){failed=true;}check(failed&&d.schemaMigrations.countDocuments({})===1,'failure did not stop chain');
 sources[id]=original;run(d);check(d.schemaMigrations.countDocuments({})===Object.keys(sources).length,'retry did not resume missing steps');
 print('PASS failed step not recorded; retry resumes and completes');
}finally{d.dropDatabase();}
const inputDb=db.getSiblingDB('qa_chain_input_'+new ObjectId().toHexString());
const input='seeds/008-default-help-v3/helpCenterRevisions.json',original=inputs[input];
try{
 inputs[input]='[]';let failed=false;
 try{run(inputDb);}catch(e){failed=e.message.includes('Missing canonical help v3 seed:');}
 check(failed&&!inputDb.schemaMigrations.findOne({_id:'008-default-help-v3'}),'invalid input recorded as applied');
 check(process.env.MYSCOUTEE_MIGRATION_SEED_DIRECTORY===root+'/seeds','failed input left seed directory changed');
 inputs[input]=original;run(inputDb);
 check(inputDb.schemaMigrations.countDocuments({})===Object.keys(sources).length,'input retry incomplete');
 print('PASS failed historical input restores release seed directory; retry completes');
}finally{inputs[input]=original;inputDb.dropDatabase();}
}finally{fs.rmSync(root,{recursive:true});}
''')
