// Runs after schema migrations on every release, even when the chain was a no-op.
const fs = require('fs');
const directory = process.env.MYSCOUTEE_MIGRATION_SEED_DIRECTORY || '/docker-entrypoint-initdb.d/myscoutee_db';
const configuration = db.deploymentConfigurations.findOne({_id:'deployment-configuration'});
if (configuration && Number(configuration.schemaVersion) !== 5) throw new Error('Migrate the configuration before loading seeds.');
const selection = JSON.parse(fs.readFileSync(process.env.MYSCOUTEE_MIGRATION_DIRECTORY + '/release-system-seeds.json', 'utf8'));
if (!Array.isArray(selection) || !selection.length || selection.length > 64
        || selection.some(row => Object.keys(row).sort().join(',') !== 'collection,replace'
          || !/^[A-Za-z][A-Za-z0-9_]*$/.test(row.collection) || typeof row.replace !== 'boolean')
        || new Set(selection.map(row => row.collection)).size !== selection.length) {
    throw new Error('Invalid release system seed selection.');
}
for (const {collection: name, replace: packageOwned} of selection) {
    const rows = EJSON.parse(fs.readFileSync(directory + '/' + name + '.json', 'utf8'));
    if (!Array.isArray(rows) || rows.some(row => row._id == null)) throw new Error('Invalid system seed: ' + name);
    if (rows.length) db.getCollection(name).bulkWrite(rows.map(row => packageOwned
        ? {replaceOne: {filter: {_id: row._id}, replacement: row, upsert: true}}
        : {updateOne: {filter: {_id: row._id}, update: {$setOnInsert: row}, upsert: true}}), {ordered: true});
    print('Synchronized release seed: ' + name + ' (' + rows.length + ')');
}
