import { readFileSync as _readContractInputs } from 'node:fs';
import { pathToFileURL as _contractFileURL } from 'node:url';
import { resolve as _contractResolve } from 'node:path';
// Emit real-Mongo regression checks for the existing running deployment.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { isDeepStrictEqual } from 'node:util';
import vm from 'node:vm';
const root = _contractFileURL(_contractResolve(process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT ?? process.cwd()) + '/');
const contract = JSON.parse(_readContractInputs(new URL('config/packaging/tests/contract-inputs.json', root), 'utf8')).contracts["release-catalog-parity-test"];
const contractInputs = contract.inputs;
const contractExpectations = contract.expectations ?? {};
const inputDirectory = process.argv.find(value=>value.startsWith('--input-directory='))?.slice('--input-directory='.length);
if (process.argv.includes('--print-script')) assert.match(inputDirectory ?? '', /^\/tmp\/qa-release-catalogs-[0-9a-f]{32}$/, 'Stage the pinned JSON inputs separately and supply their owned --input-directory');
const migration = fs.readFileSync(new URL(contractInputs["packaging_migrations_016_release_catalog_parity_js"],root),'utf8');
const files = Object.fromEntries(['catalog-defaults','helpCenterRevisions','helpCenterGuideFields'].map(name=>[
  name, fs.readFileSync(new URL(contractInputs["migrations_seeds_016_release_catalog_parity"]+name+'.json',root),'utf8')
]));
const refreshMigration = fs.readFileSync(new URL(contractInputs["packaging_migrations_017_release_catalog_refresh_js"],root),'utf8');
const refreshInput = fs.readFileSync(new URL(contractInputs["seeds_017_release_catalog_refresh_catalog_updates_json"],root),'utf8');
const refresh = JSON.parse(refreshInput);
const languageRefresh = JSON.parse(fs.readFileSync(new URL(contractInputs["seeds_020_four_language_content_catalog_updates_json"],root),'utf8'));
const locationGuideRefresh = JSON.parse(fs.readFileSync(new URL(contractInputs["seeds_021_location_setup_guidance_catalog_updates_json"],root),'utf8'));
assert.ok(isDeepStrictEqual(refresh.previousRevisions, JSON.parse(files.helpCenterRevisions)), 'Refresh must recognize the immutable prior defaults');
const upgradedFields = new Map(JSON.parse(files.helpCenterGuideFields).map(row=>[row._id,row]));
for (const row of refresh.fields) upgradedFields.set(row._id,row);
for (const id of refresh.removedFieldIds) upgradedFields.delete(id);
const currentFields = JSON.parse(fs.readFileSync(new URL(contractInputs["mongodb_myscoutee_db_helpCenterGuideFields_json"],root),'utf8'));
const sorted = rows => [...rows].sort((a,b)=>a._id.localeCompare(b._id));
const languageFields = new Map(upgradedFields);
for (const row of languageRefresh.fields) languageFields.set(row._id,row);
for (const id of languageRefresh.removedFieldIds) languageFields.delete(id);
for (const row of locationGuideRefresh.fields) languageFields.set(row._id,row);
assert.ok(isDeepStrictEqual(sorted(languageFields.values()),sorted(currentFields)), 'Guide metadata refresh differs from the current production seed');
const currentGuideRevisions = JSON.parse(fs.readFileSync(new URL(contractInputs["mongodb_myscoutee_db_helpCenterRevisions_json"],root),'utf8'));
const correctedGuideRevisions = currentGuideRevisions.filter(row => row.active && row.documentType==='explanation'
  && ['landing.home','landing.setup'].includes(row.contextKey));
assert.equal(correctedGuideRevisions.length,24,'Both guide contexts must cover all four languages and three workspace scopes');
assert.ok(isDeepStrictEqual(sorted(locationGuideRefresh.addedRevisions),sorted(correctedGuideRevisions)),
  'The pinned location-guide correction differs from the current source');
