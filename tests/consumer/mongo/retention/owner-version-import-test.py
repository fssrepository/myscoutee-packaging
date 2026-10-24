#!/usr/bin/env python3
"""Exercise seed owner-version initialization on the existing Mongo instance."""
import json
import subprocess
import tempfile
from pathlib import Path
from pathlib import Path
import os, sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'lib'))
from mongo_test_runtime import run_mongo

root = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd()))
CONTRACT = json.loads((Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'config/packaging/tests/contract-inputs.json').read_text())['contracts']['owner-version-import-test']
CONTRACT_INPUTS = CONTRACT['inputs']
CONTRACT_EXPECTATIONS = CONTRACT.get('expectations', {})
importer = root / CONTRACT_INPUTS['conf_mongodb_mongo_import_sh']
# Exercise the real import dispatch; capture its Mongo statements without touching live collections.
capture = r'''set -eu
export MONGO_IMPORT_SINGLE_FILE=/nonexistent/owner-version-test.json
source "$1" >/dev/null
exec 3>&1
mongosh() { printf '%s\n' "${@: -1}" >&3; }
mongoimport() { printf '// imported\n' >&3; }
ensure_collection_indexes() { :; }
for collection in assets events eventFeedbackStates users; do
  import_json_file demo_db "$2/$collection.json"
done
'''
with tempfile.TemporaryDirectory() as directory:
    for collection in ('assets', 'events', 'eventFeedbackStates', 'users'):
        Path(directory, collection + '.json').write_text('[{"_id":"legacy"}]')
    commands = subprocess.check_output(["bash", "-c", capture, "_", str(importer), directory], text=True)
assert commands.count('// imported') == 4
assert all('updateMany' in part for part in commands.split('// imported')[1:4])
assert commands.count("updateMany") == 3
script = r'''const testDb = db.getSiblingDB('qa_owner_versions_' + new ObjectId().toHexString());
function check(ok, message) { if (!ok) throw Error(message); }
function migrate() { COMMANDS }
try {
  for (const name of ['assets', 'events', 'eventFeedbackStates', 'users']) {
    testDb.getCollection(name).insertMany([
      {_id:'legacy', title:'Retained content'},
      {_id:'existing', version:NumberLong('7'), title:'Modified content'}
    ]);
  }
  migrate();
  for (const name of ['assets', 'events', 'eventFeedbackStates']) {
    const rows = testDb.getCollection(name);
    check(rows.countDocuments({}) === 2, name + ': records changed');
    check(rows.countDocuments({_id:'legacy', version:{$type:'long', $eq:0}, title:'Retained content'}) === 1, name + ': legacy version');
    check(rows.countDocuments({_id:'existing', version:7, title:'Modified content'}) === 1, name + ': existing version overwritten');
    // A versioned update matches the imported record; a stale repeat cannot.
    check(rows.updateOne({_id:'legacy', version:0}, {$set:{title:'Saved'}, $inc:{version:1}}).matchedCount === 1, name + ': save failed');
    check(rows.updateOne({_id:'legacy', version:0}, {$set:{title:'Stale'}}).matchedCount === 0, name + ': stale write accepted');
  }
  migrate();
  for (const name of ['assets', 'events', 'eventFeedbackStates']) {
    check(testDb.getCollection(name).countDocuments({_id:'legacy', version:1, title:'Saved'}) === 1, name + ': repeat reset version');
  }
  check(testDb.users.countDocuments({_id:'legacy', version:{$exists:false}}) === 1, 'unrelated collection changed');
  print('PASS owner seed versions: imported owners writable, existing versions/content retained, stale writes rejected, repeat idempotent, unrelated collections untouched.');
} finally { testDb.dropDatabase(); }
'''.replace('COMMANDS', commands.replace('db.getCollection(', 'testDb.getCollection('))
run_mongo(script)
