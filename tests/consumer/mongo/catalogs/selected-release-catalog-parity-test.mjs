import { readFileSync as _readContractInputs } from 'node:fs';
import { pathToFileURL as _contractFileURL } from 'node:url';
import { resolve as _contractResolve } from 'node:path';
// Emit real-Mongo regression checks for the existing running deployment.
import assert from 'node:assert/strict';
import fs from 'node:fs';
const root = _contractFileURL(_contractResolve(process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT ?? process.cwd()) + '/');
const contract = JSON.parse(_readContractInputs(new URL('config/packaging/tests/contract-inputs.json', root), 'utf8')).contracts["selected-release-catalog-parity-test"];
const contractInputs = contract.inputs;
const contractExpectations = contract.expectations ?? {};
const migration = fs.readFileSync(new URL(contractInputs["packaging_migrations_016_release_catalog_parity_js"],root),'utf8');
const files = Object.fromEntries(['catalog-defaults','helpCenterRevisions','helpCenterGuideFields'].map(name=>[
  name, fs.readFileSync(new URL(contractInputs["migrations_seeds_016_release_catalog_parity"]+name+'.json',root),'utf8')
]));
const guideMigration = fs.readFileSync(new URL(contractInputs["packaging_migrations_017_retained_guide_controls_js"],root),'utf8');
const guideUpdates = fs.readFileSync(new URL(contractInputs["seeds_017_retained_guide_controls_guide_field_updates_json"],root),'utf8');
const updates = JSON.parse(guideUpdates);
const upgradedFields = new Map(JSON.parse(files.helpCenterGuideFields).map(row => [row._id,row]));
for (const row of updates.fields) upgradedFields.set(row._id,row);
for (const id of updates.removedIds) upgradedFields.delete(id);
const currentFields = JSON.parse(fs.readFileSync(new URL(contractInputs["mongodb_myscoutee_db_helpCenterGuideFields_json"],root),'utf8'));
assert.deepEqual([...upgradedFields.values()].sort((a,b)=>a._id.localeCompare(b._id)),currentFields.sort((a,b)=>a._id.localeCompare(b._id)));
const upgradedRevisions = new Map(JSON.parse(files.helpCenterRevisions).map(row => [row._id,row]));
for (const {previous,target} of updates.revisions) { assert.deepEqual(upgradedRevisions.get(previous._id),previous); upgradedRevisions.set(target._id,target); }
const currentRevisions = JSON.parse(fs.readFileSync(new URL(contractInputs["mongodb_myscoutee_db_helpCenterRevisions_json"],root),'utf8'));
assert.deepEqual([...upgradedRevisions.values()].sort((a,b)=>a._id.localeCompare(b._id)),currentRevisions.sort((a,b)=>a._id.localeCompare(b._id)));
for (const row of JSON.parse(files['catalog-defaults'])) {
  assert.deepEqual(row.rows,JSON.parse(fs.readFileSync(new URL(contractInputs["conf_mongodb_myscoutee_db"]+row.collection+'.json',root),'utf8')));
}
if (!process.argv.includes('--print-script')) {
  console.log('PASS: pinned catalog upgrade inputs match every selected current production seed.');
} else console.log(`
const inputs=${JSON.stringify(files)};
const catalogs=EJSON.parse(inputs['catalog-defaults']);
const seeds=EJSON.parse(inputs.helpCenterRevisions);
const fields=${JSON.stringify(currentFields)};
const target=db.getSiblingDB('qa_release_catalogs_'+new ObjectId().toHexString());
const names=[...catalogs.map(row=>row.collection),'helpCenterRevisions','helpCenterGuideFields'];
const scope=row=>JSON.stringify([row.baseGroupId??null,row.documentType,row.lang,row.contextKey??null]);
const snapshot=name=>EJSON.stringify(target.getCollection(name).find().sort({_id:1}).toArray());
function check(ok,message){if(!ok)throw Error(message);}
const canonical=value=>Array.isArray(value)?value.map(canonical):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])])):value;
function migrate(db){
 const process={env:{MYSCOUTEE_MIGRATION_SEED_DIRECTORY:'/pinned'}};
 const require=()=>({readFileSync:path=>inputs[path.split('/').pop().replace(/\\.json$/,'')]});
 { ${migration} }
 { const require=()=>({readFileSync:()=>${JSON.stringify(guideUpdates)}}); ${guideMigration} }
}
function empty(){for(const name of names)target.getCollection(name).deleteMany({});}
try {
 target.users.insertOne({_id:'retained-user',guideEnabled:false});
 target.privacyConsents.insertOne({_id:'retained-consent',version:7});
 target.deploymentConfigurations.insertOne({_id:'deployment-configuration',schemaVersion:5,version:9,operatorSetting:'retained'});
 const controls=['users','privacyConsents','deploymentConfigurations'].map(name=>[name,snapshot(name)]);
 target.helpCenterRevisions.createIndex({baseGroupId:1,documentType:1,lang:1,contextKey:1,version:-1},{unique:true});
 target.helpCenterGuideFields.createIndex({screenKey:1,id:1},{unique:true});
 for(const row of catalogs){
  target.getCollection(row.collection).createIndex(Object.fromEntries(row.identityFields.map(key=>[key,1])),{unique:true});
 }
 migrate(target);
 for(const row of catalogs)check(target.getCollection(row.collection).countDocuments({})===row.rows.length,'fresh catalog missing: '+row.collection);
 check(target.helpCenterRevisions.countDocuments({})===seeds.length,'fresh help incomplete');
 check(target.helpCenterRevisions.countDocuments({active:true})===seeds.filter(row=>row.active).length,'active help differs');
 check(target.helpCenterGuideFields.countDocuments({})===fields.length,'guide fields incomplete');
 for(const row of ${JSON.stringify(currentRevisions)})check(EJSON.stringify(canonical(target.helpCenterRevisions.findOne({_id:row._id})))===EJSON.stringify(canonical(row)),'current help differs: '+row._id);
 const first=names.map(name=>[name,snapshot(name)]);migrate(target);
 for(const [name,before] of first)check(snapshot(name)===before,'repeat changed '+name);
 print('PASS: complete fresh selected catalogs and repeated upgrade');

 empty();
 for(const row of catalogs){
  const seed=row.rows[0];
  target.getCollection(row.collection).insertOne({...seed,_id:'operator-'+row.collection,active:false,enabled:false,title:'Operator override'});
 }
 const customized=catalogs.map(row=>[row.collection,snapshot(row.collection)]);
 const activeSeed=seeds.find(row=>row.active && row.documentType==='explanation');
 const inactive={...activeSeed,active:false};
 target.helpCenterRevisions.insertOne(inactive);
 target.helpCenterGuideFields.insertOne({_id:'custom-field',screenKey:'custom',id:'custom'});
 migrate(target);
 for(const row of catalogs){
  check(!target.getCollection(row.collection).findOne({_id:row.rows[0]._id}),'semantic operator duplicate inserted: '+row.collection);
  check(target.getCollection(row.collection).findOne({_id:'operator-'+row.collection}).enabled===false,'operator setting overwritten');
 }
 check(target.helpCenterRevisions.findOne({_id:activeSeed._id}).active===false,'inactive choice reactivated');
 check(target.helpCenterGuideFields.findOne({_id:'custom-field'}).id==='custom','custom field removed');
 print('PASS: operator semantic identities, disabled defaults and custom guide fields retained');

 empty();
 const collision={...activeSeed,_id:'operator-revision',title:'Operator guide'};
 target.helpCenterRevisions.insertOne(collision);migrate(target);
 check(!target.helpCenterRevisions.findOne({_id:activeSeed._id}),'operator revision collision overwritten');
 check(target.helpCenterRevisions.findOne({_id:collision._id}).title===collision.title,'operator content changed');

 const newer={...activeSeed,_id:'operator-newer',version:activeSeed.version+1};
 empty();target.helpCenterRevisions.insertOne(newer);migrate(target);
 check(target.helpCenterRevisions.findOne({_id:newer._id}).active===true,'newer revision deactivated');
 check(target.helpCenterRevisions.findOne({_id:activeSeed._id}).active===false,'newer revision downgraded');
 print('PASS: operator revision collisions and newer active revisions retained');

 const next=seeds.find(row=>row.active && seeds.some(old=>scope(old)===scope(row)&&old.version<row.version));
 if(next){
  const previous=seeds.find(row=>scope(row)===scope(next)&&row.version<next.version);
  for(const mode of ['default','custom','inactive','interrupted']){
   empty();const old={...previous,active:mode!=='inactive',...(mode==='custom'?{title:'Operator custom'}:{})};
   target.helpCenterRevisions.insertOne(old);
   if(mode==='interrupted')target.helpCenterRevisions.insertOne(next);
   migrate(target);
   const shouldActivate=mode==='default'||mode==='interrupted';
   check(target.helpCenterRevisions.findOne({_id:next._id}).active===shouldActivate,'wrong activation for '+mode);
   check(target.helpCenterRevisions.findOne({_id:old._id}).active===(mode==='custom'),'wrong old selection for '+mode);
  }
  print('PASS: older defaults, customization, explicit inactive selection and interrupted upgrade');
 }
 for(const {previous,next} of ${JSON.stringify(updates.revisions.map(row=>({previous:row.previous,next:row.target})) )}){
  for(const override of [{title:'Operator introduction'},{active:false}]){
   empty();const retained={...previous,...override};target.helpCenterRevisions.insertOne(retained);migrate(target);
   check(EJSON.stringify(canonical(target.helpCenterRevisions.findOne({_id:previous._id})))===EJSON.stringify(canonical(retained)),'landing introduction override changed');
  }
 }
 print('PASS: revised landing guide preserves operator text and inactive choices');
 for(const [name,before] of controls)check(snapshot(name)===before,'retained control changed: '+name);
 print('PASS: retained users, consents and deployment configuration; test database only');
}finally{target.dropDatabase();}
`);
