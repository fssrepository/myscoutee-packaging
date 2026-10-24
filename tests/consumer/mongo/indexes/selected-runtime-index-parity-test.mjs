#!/usr/bin/env node
import { readFileSync as _readContractInputs } from 'node:fs';
import { pathToFileURL as _contractFileURL } from 'node:url';
import { resolve as _contractResolve } from 'node:path';
// Validate the complete existing Mongo index contract, then emit a disposable
// runtime test for the already-running deployment's authenticated mongosh.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const root = _contractFileURL(_contractResolve(process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT ?? process.cwd()) + '/');
const contract = JSON.parse(_readContractInputs(new URL('config/packaging/tests/contract-inputs.json', root), 'utf8')).contracts["selected-runtime-index-parity-test"];
const contractInputs = contract.inputs;
const contractExpectations = contract.expectations ?? {};
const read = name => fs.readFileSync(new URL(name, root), 'utf8');
const catalog = JSON.parse(read(contractInputs["seeds_015_runtime_index_parity_runtime_indexes_json"]));
catalog.indexes.push(...JSON.parse(read(contractInputs["seeds_018_media_worker_index_runtime_indexes_json"])).indexes);
const migration = read(contractInputs["packaging_migrations_015_runtime_index_parity_js"]);
const mediaMigration = read(contractInputs["packaging_migrations_018_media_worker_index_js"]);
const mediaCatalog = JSON.parse(read(contractInputs["seeds_018_media_worker_index_runtime_indexes_json"]));
const migrated = [];
for (let attempt = 0; attempt < 2; attempt++) vm.runInNewContext(mediaMigration, {
  require: () => ({ readFileSync: () => JSON.stringify(mediaCatalog) }),
  process: { env: { MYSCOUTEE_MIGRATION_SEED_DIRECTORY: '/pinned' } },
  db: { getCollection: collection => ({ createIndex: (key, options) => migrated.push({ collection, key, options }) }) },
  print() {}
});
assert.deepEqual(JSON.parse(JSON.stringify(migrated)), [...mediaCatalog.indexes, ...mediaCatalog.indexes]);
const id = row => row.collection + '/' + row.options.name;
function definitions(source) {
  return [...source.matchAll(/(?:portalDb\.(\w+)|db\.getCollection\('([^']+)'\))\.createIndex\(([\s\S]*?)\);/g)]
    .map(match => {
      const [key, options] = JSON.parse(JSON.stringify(vm.runInNewContext('[' + match[3] + ']')));
      return { collection: match[1] || match[2], key, options };
    });
}
const fresh = definitions(read(contractInputs["conf_mongodb_db_init_js"]));
const expected = new Map(catalog.indexes.map(row => [id(row), row]));
assert.equal(new Set(fresh.map(id)).size, expected.size);
for (const row of fresh) assert.deepEqual(row, expected.get(id(row)), 'Fresh index differs: ' + id(row));
for (const row of definitions(read(contractInputs["conf_mongodb_mongo_seed_policy_inc"]))) {
  assert.deepEqual(row, expected.get(id(row)), 'DEV/import index differs: ' + id(row));
}
// Exercise the actual initializer's database selection, not only its static
// definitions: installed reset must build every index on demo_db and nowhere else.
function initialize(environment) {
  const selected = [], indexes = [];
  const collection = name => ({createIndex(key, options) {indexes.push(name + '/' + options.name);}, getIndexes:()=>[]});
  const database = new Proxy({getCollectionNames:()=>[], createCollection() {}, getUser:()=>({user:'existing'})},
    {get:(target,name)=>name in target ? target[name] : collection(name)});
  vm.runInNewContext(read(contractInputs["conf_mongodb_db_init_js"]), {
    process:{env:environment}, db:{getSiblingDB(name) {selected.push(name); return database;}}
  });
  return {selected,indexes};
}
const reset = initialize({MONGO_RESET_DATABASE:'demo_db', MONGO_REAL_DATABASE:'production_db',
  MONGO_APP_DATABASE:'production_db', MONGO_INITDB_DATABASE:'production_db', MONGO_E2E_DATABASE:'e2e_db'});
assert.deepEqual(reset.selected,['demo_db']);
assert.deepEqual(new Set(reset.indexes), new Set(expected.keys()));
for (const environment of [{MONGO_RESET_DATABASE:'production_db'}, {MONGO_RESET_DATABASE:''},
  {MONGO_RESET_DATABASE:'demo_db',MONGO_REAL_DATABASE:'demo_db'}]) {
  assert.throws(()=>initialize(environment),/Rejected Mongo initializer reset target/);
}
assert.deepEqual(initialize({MONGO_APP_DATABASE:'production_db',MONGO_E2E_DATABASE:'e2e_db'}).selected,
  ['demo_db','myscoutee_db','production_db','e2e_db']);
if (!process.argv.includes('--print-script')) {
  console.log(`PASS: all ${expected.size} fresh/runtime/upgrade index definitions agree.`);
} else {
  console.log(`
const catalog=${JSON.stringify(catalog)};
const prefix='qa_runtime_indexes_'+new ObjectId().toHexString();
const target=db.getSiblingDB(prefix);
function check(value,message){if(!value)throw Error(message);}
function initializeReset() {
 const process={env:{MONGO_RESET_DATABASE:'demo_db',MONGO_REAL_DATABASE:'production_db',
  MONGO_APP_USERNAME:prefix,MONGO_APP_PASSWORD:prefix}};
 const db={getSiblingDB(name){check(name==='demo_db','initializer selected a non-demo database');return target;}};
 ${read(contractInputs["conf_mongodb_db_init_js"])}
}
const pinnedCatalog=JSON.stringify(catalog);
function migrate(db){
 const require=()=>({readFileSync:()=>pinnedCatalog});
 const process={env:{MYSCOUTEE_MIGRATION_SEED_DIRECTORY:'/pinned'}};
 ${migration}
}
try {
 for(const retired of catalog.retiredIndexes){
  const key=retired.collection==='userRates'?{ownerUserId:1,mode:1,relatedUserId:1,secondaryRelatedUserId:1}
   :retired.collection==='helpCenterRevisions'?{documentType:1,lang:1,contextKey:1,version:-1}
   :retired.collection==='notificationRuleConfigs'||retired.collection==='emailCampaignRules'?{ruleKey:1}:{templateKey:1};
  target.getCollection(retired.collection).createIndex(key,{name:retired.name,unique:true});
 }
 target.notificationRuleConfigs.insertOne({_id:'operator-rule',ruleKey:'retained',enabled:false,version:9});
 const before=EJSON.stringify(target.notificationRuleConfigs.find().toArray());
 migrate(target);migrate(target);
 check(before===EJSON.stringify(target.notificationRuleConfigs.find().toArray()),'operator data changed');
 // Reproduce the installed reset gap, then apply the actual canonical source.
 // Only this unique test database is reachable through initializeReset().
 target.countryPartitions.dropIndexes();
 initializeReset();initializeReset();
 check(before===EJSON.stringify(target.notificationRuleConfigs.find().toArray()),'initializer changed existing documents');
 for(const row of catalog.indexes){
  const actual=target.getCollection(row.collection).getIndexes().find(index=>index.name===row.options.name);
  check(actual&&JSON.stringify(actual.key)===JSON.stringify(row.key),'missing/key mismatch '+row.options.name);
  for(const field of ['unique','sparse','expireAfterSeconds','partialFilterExpression'])
   check(JSON.stringify(actual[field])===JSON.stringify(row.options[field]),'options mismatch '+row.options.name);
  // Mongo expands collation defaults; compare every explicitly declared option.
  for(const [field,value] of Object.entries(row.options.collation||{}))
   check(actual.collation?.[field]===value,'collation mismatch '+row.options.name+'/'+field);
 }
 for(const row of catalog.retiredIndexes)
  check(!target.getCollection(row.collection).getIndexes().some(index=>index.name===row.name),'obsolete constraint retained');
 target.notificationRuleConfigs.insertMany([{_id:'work',baseGroupId:'work',ruleKey:'retained'},
  {_id:'community',baseGroupId:'community',ruleKey:'retained'}]);
 let rejected=false;try{target.notificationRuleConfigs.insertOne({_id:'duplicate',baseGroupId:'work',ruleKey:'retained'});}
 catch(error){rejected=error.code===11000;}check(rejected,'same-group duplicates accepted');
 const plan=target.notificationRuleConfigs.find({baseGroupId:'work',ruleKey:'retained'}).explain('executionStats');
 check(plan.executionStats.totalDocsExamined===1,'scoped query does not examine exactly one document');
 check(JSON.stringify(plan.queryPlanner.winningPlan).includes('notification_rule_group_key'),'scoped lookup lost its index');
 print('PASS: '+catalog.indexes.length+' indexes; upgrade and reset initialization repeated; operator data retained; scoped inserts; duplicate rejection; indexed lookup examines one document.');
} finally {if(target.getUser(prefix))target.dropUser(prefix);target.dropDatabase();}
`);
}