assert.equal(locationGuideRefresh.previousRevisions.length,24);
assert.ok(locationGuideRefresh.previousRevisions.every(row => ['landing.home','landing.setup'].includes(row.contextKey)));
assert.deepEqual(locationGuideRefresh.fields.map(row=>row._id),['landing.home--setup-launcher']);
for (const name of ['removedFieldIds','revisionUpdates','retiredRevisions','catalogUpdates']) assert.deepEqual(locationGuideRefresh[name],[]);
const upgradedRevisions = new Map(JSON.parse(files.helpCenterRevisions).map(row=>[row._id,row]));
for (const row of refresh.addedRevisions) { assert.ok(!upgradedRevisions.has(row._id)); upgradedRevisions.set(row._id,row); }
for (const {previous,target} of refresh.revisionUpdates) {
  assert.ok(isDeepStrictEqual(upgradedRevisions.get(previous._id),previous), 'Refresh previous revision differs from the immutable baseline');
  upgradedRevisions.set(target._id,target);
}
const currentRevisions = languageRefresh.previousRevisions;
const revisionScope = row => JSON.stringify([row.baseGroupId??null,row.documentType,row.lang,row.contextKey??null]);
const currentScopes = new Set(currentRevisions.map(revisionScope));
assert.ok(isDeepStrictEqual(refresh.retiredRevisions,refresh.previousRevisions.filter(row=>!currentScopes.has(revisionScope(row)))), 'Only obsolete packaged guide scopes may be retired');
for (const row of currentRevisions) assert.ok(isDeepStrictEqual(upgradedRevisions.get(row._id),row), `Missing current revision refresh: ${row._id}`);
const upgradedCatalogs = {};
for (const row of JSON.parse(files['catalog-defaults'])) {
  const key = row => JSON.stringify(row._id);
  const upgraded = new Map(row.rows.map(value=>[key(value),value]));
  for (const update of refresh.catalogUpdates.filter(value=>value.collection===row.collection)) {
    assert.ok(isDeepStrictEqual(upgraded.get(key(update.previous)),update.previous), 'Refresh catalog baseline differs');
    upgraded.set(key(update.target),update.target);
  }
  for (const update of languageRefresh.catalogUpdates.filter(value=>value.collection===row.collection)) upgraded.set(key(update.target),update.target);
  for (const added of languageRefresh.addedCatalogs.filter(value=>value.collection===row.collection)) for (const value of added.rows) upgraded.set(key(value),value);
  upgradedCatalogs[row.collection] = [...upgraded.values()];
}
// Apply the actual new URL migration before comparing historical catalogs with
// today's seeds. Historical pinned inputs stay immutable.
const imageManifest = fs.readFileSync(new URL(contractInputs["seeds_023_seeded_image_webp_image_replacements_json"],root),'utf8');
vm.runInNewContext(fs.readFileSync(new URL(contractInputs["packaging_migrations_023_seeded_image_webp_js"],root),'utf8'), {
  require: () => ({readFileSync: () => imageManifest}),
  process: {env: {MYSCOUTEE_MIGRATION_SEED_DIRECTORY: '/pinned'}},
  EJSON: {stringify: JSON.stringify}, print: () => {},
  db: {getCollection: name => ({
    find: () => ({forEach: visit => (upgradedCatalogs[name] ?? []).forEach(visit)}),
    bulkWrite: operations => {
      for (const {updateOne: operation} of operations) {
        const row = upgradedCatalogs[name].find(value => value._id === operation.filter._id);
        for (const [field, previous] of Object.entries(operation.filter))
          assert.ok(isDeepStrictEqual(row[field],previous), 'Migration023 previous field differs');
        Object.assign(row,JSON.parse(JSON.stringify(operation.update.$set)));
      }
      return {matchedCount: operations.length, modifiedCount: operations.length};
    }
  })}
});
for (const [name, rows] of Object.entries(upgradedCatalogs))
  assert.ok(isDeepStrictEqual(sorted(rows),sorted(JSON.parse(fs.readFileSync(new URL(contractInputs["conf_mongodb_myscoutee_db"]+name+'.json',root),'utf8')))),
    `Pinned upgrade catalog differs after migration023: ${name}`);
