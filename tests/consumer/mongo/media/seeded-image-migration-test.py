#!/usr/bin/env python3
"""Run the image-reference upgrade against an isolated, disposable Mongo DB."""
import json
from pathlib import Path
import sys
from pathlib import Path
import os, sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'lib'))
from mongo_test_runtime import run_mongo

ROOT = (Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'build')
CONTRACT = json.loads((Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'config/packaging/tests/contract-inputs.json').read_text())['contracts']['seeded-image-migration-test']
CONTRACT_INPUTS = CONTRACT['inputs']
CONTRACT_EXPECTATIONS = CONTRACT.get('expectations', {})
source = (ROOT.parent / CONTRACT_INPUTS['packaging_migrations_023_seeded_image_webp_js']).read_text()
manifest = json.loads((ROOT.parent / CONTRACT_INPUTS['seeds_023_seeded_image_webp_image_replacements_json']).read_text())
script = ('const imageManifest=' + json.dumps(manifest) + ';\n'
          + 'const migrationSource=' + json.dumps(source) + ';\n'
          + 'const migrationRunner=' + json.dumps((ROOT.parent / 'build/scripts/run-data-migrations.js').read_text()) + ';\n') + r'''
const testDb = db.getSiblingDB('qa_seeded_images_' + new ObjectId().toHexString());
function check(value, message) { if (!value) throw Error(message); }
// Exercise the real runner's load/block scope, not only a function wrapper.
const fs = require('fs'), path = require('path');
const runnerDirectory = fs.mkdtempSync('/tmp/qa-seeded-image-runner-');
const runnerDb = db.getSiblingDB('qa_seeded_image_runner_' + new ObjectId().toHexString());
const previousDb = db;
const previousDirectory = process.env.MYSCOUTEE_MIGRATION_DIRECTORY;
try {
    fs.mkdirSync(path.join(runnerDirectory, 'seeds/023-seeded-image-webp'), {recursive: true});
    fs.writeFileSync(path.join(runnerDirectory, '023-seeded-image-webp.js'), migrationSource);
    fs.writeFileSync(path.join(runnerDirectory, 'seeds/023-seeded-image-webp/image-replacements.json'), JSON.stringify(imageManifest));
    fs.writeFileSync(path.join(runnerDirectory, 'runner.js'), migrationRunner);
    runnerDb.ideaPosts.insertOne({_id: 'runner', imageUrl: 'assets/articles/business-idea.png'});
    process.env.MYSCOUTEE_MIGRATION_DIRECTORY = runnerDirectory;
    db = runnerDb;
    load(path.join(runnerDirectory, 'runner.js'));
    check(runnerDb.ideaPosts.findOne().imageUrl === imageManifest.frontend.find(row => row.previousPath === 'assets/articles/business-idea.png').path, 'real runner did not migrate image');
    check(runnerDb.schemaMigrations.countDocuments({}) === 1, 'real runner receipt missing');
    load(path.join(runnerDirectory, 'runner.js'));
    check(runnerDb.schemaMigrations.countDocuments({}) === 1, 'real runner retry duplicated receipt');
    print('PASS actual migration runner: load scope, pinned inputs, receipt and retry');
} finally {
    db = previousDb;
    if (previousDirectory === undefined) delete process.env.MYSCOUTEE_MIGRATION_DIRECTORY;
    else process.env.MYSCOUTEE_MIGRATION_DIRECTORY = previousDirectory;
    runnerDb.dropDatabase();
    fs.rmSync(runnerDirectory, {recursive: true});
}
function migrate(db) {
    const require = () => ({readFileSync: () => JSON.stringify(imageManifest)});
    SOURCE
}
const old = 'assets/articles/business-idea.png';
const next = imageManifest.frontend.find(row => row.previousPath === old).path;
const metadata = {caption: 'Retained caption', location: 'Budapest', event: {id: 'event'}};
const snapshot = name => EJSON.stringify(testDb.getCollection(name).find().sort({_id: 1}).toArray());
try {
    testDb.ideaPosts.insertMany([
        {_id: 'seeded', title: 'Operator-edited title', published: false, imageUrl: old,
         imageUrls: [old, 'https://cdn.example/custom.png'], imageDetails: {[old]: metadata},
         contentHtml: '<p>Unchanged text.</p><img src="/' + old + '">', createdAt: new Date('2020-01-01')},
        {_id: 'custom', imageUrl: 'https://cdn.example/' + old,
         contentHtml: '<img src="https://cdn.example/' + old + '">', imageUrls: ['custom.png']}
    ]);
    const custom = EJSON.stringify(testDb.ideaPosts.findOne({_id: 'custom'}));
    testDb.events.insertMany([
        {_id: 'raw', imageUrl: '/media/public?key=images/system/random-room-default.png'},
        {_id: 'encoded', imageUrl: '/api/media/public?key=images%2Fsystem%2Frandom-room-default.png&cache=1'}
    ]);
    testDb.helpCenterRevisions.insertOne({_id: 'help', sections: [{id: 'intro', contentHtml: '<img src="' + old + '">'}]});
    testDb.campaigns.insertOne({_id: 'campaign', imageUrls: ['/' + old + '?v=1'], imageDetails: {['/' + old + '?v=1']: metadata}});
    testDb.serviceOfferings.insertOne({_id: 'service', imageUrls: [old]});
    testDb.landingSlides.insertOne({_id: 'slide', imageUrl: 'assets/logo/cards_no_edges.png'});
    testDb.i18n_messages.insertOne({_id: 'text', value: '<img src="' + old + '">'});
    testDb.users.insertOne({_id: 'user', imageUrl: '/media/public?key=images/user/original'});
    const user = snapshot('users');
    migrate(testDb);
    const row = testDb.ideaPosts.findOne({_id: 'seeded'});
    check(row.imageUrl === next && row.imageUrls[0] === next, 'article URL/array not migrated');
    check(row.contentHtml === '<p>Unchanged text.</p><img src="' + next + '">', 'article HTML not migrated');
    check(EJSON.stringify(row.imageDetails[next]) === EJSON.stringify(metadata), 'image metadata detached');
    check(row.createdAt instanceof Date && row.createdAt.toISOString() === '2020-01-01T00:00:00.000Z', 'BSON date changed');
    check(row.title === 'Operator-edited title' && !row.published, 'operator fields changed');
    check(EJSON.stringify(testDb.ideaPosts.findOne({_id: 'custom'})) === custom, 'external image changed');
    check(testDb.events.findOne({_id: 'raw'}).imageUrl.endsWith('random-room-default.webp'), 'raw room URL unchanged');
    check(testDb.events.findOne({_id: 'encoded'}).imageUrl.endsWith('random-room-default.webp&cache=1'), 'encoded URL or query changed');
    check(testDb.campaigns.findOne().imageUrls[0] === next + '?v=1', 'root-relative URL/query changed');
    check(testDb.serviceOfferings.findOne().imageUrls[0] === next, 'service image unchanged');
    check(testDb.landingSlides.findOne().imageUrl === 'assets/logo/cards_no_edges.webp', 'landing atlas unchanged');
    check(testDb.helpCenterRevisions.findOne().sections[0].contentHtml.includes(next), 'help HTML unchanged');
    check(testDb.i18n_messages.findOne().value.includes(next), 'i18n HTML unchanged');
    check(snapshot('users') === user, 'user uploads touched');
    const names = ['ideaPosts','events','campaigns','serviceOfferings','landingSlides','helpCenterRevisions','i18n_messages'];
    const before = names.map(name => snapshot(name));
    migrate(testDb);
    check(names.every((name, index) => snapshot(name) === before[index]), 'retry changed data');
    testDb.ideaPosts.insertOne({_id: 'concurrent', imageUrl: old});
    const racingDb = {getCollection(name) {
        const collection = testDb.getCollection(name);
        return {
            find: (...args) => collection.find(...args),
            bulkWrite(operations, options) {
                if (name === 'ideaPosts') collection.updateOne({_id: 'concurrent'}, {$set: {imageUrl: 'operator.png'}});
                return collection.bulkWrite(operations, options);
            }
        };
    }};
    let rejected = false;
    try { migrate(racingDb); } catch (error) { rejected = error.message.includes('Concurrent image-reference edit'); }
    check(rejected && testDb.ideaPosts.findOne({_id:'concurrent'}).imageUrl === 'operator.png', 'concurrent edit overwritten');
    print('PASS image migration: articles, HTML, metadata, rooms, help, i18n, retry, concurrency and retained user data');
} finally { testDb.dropDatabase(); }
'''.replace('SOURCE', source)
if '--print-script' in sys.argv:
    print(script)
else:
    run_mongo(script)
