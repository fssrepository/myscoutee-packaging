#!/usr/bin/env python3
"""Exercise packaged migration against an isolated DB in an existing QA Mongo container."""
import json
import os
from pathlib import Path
import subprocess
CONTRACT = json.loads((Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'config/packaging/tests/contract-inputs.json').read_text())['contracts']['deployment-configuration-migration-test']
CONTRACT_INPUTS = CONTRACT['inputs']
CONTRACT_EXPECTATIONS = CONTRACT.get('expectations', {})

sources = [
    (Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / CONTRACT_INPUTS['packaging_migrations_004_deployment_configuration_js']).read_text(),
    (Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / CONTRACT_INPUTS['packaging_migrations_005_deployment_configuration_integration_js']).read_text(),
]
source = '\n'.join('{\n' + item + '\n}' for item in sources)
source_for_test = source.replace("db.getCollection(", "testDb.getCollection(")
source_005_for_test = sources[1].replace("db.getCollection(", "testDb.getCollection(")
script = '''
const testName = 'qa_migration_004_005_' + new ObjectId().toHexString();
const testDb = db.getSiblingDB(testName);
function check(condition, message) { if (!condition) throw new Error(message); }
try {
  const original = {_id:'deployment-configuration', schemaVersion:3, version:NumberLong('7'),
    branding:{productName:'Custom operator name',logoCharacterIndex:2},
    firebase:{active:true, authenticationCredentialEnvelope:{ciphertext:'opaque-retained'}},
    payment:{credentialEnvelope:{ciphertext:'opaque-payment'}}, customField:'retain me'};
  testDb.deploymentConfigurations.insertOne(original);
  { SOURCE }
  const changed = testDb.deploymentConfigurations.findOne();
  check(Number(changed.schemaVersion) === 5 && Number(changed.version) === 9, 'versions not migrated');
  check(changed.integration && changed.integration.publicBaseUrl === null, 'integration default not added');
  delete changed.integration;
  changed.schemaVersion=3; changed.version=NumberLong('7');
  check(EJSON.stringify(changed) === EJSON.stringify(original), 'operator values changed');
  const once=EJSON.stringify(testDb.deploymentConfigurations.findOne());
  { SOURCE }
  check(EJSON.stringify(testDb.deploymentConfigurations.findOne()) === once, 'not idempotent');
  testDb.deploymentConfigurations.updateOne({_id:original._id},{$set:{schemaVersion:2}});
  let rejected=false;
  try { { SOURCE } } catch (error) { rejected=true; }
  check(rejected && Number(testDb.deploymentConfigurations.findOne().schemaVersion) === 2,'unsupported schema mutated');
  testDb.deploymentConfigurations.deleteMany({});
  { SOURCE }
  check(testDb.deploymentConfigurations.countDocuments({})===0,'fresh database seeded by migration');
  const custom = {_id:'deployment-configuration', schemaVersion:4, version:NumberLong('12'),
    branding:{productName:'Custom'}, integration:{publicBaseUrl:'https://operator.example/api/integrations/v1'},
    firebase:{authenticationCredentialEnvelope:{ciphertext:'still-retained'}}};
  testDb.deploymentConfigurations.insertOne(custom);
  { SOURCE_005 }
  const customChanged = testDb.deploymentConfigurations.findOne();
  check(Number(customChanged.schemaVersion) === 5 && Number(customChanged.version) === 13, 'schema4 version not migrated');
  check(customChanged.integration.publicBaseUrl === custom.integration.publicBaseUrl, 'existing integration URL changed');
  customChanged.schemaVersion=4; customChanged.version=NumberLong('12');
  check(EJSON.stringify(customChanged) === EJSON.stringify(custom), 'schema4 operator values changed');
  print('PASS migration004/005: retained fields/secrets/URL, optimistic versions, repeat execution, unsupported schema, fresh database');
} finally { testDb.dropDatabase(); }
'''.replace('SOURCE_005', source_005_for_test).replace('SOURCE', source_for_test)
subprocess.run(['docker','exec','-i','mongodb','sh','-c',
 'exec mongosh --quiet --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin production_db --file /dev/stdin'],input=script,text=True,check=True)