if (!process.argv.includes('--print-script')) {
  console.log('PASS: immutable migrations016/017/020, scoped migration021 and image migration023 match the current production catalogs.');
} else console.log(`
const inputDirectory=${JSON.stringify(inputDirectory)};
const inputFs=require('fs');
const inputs=Object.fromEntries(['catalog-defaults','helpCenterRevisions','helpCenterGuideFields'].map(name=>[name,inputFs.readFileSync(inputDirectory+'/016/'+name+'.json','utf8')]));
const refreshInput=inputFs.readFileSync(inputDirectory+'/catalog-updates.json','utf8');
const catalogs=EJSON.parse(inputs['catalog-defaults']);
// Historical 016/017 checks retain their own expected catalogs after 020.
const seeds=EJSON.parse(${JSON.stringify(JSON.stringify(currentRevisions))});
const fields=EJSON.parse(${JSON.stringify(JSON.stringify([...upgradedFields.values()]))});
const target=db.getSiblingDB('qa_release_catalogs_'+new ObjectId().toHexString());
const names=[...catalogs.map(row=>row.collection),'helpCenterRevisions','helpCenterGuideFields'];
const scope=row=>JSON.stringify([row.baseGroupId??null,row.documentType,row.lang,row.contextKey??null]);
const snapshot=name=>EJSON.stringify(target.getCollection(name).find().sort({_id:1}).toArray());
function check(ok,message){if(!ok)throw Error(message);}
const canonical=value=>Array.isArray(value)?value.map(canonical):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])])):value;
const stable=value=>EJSON.stringify(canonical(value));
function migrate(db){
 const process={env:{MYSCOUTEE_MIGRATION_SEED_DIRECTORY:'/pinned'}};
 const require=()=>({readFileSync:path=>inputs[path.split('/').pop().replace(/\\.json$/,'')]});
 { ${migration} }
 { const require=()=>({readFileSync:()=>refreshInput}); ${refreshMigration} }
}
function preparePrevious(db){
 const saved=process.env.MYSCOUTEE_MIGRATION_SEED_DIRECTORY;
 try{process.env.MYSCOUTEE_MIGRATION_SEED_DIRECTORY=inputDirectory+'/016'; { ${migration} }}
 finally{if(saved===undefined)delete process.env.MYSCOUTEE_MIGRATION_SEED_DIRECTORY;else process.env.MYSCOUTEE_MIGRATION_SEED_DIRECTORY=saved;}
}
function applyRefresh(db){
 const saved=process.env.MYSCOUTEE_MIGRATION_SEED_DIRECTORY;
 try{process.env.MYSCOUTEE_MIGRATION_SEED_DIRECTORY=inputDirectory; { ${refreshMigration} }}
 finally{if(saved===undefined)delete process.env.MYSCOUTEE_MIGRATION_SEED_DIRECTORY;else process.env.MYSCOUTEE_MIGRATION_SEED_DIRECTORY=saved;}
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
 if(${process.argv.includes('--refresh-only')}){
  const refreshData=EJSON.parse(refreshInput);
  const retired=refreshData.retiredRevisions.find(row=>row.active);
  const inactive=refreshData.retiredRevisions.find(row=>!row.active);
  const corrected=refreshData.revisionUpdates.find(row=>row.previous.active&&row.target.active);
  const next=refreshData.addedRevisions.find(row=>row.active&&refreshData.previousRevisions.some(old=>old.active&&scope(old)===scope(row)&&old.version<row.version));
  const old=refreshData.previousRevisions.find(row=>row.active&&scope(row)===scope(next));
  for(const mode of ['default','custom','inactive','reactivated','interrupted','collision']){
   empty();preparePrevious(target);
   const retained=[];
   if(mode==='custom'){
    for(const id of [retired._id,corrected.previous._id])target.helpCenterRevisions.updateOne({_id:id},{$set:{title:'Operator custom guide'}});
    for(const update of refreshData.catalogUpdates){const field=update.collection==='ideaPosts'?'contentHtml':'message';target.getCollection(update.collection).updateOne({_id:update.previous._id},{$set:{[field]:'Operator custom text'}});retained.push([update.collection,update.previous._id,stable(target.getCollection(update.collection).findOne({_id:update.previous._id}))]);}
    for(const id of [retired._id,corrected.previous._id])retained.push(['helpCenterRevisions',id,stable(target.helpCenterRevisions.findOne({_id:id}))]);
   }
   if(mode==='inactive')target.helpCenterRevisions.updateOne({_id:corrected.previous._id},{$set:{active:false}});
   if(mode==='reactivated')target.helpCenterRevisions.updateOne({_id:inactive._id},{$set:{active:true}});
   if(mode==='interrupted')target.helpCenterRevisions.insertOne(next);
   if(mode==='collision'){target.helpCenterRevisions.updateMany({documentType:next.documentType,lang:next.lang,contextKey:next.contextKey,baseGroupId:next.baseGroupId??null},{$set:{active:false}});target.helpCenterRevisions.insertOne({...next,_id:'operator-version-collision',title:'Operator guide'});}
   applyRefresh(target);
   for(const [name,id,before]of retained)check(stable(target.getCollection(name).findOne({_id:id}))===before,'custom value overwritten: '+name);
   if(mode==='default')check(!target.helpCenterRevisions.findOne({_id:retired._id}).active,'removed default remains active');
   if(mode==='inactive'){const stored=target.helpCenterRevisions.findOne({_id:corrected.previous._id});check(!stored.active&&stable(stored)===stable({...corrected.target,active:false}),'inactive correction lost its selection');}
   if(mode==='reactivated')check(target.helpCenterRevisions.findOne({_id:inactive._id}).active,'operator-reactivated history disabled');
   if(mode==='interrupted')check(target.helpCenterRevisions.findOne({_id:next._id}).active&&!target.helpCenterRevisions.findOne({_id:old._id}).active,'interrupted transition did not finish');
   if(mode==='collision')check(!target.helpCenterRevisions.findOne({_id:next._id})&&target.helpCenterRevisions.findOne({_id:'operator-version-collision'}).title==='Operator guide','operator version collision replaced');
   const before=names.map(name=>[name,snapshot(name)]);applyRefresh(target);for(const[name,value]of before)check(snapshot(name)===value,'repeat changed '+mode+': '+name);
   print('PASS migration017: '+mode+', repeated execution, actual pinned files');
  }
 }else{
 migrate(target);
 for(const row of catalogs)check(target.getCollection(row.collection).countDocuments({})===row.rows.length,'fresh catalog missing: '+row.collection);
 check(target.helpCenterRevisions.countDocuments({})===${upgradedRevisions.size},'fresh help or retained history incomplete');
 for(const row of seeds){const stored=target.helpCenterRevisions.findOne({_id:row._id});check(stable(stored)===stable(row),'fresh current revision differs: '+row._id+' fields='+Object.keys(row).filter(key=>stable(stored?.[key])!==stable(row[key])).join(','));}
 check(target.helpCenterRevisions.countDocuments({active:true})===seeds.filter(row=>row.active).length,'active help differs');
 check(target.helpCenterGuideFields.countDocuments({})===fields.length,'guide fields incomplete');
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
 }
 for(const [name,before] of controls)check(snapshot(name)===before,'retained control changed: '+name);
 print('PASS: retained users, consents and deployment configuration; test database only');
}finally{target.dropDatabase();}
`);
