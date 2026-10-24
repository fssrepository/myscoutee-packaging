import { readFileSync as _readContractInputs } from 'node:fs';
import { pathToFileURL as _contractFileURL } from 'node:url';
import { resolve as _contractResolve } from 'node:path';
// Validate pinned release coverage; optionally emit real-Mongo regression checks.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { isDeepStrictEqual } from 'node:util';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = _contractFileURL(_contractResolve(process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT ?? process.cwd()) + '/');
const contract = JSON.parse(_readContractInputs(new URL('config/packaging/tests/contract-inputs.json', root), 'utf8')).contracts["four-language-content-test"];
const contractInputs = contract.inputs;
const contractExpectations = contract.expectations ?? {};
const read = path => JSON.parse(fs.readFileSync(new URL(path, root), 'utf8'));
const updates = read(contractInputs["seeds_020_four_language_content_catalog_updates_json"]);
const current = read(contractInputs["mongodb_myscoutee_db_helpCenterRevisions_json"]);
const successor = read(contractInputs["seeds_021_location_setup_guidance_catalog_updates_json"]);
const upgraded = new Map(updates.previousRevisions.map(row => [row._id, row]));
for (const row of updates.addedRevisions) {
    assert.ok(!upgraded.has(row._id));
    upgraded.set(row._id, row);
}
for (const {previous, target} of updates.revisionUpdates) {
    assert.ok(isDeepStrictEqual(upgraded.get(previous._id), previous));
    upgraded.set(target._id, target);
}
for (const row of successor.previousRevisions) assert.ok(isDeepStrictEqual(upgraded.get(row._id), row), row._id);
// The full retained chain owns comparison with today's content; migration020
// must keep its historical target after later guide and image corrections.
execFileSync(process.execPath, [fileURLToPath(new URL('./release-catalog-parity-test.mjs', import.meta.url))]);
for (const name of ['helpCenterRevisions', 'helpCenterGuideFields', 'ideaPosts', 'emailTemplates', 'notificationTemplates']) {
    const expected = read(contractInputs["conf_mongodb_myscoutee_db"] + name + '.json');
    for (const database of ['demo_db', 'e2e_db']) {
        assert.ok(isDeepStrictEqual(read(contractInputs["docker_conf_mongodb"] + database + '/' + name + '.json'), expected), name + ': ' + database);
    }
}
if (!process.argv.includes('--print-script')) {
    console.log('PASS: migration020 pinned content, successor baseline and current three-mode catalog parity.');
    process.exit(0);
}
const migration = fs.readFileSync(new URL(contractInputs["packaging_migrations_020_four_language_content_js"], root), 'utf8');
console.log(`
const fs=require('fs');
const directory='/tmp/myscoutee-content-20261019';
const updates=EJSON.parse(fs.readFileSync(directory+'/migrations/seeds/020-four-language-content/catalog-updates.json','utf8'));
const current=EJSON.parse(${JSON.stringify(JSON.stringify([...upgraded.values()]))});
const dbTest=db.getSiblingDB('qa_four_languages_'+new ObjectId().toHexString());
const names=['helpCenterRevisions','helpCenterGuideFields','ideaPosts','emailTemplates','notificationTemplates'];
const scope=row=>JSON.stringify([row.baseGroupId??null,row.documentType,row.lang,row.contextKey??null]);
const canonical=value=>Array.isArray(value)?value.map(canonical):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])])):value;
const stable=value=>EJSON.stringify(canonical(value));
function check(ok,message){if(!ok)throw Error(message);}
function snapshot(name){return EJSON.stringify(dbTest.getCollection(name).find().sort({_id:1}).toArray());}
function migrate(){
 db=dbTest;
 process.env.MYSCOUTEE_MIGRATION_DIRECTORY=directory+'/migrations';
 process.env.MYSCOUTEE_MIGRATION_SEED_DIRECTORY=directory+'/migrations/seeds/020-four-language-content';
 { ${migration} }
}
const next=updates.addedRevisions.find(row=>row.active&&updates.previousRevisions.some(old=>old.active&&scope(old)===scope(row)&&old.version<row.version));
const previous=updates.previousRevisions.find(row=>row.active&&scope(row)===scope(next));
try{
 dbTest.helpCenterRevisions.createIndex({baseGroupId:1,documentType:1,lang:1,contextKey:1,version:-1},{unique:true});
 dbTest.helpCenterGuideFields.createIndex({screenKey:1,id:1},{unique:true});
 for(const entry of updates.addedCatalogs)dbTest.getCollection(entry.collection).createIndex(Object.fromEntries(entry.identityFields.map(key=>[key,1])),{unique:true});
 dbTest.users.insertOne({_id:'retain-user',guideEnabled:false});
 dbTest.privacyConsents.insertOne({_id:'retain-consent',version:5});
 dbTest.deploymentConfigurations.insertOne({_id:'deployment-configuration',schemaVersion:5,version:99});
 const controls=['users','privacyConsents','deploymentConfigurations'].map(name=>[name,snapshot(name)]);
 for(const mode of ['default','custom','inactive','collision','interrupted','fresh']){
  for(const name of names)dbTest.getCollection(name).deleteMany({});
  if(mode!=='fresh')dbTest.helpCenterRevisions.insertMany(updates.previousRevisions);
  if(mode==='custom')dbTest.helpCenterRevisions.updateOne({_id:previous._id},{$set:{title:'Operator guide'}});
  if(mode==='inactive')dbTest.helpCenterRevisions.updateOne({_id:previous._id},{$set:{active:false}});
  if(mode==='collision')dbTest.helpCenterRevisions.insertOne({...next,_id:'operator-collision',title:'Operator guide'});
  if(mode==='interrupted')dbTest.helpCenterRevisions.insertOne(next);
  if(mode==='custom')for(const entry of updates.addedCatalogs)dbTest.getCollection(entry.collection).insertOne({...entry.rows[0],_id:'operator-'+entry.collection,title:'Operator text',active:false});
  dbTest.helpCenterGuideFields.insertOne({_id:'custom-field',screenKey:'custom',id:'custom'});
  migrate();
  if(mode==='default'){
   for(const row of current)check(stable(dbTest.helpCenterRevisions.findOne({_id:row._id}))===stable(row),'current revision differs: '+row._id);
   check(dbTest.helpCenterRevisions.countDocuments({active:true})===current.filter(row=>row.active).length,'obsolete history remains active');
  }
  if(mode==='custom'||mode==='inactive')check(dbTest.helpCenterRevisions.findOne({_id:next._id}).active===false,'custom/inactive selection replaced');
  if(mode==='custom'){
   check(dbTest.helpCenterRevisions.findOne({_id:previous._id}).title==='Operator guide','custom help overwritten');
   for(const entry of updates.addedCatalogs){check(!dbTest.getCollection(entry.collection).findOne({_id:entry.rows[0]._id}),'semantic duplicate inserted');check(dbTest.getCollection(entry.collection).findOne({_id:'operator-'+entry.collection}).title==='Operator text','custom catalog overwritten');}
  }
  if(mode==='collision')check(!dbTest.helpCenterRevisions.findOne({_id:next._id}),'version collision overwritten');
  if(mode==='interrupted')check(!dbTest.helpCenterRevisions.findOne({_id:previous._id}).active&&dbTest.helpCenterRevisions.findOne({_id:next._id}).active,'interrupted activation incomplete');
  check(dbTest.helpCenterGuideFields.findOne({_id:'custom-field'}),'custom metadata removed');
  for(const lang of ${JSON.stringify(contractExpectations.additionalLanguages)})check(dbTest.helpCenterRevisions.countDocuments({lang,active:true})===current.filter(row=>row.lang===lang&&row.active).length,'missing translated active scopes: '+lang);
  const before=names.map(name=>[name,snapshot(name)]);migrate();for(const [name,value] of before)check(snapshot(name)===value,'retry changed '+name);
  print('PASS migration020: '+mode+', four-language scopes, retry and retained operator choices');
 }
 for(const [name,value]of controls)check(snapshot(name)===value,'retained user data changed: '+name);
 print('PASS migration020: users, consents and deployment configuration retained');
}finally{dbTest.dropDatabase();}
`);
