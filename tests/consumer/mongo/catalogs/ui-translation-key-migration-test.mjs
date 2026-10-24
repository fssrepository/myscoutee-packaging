import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const root = pathToFileURL(resolve(process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT ?? process.cwd()) + '/');
const read = path => fs.readFileSync(new URL(path, root), 'utf8');
const testCase = JSON.parse(read('config/packaging/tests/ui-translation.json'));
const input = read(testCase.input);
const renames = JSON.parse(input);
assert.equal(renames.length, testCase.perLanguageCount * testCase.languages.length, 'all reviewed key renames must cover the selected languages');
assert.equal(new Set(renames.map(row => `${row.target.lang}:${row.from}`)).size, renames.length,
    'a legacy key must appear only once per language');
const catalog = JSON.parse(read('server/docker/conf/mongodb/myscoutee_db/i18n_messages.json'));
for (const {from, target} of renames) {
    assert.deepEqual(target, catalog.find(row => row._id === target._id));
    assert.ok(!catalog.some(row => row.key === from && row.lang === target.lang));
}
assert.equal(new Set(renames.map(row => row.target.lang)).size, testCase.languages.length);
for (const lang of testCase.languages) {
    assert.equal(renames.filter(row => row.target.lang === lang).length, testCase.perLanguageCount);
    assert.ok(renames.some(row => row.target.lang === lang && row.target.key === testCase.requiredTargetKey));
}
const source = read(testCase.migration);
if (!process.argv.includes('--print-script')) {
    console.log(testCase.successMessage);
} else console.log(`
const targetDb = db.getSiblingDB('qa_ui_keys_' + new ObjectId().toHexString());
const renames = JSON.parse(${JSON.stringify(input)});
function run() {
    const db = targetDb;
    const require = () => ({readFileSync: () => ${JSON.stringify(input)}});
    const process = {env: {MYSCOUTEE_MIGRATION_SEED_DIRECTORY: '/pinned'}};
    ${source}
}
function check(ok, message) { if (!ok) throw Error(message); }
const snapshot = () => EJSON.stringify(targetDb.i18n_messages.find().sort({_id: 1}).toArray());
try {
    targetDb.i18n_bundles.insertOne({_id: 'hu', version: '2026.10.21.1'});
    targetDb.i18n_messages.insertMany(renames.map(({from, target}, index) => ({
        _id: 'legacy-' + index, key: from, lang: target.lang, value: target.value
    })));
    targetDb.i18n_messages.insertOne({_id: 'unrelated', key: 'custom.caption', lang: 'hu', value: 'Saját felirat'});
    targetDb.i18n_messages.updateOne({_id: 'legacy-0'}, {$set: {value: 'Operator customization'}});
    const custom = EJSON.stringify(targetDb.i18n_messages.findOne({_id: 'legacy-0'}));
    run();
    for (const {target} of renames) {
        check(EJSON.stringify(targetDb.i18n_messages.findOne({_id: target._id})) === EJSON.stringify(target), 'canonical translation missing or changed');
    }
    check(targetDb.i18n_messages.countDocuments({_id: /^legacy-/}) === 1, 'unchanged legacy defaults survived');
    check(EJSON.stringify(targetDb.i18n_messages.findOne({_id: 'legacy-0'})) === custom, 'operator edit lost');
    check(targetDb.i18n_messages.findOne({_id: 'unrelated'}).value === 'Saját felirat', 'unrelated text changed');
    check(targetDb.i18n_bundles.findOne({_id: 'hu'}).version === '2026.10.21.1', 'version published before release seed sync');
    const first = snapshot();
    run();
    check(snapshot() === first, 'retry changed migrated data');
    targetDb.i18n_messages.deleteMany({});
    run();
    check(targetDb.i18n_messages.countDocuments({}) === renames.length, 'fresh database missing keys');
    print('PASS semantic UI key upgrade: selected languages, default retirement, custom retention, version ordering and retry.');
} finally {
    targetDb.dropDatabase();
}
`);
