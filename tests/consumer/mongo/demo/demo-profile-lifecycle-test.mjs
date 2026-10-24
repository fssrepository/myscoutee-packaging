import { readFileSync as _readContractInputs } from 'node:fs';
import { pathToFileURL as _contractFileURL } from 'node:url';
import { resolve as _contractResolve } from 'node:path';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const root = _contractFileURL(_contractResolve(process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT ?? process.cwd()) + '/');
const contract = JSON.parse(_readContractInputs(new URL('config/packaging/tests/contract-inputs.json', root), 'utf8')).contracts["demo-profile-lifecycle-test"];
const contractInputs = contract.inputs;
const contractExpectations = contract.expectations ?? {};
const read = name => fs.readFileSync(new URL(name, root), 'utf8');
const input = read(contractInputs["seeds_025_demo_profile_lifecycle_users_json"]);
const seeds = JSON.parse(input);
assert.equal(seeds.length, 2);
assert.deepEqual(seeds.map(row => [row.name, row.status, row.to]), [
    ['Ava Hale', 'B', 'blocked'], ['Ryan Hale', 'D', 'deleted']
]);
for (const name of ['demo_db', 'e2e_db']) {
    const users = JSON.parse(read(`server/docker/conf/mongodb/${name}/users.json`));
    for (const seed of seeds) {
        const user = users.find(row => row.userId === seed.userId);
        assert.equal(user.name, seed.name);
        assert.equal(user.status, seed.status);
        assert.equal(user.profileStatus, seed.to);
        if (seed.to === 'deleted') assert.ok(user.deletedAtIso);
    }
}
assert.deepEqual(JSON.parse(read(contractInputs["mongodb_myscoutee_db_users_json"])), []);
const source = read(contractInputs["packaging_migrations_025_demo_profile_lifecycle_js"]);
if (!process.argv.includes('--print-script')) {
    console.log('PASS: demo/E2E lifecycle seeds agree; production contains no sample accounts.');
} else console.log(`
const targetDb = db.getSiblingDB('qa_demo_lifecycle_' + new ObjectId().toHexString());
const seeds = EJSON.parse(${JSON.stringify(input)});
function run(scope = 'demo_db') {
    const db = { getName: () => scope, users: targetDb.users };
    const require = () => ({ readFileSync: () => ${JSON.stringify(input)} });
    const process = { env: { MYSCOUTEE_MIGRATION_SEED_DIRECTORY: '/pinned' } };
    ${source}
}
function check(ok, message) { if (!ok) throw Error(message); }
const snapshot = () => EJSON.stringify(targetDb.users.find().sort({_id: 1}).toArray());
const legacy = seeds.map(seed => ({_id: seed._id, userId: seed.userId, name: seed.name,
    status: seed.status, profileStatus: seed.from, custom: 'retained'}));
try {
    targetDb.users.insertMany(legacy);
    targetDb.users.insertOne({_id: 'real-account', status: 'B', profileStatus: 'public'});
    const before = snapshot();
    run('myscoutee_db');
    check(snapshot() === before, 'production changed');
    run();
    for (const seed of seeds) {
        const user = targetDb.users.findOne({_id: seed._id});
        check(user.profileStatus === seed.to && user.custom === 'retained', 'demo correction failed');
    }
    check(targetDb.users.findOne({_id: 'real-account'}).profileStatus === 'public', 'unrelated account changed');
    const first = snapshot();
    run();
    check(snapshot() === first, 'retry changed data');
    targetDb.users.deleteMany({});
    targetDb.users.insertMany(legacy.map(user => ({...user, profileStatus: 'inactive'})));
    const custom = snapshot();
    run('e2e_db');
    check(snapshot() === custom, 'operator lifecycle change overwritten');
    targetDb.users.deleteMany({});
    run();
    check(targetDb.users.countDocuments({}) === 0, 'migration created sample accounts');
    print('PASS demo lifecycle migration: correction, retry, production/custom retention and empty database.');
} finally { targetDb.dropDatabase(); }
`);
