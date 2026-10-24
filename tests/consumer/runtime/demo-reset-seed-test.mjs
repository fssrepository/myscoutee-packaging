import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
// Exercise the actual shared reset oracle with every selected JSON file.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const root = pathToFileURL(resolve(process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT ?? process.cwd()) + '/');
const script = fs.readFileSync(new URL('build/scripts/reset-demo-state.sh', root), 'utf8');
const start = script.indexOf('const userCount =');
const end = script.indexOf("\n'\\''", start);
assert(start > 0 && end > start, 'Cannot locate the actual reset oracle');
const oracle = script.slice(start, end);
const directory = new URL('server/docker/conf/mongodb/demo_db/', root);
const files = fs.readdirSync(directory).filter(name => name.endsWith('.json'));
const data = {};
for (const file of files) {
  const name = file === 'adminUsers.json' ? 'users' : file.slice(0, -5);
  data[name] ??= new Map();
  for (const row of JSON.parse(fs.readFileSync(new URL(file, directory), 'utf8'))) {
    data[name].set(JSON.stringify(row._id), row);
  }
}
function run(changes = {}, selected = files) {
  const calls = [];
  const collection = name => ({countDocuments(query) {
    calls.push(name);
    const rows = changes[name] ?? [...(data[name]?.values() ?? [])];
    if (query.images) return rows.filter(row => (row.images ?? []).some(image => /^https?:\/\//i.test(image))).length;
    if (query._id) {
      const expected = new Set(query._id.$in.map(id => JSON.stringify(id)));
      return rows.filter(row => expected.has(JSON.stringify(row._id))).length;
    }
    return rows.length;
  }});
  vm.runInNewContext(oracle, {
    db:{users:collection('users'), getCollection:collection}, EJSON:JSON,
    require(name) {
      assert.equal(name,'fs');
      return {readdirSync:()=>selected, readFileSync:path=>
        fs.readFileSync(new URL(path.split('/').at(-1), directory),'utf8')};
    }
  });
  return new Set(calls);
}
assert.deepEqual(run(), new Set(Object.keys(data)));
for (const [name, rows] of Object.entries(data)) {
  const values = [...rows.values()];
  if (values.length) {
    assert.throws(()=>run({[name]:values.slice(1)}), /Incomplete Explore seed/);
    assert.throws(()=>run({[name]:[{...values[0],_id:'wrong-seed-id'},...values.slice(1)]}), /Incomplete Explore seed/);
  } else {
    assert.throws(()=>run({[name]:[{_id:'unexpected-retained-row'}]}), /Incomplete Explore seed/);
  }
}
assert.throws(()=>run({},[]), /No packaged Explore seed files/);
const users = [...data.users.values()].map(row=>({...row,images:['https://external.invalid/avatar.png']}));
assert.throws(()=>run({users}), /externalImages=/);
console.log(`PASS: actual reset oracle covers all ${files.length} seed files, missing/wrong IDs, nonempty empty-baselines and external avatars.`);
