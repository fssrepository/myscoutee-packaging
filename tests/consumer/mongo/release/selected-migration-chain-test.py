#!/usr/bin/env python3
"""Emit the selected real-Mongo migration-chain test for an existing QA container."""
import os
from pathlib import Path
import json

root = (Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'build')
CONTRACT = json.loads((Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'config/packaging/tests/contract-inputs.json').read_text())['contracts']['selected-migration-chain-test']
CONTRACT_INPUTS = CONTRACT['inputs']
CONTRACT_EXPECTATIONS = CONTRACT.get('expectations', {})
sources = {p.name: p.read_text() for p in (root.parent / 'config/packaging/migrations').glob('*.js')}
inputs = {str(p.relative_to(root.parent / 'config/packaging/migrations')): p.read_text()
          for p in (root.parent / CONTRACT_INPUTS['packaging_migrations_seeds']).glob('*/*.json')}
print('const sources=' + json.dumps(sources) + ';')
print('const inputs=' + json.dumps(inputs) + ';')
print('const runner=' + json.dumps((root.parent / 'build/scripts/run-data-migrations.js').read_text()) + ';')
print(r'''
const fs = require('fs'), crypto = require('crypto'), path = require('path');
const directory = fs.mkdtempSync('/tmp/qa-template-chain-');
const target = db.getSiblingDB('qa_template_chain_' + new ObjectId().toHexString());
const releaseDirectory = directory + '/current-release';
fs.mkdirSync(releaseDirectory);
fs.writeFileSync(directory + '/runner.js', runner);
process.env.MYSCOUTEE_MIGRATION_DIRECTORY = directory;
process.env.MYSCOUTEE_MIGRATION_SEED_DIRECTORY = releaseDirectory;
function check(value, message) { if (!value) throw Error(message); }
function run() {
    for (const [name, source] of Object.entries({...sources, ...inputs})) {
        fs.mkdirSync(path.dirname(directory + '/' + name), {recursive: true});
        fs.writeFileSync(directory + '/' + name, source);
    }
    db = target;
    load(directory + '/runner.js');
}
function snapshot() {
    return EJSON.stringify(target.deploymentConfigurations.findOne({_id: 'deployment-configuration'}));
}
try {
    target.deploymentConfigurations.insertOne({_id: 'deployment-configuration', schemaVersion: 5,
        version: 7, operatorSetting: 'retain'});
    const before = snapshot();
    run();
    check(target.schemaMigrations.countDocuments({}) === Object.keys(sources).length, 'incomplete chain');
    for (const id of ['015-runtime-index-parity', '016-release-catalog-parity'])
        check(target.schemaMigrations.findOne({_id: id}).seedSha256.length === 64, 'missing pinned input receipt');
    const catalog = JSON.parse(inputs['seeds/015-runtime-index-parity/runtime-indexes.json']);
    for (const row of catalog.indexes)
        check(target.getCollection(row.collection).getIndexes().some(index => index.name === row.options.name), 'missing index');
    const defaults = JSON.parse(inputs['seeds/016-release-catalog-parity/catalog-defaults.json']);
    for (const row of defaults)
        check(target.getCollection(row.collection).countDocuments({}) === row.rows.length, 'missing selected catalog');
    const receipts = EJSON.stringify(target.schemaMigrations.find().sort({_id: 1}).toArray());
    run();
    check(snapshot() === before, 'operator configuration changed');
    check(EJSON.stringify(target.schemaMigrations.find().sort({_id: 1}).toArray()) === receipts, 'repeat changed receipts');
    check(process.env.MYSCOUTEE_MIGRATION_SEED_DIRECTORY === releaseDirectory, 'release directory not restored');
    print('PASS complete selected chain, pinned inputs, all indexes/catalogs, repeat and retained operator state');

    for (const selection of [sources, inputs]) {
        const key = Object.keys(selection)[0], original = selection[key];
        selection[key] += '\n';
        let rejected = false;
        try { run(); } catch (error) { rejected = /Applied migration.*changed:/.test(error.message); }
        finally { selection[key] = original; }
        check(rejected, 'applied source/input tampering accepted');
    }
    const last = Object.keys(sources).sort().at(-1), id = last.replace(/\.js$/, '');
    target.schemaMigrations.deleteOne({_id: id});
    const original = sources[last];
    sources[last] = 'throw Error("injected interruption")';
    let rejected = false;
    try { run(); } catch (error) { rejected = error.message.includes('injected interruption'); }
    finally { sources[last] = original; }
    check(rejected && !target.schemaMigrations.findOne({_id: id}), 'failed migration was recorded');
    check(process.env.MYSCOUTEE_MIGRATION_SEED_DIRECTORY === releaseDirectory, 'failure changed release directory');
    run();
    check(target.schemaMigrations.countDocuments({}) === Object.keys(sources).length, 'retry incomplete');
    check(snapshot() === before, 'retry changed operator configuration');
    print('PASS changed source/input rejection, interrupted step not recorded, retry and directory restoration');
} finally {
    target.dropDatabase();
    fs.rmSync(directory, {recursive: true});
}
''')
