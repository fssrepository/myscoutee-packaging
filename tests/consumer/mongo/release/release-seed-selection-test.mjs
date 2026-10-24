import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const root = pathToFileURL(resolve(process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT ?? process.cwd()) + '/');
const source = fs.readFileSync(new URL('build/scripts/sync-release-system-seeds.js', root), 'utf8');
const testCase = JSON.parse(fs.readFileSync(new URL('config/packaging/tests/release-seeds.json', root), 'utf8'));
const native = JSON.parse(fs.readFileSync(new URL('build/scripts/release-system-seeds.json', root), 'utf8'));
const minimal = native.filter(row => testCase.minimalCollections.includes(row.collection));
function run(selection) {
  const reads = [], writes = [];
  vm.runInNewContext(source, {
    process: {env: {MYSCOUTEE_MIGRATION_DIRECTORY:'/migrations', MYSCOUTEE_MIGRATION_SEED_DIRECTORY:'/seeds'}},
    require: name => { assert.equal(name, 'fs'); return {readFileSync(path) {
      reads.push(path);
      return JSON.stringify(path === '/migrations/release-system-seeds.json' ? selection : [{_id:'existing', value:'release'}]);
    }}; },
    EJSON: JSON, print() {},
    db: {deploymentConfigurations:{findOne:()=>({schemaVersion:5})}, getCollection(name) {
      return {bulkWrite(operations, options) {writes.push({name,operations,options});}};
    }},
  });
  return JSON.parse(JSON.stringify({reads,writes}));
}
for (const selection of [native, minimal]) {
  const {reads,writes} = run(selection);
  assert.equal(reads.length, selection.length + 1);
  assert.equal(writes.length, selection.length);
  for (const row of selection) {
    const write = writes.find(item => item.name === row.collection);
    const operation = write.operations[0];
    assert.equal(write.options.ordered, true);
    if (row.replace) assert.deepEqual(operation, {replaceOne:{filter:{_id:'existing'},replacement:{_id:'existing',value:'release'},upsert:true}});
    else assert.deepEqual(operation, {updateOne:{filter:{_id:'existing'},update:{$setOnInsert:{_id:'existing',value:'release'}},upsert:true}});
  }
}
assert(!run(minimal).reads.some(path => path.includes('exchangeRates')));
for (const fragment of testCase.forbiddenReadFragments) assert(!run(minimal).reads.some(path => path.includes(fragment)));
for (const name of testCase.retainedCollections) {
  assert.equal(native.find(row => row.collection === name)?.replace, false,
    'upgrades may insert missing system defaults but must retain operator changes');
}
for (const selection of [[], [...native,native[0]], [{collection:'../users',replace:true}], [{collection:'users',replace:'true'}]]) {
  assert.throws(()=>run(selection), /Invalid release system seed selection/);
}
console.log('PASS: selected release seeds preserve write semantics and batch counts; omitted seeds are never read or written.');
