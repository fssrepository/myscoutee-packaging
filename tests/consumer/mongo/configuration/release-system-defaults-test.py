#!/usr/bin/env python3
"""Real Mongo assertions for migration006. --print-script supports a remote QA container."""
import os
import json
import subprocess
import sys
from pathlib import Path
root=(Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'build')
CONTRACT = json.loads((Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'config/packaging/tests/contract-inputs.json').read_text())['contracts']['release-system-defaults-test']
CONTRACT_INPUTS = CONTRACT['inputs']
CONTRACT_EXPECTATIONS = CONTRACT.get('expectations', {})
source='\n'.join('{\n'+p.read_text()+'\n}' for p in [root.parent / CONTRACT_INPUTS['packaging_migrations_006_release_system_defaults_js'],root/'scripts/sync-release-system-seeds.js'])
script=r'''
const testDb=db.getSiblingDB('qa_release_defaults_'+new ObjectId().toHexString());
function check(value,message){if(!value)throw Error(message);}
const seeds={deploymentConfigurations:[{_id:'deployment-configuration',payment:{exchangeRateUrl:'https://rates.example/reference.xml'}}],exchangeRates:[{_id:'default-v1',rates:{EUR:'1'}}],notificationRuleConfigs:[{_id:'existing',enabled:true},{_id:'new',enabled:true}],countryPartitions:[{_id:'country-test',countryCode:'DE'}],i18n_messages:[{_id:'text',value:'first'}],i18n_bundles:[{_id:'en',version:'1'}]};
seeds['release-system-seeds']=SELECTION;
function migrate(db){
 const require=name=>({readFileSync:path=>JSON.stringify(seeds[path.split('/').pop().replace('.json','')])});
 SOURCE
}
try{
 const original={_id:'deployment-configuration',schemaVersion:5,version:12,payment:{credentialEnvelope:'retain'},branding:{productName:'Custom'}};
 testDb.deploymentConfigurations.insertOne(original);
 testDb.notificationRuleConfigs.insertOne({_id:'existing',enabled:false,runHistory:['retain']});
 testDb.users.insertOne({_id:'existing-user',name:'retained'});
 migrate(testDb);
 let row=testDb.deploymentConfigurations.findOne();
 check(row.version===13 && row.payment.exchangeRateUrl==='https://rates.example/reference.xml','missing URL/version');
 check(row.payment.credentialEnvelope==='retain'&&row.branding.productName==='Custom','operator data changed');
 check(testDb.notificationRuleConfigs.findOne({_id:'existing'}).enabled===false,'job override lost');
 check(testDb.notificationRuleConfigs.countDocuments({})===2&&testDb.exchangeRates.countDocuments({})===1,'defaults missing');
 seeds.i18n_messages[0].value='second';migrate(testDb);check(testDb.i18n_messages.findOne().value==='second','changed package seed not loaded');
 const first=EJSON.stringify(row);migrate(testDb);check(first===EJSON.stringify(testDb.deploymentConfigurations.findOne()),'not idempotent');
 for(const url of ['',null,'https://custom.example/rates']){
  testDb.deploymentConfigurations.updateOne({_id:original._id},{$set:{'payment.exchangeRateUrl':url}});
  migrate(testDb);check(testDb.deploymentConfigurations.findOne().payment.exchangeRateUrl===url,'explicit URL choice overwritten');
 }
 testDb.exchangeRates.updateOne({_id:'default-v1'},{$set:{rates:{EUR:'1',USD:'custom'}}});migrate(testDb);
 check(testDb.exchangeRates.findOne().rates.USD==='custom','existing rate changed');
 check(testDb.users.findOne().name==='retained','user changed');
 testDb.deploymentConfigurations.updateOne({_id:original._id},{$set:{schemaVersion:6}});
 let rejected=false;try{migrate(testDb);}catch(e){rejected=true;}check(rejected,'unsupported schema accepted');
 print('PASS migration006: defaults, custom/null/blank URLs, operator secrets, job overrides, retained rates/users, repeat execution, schema rejection');
}finally{testDb.dropDatabase();}
'''.replace('SOURCE',source).replace('SELECTION',(root/'scripts/release-system-seeds.json').read_text())
if '--print-script' in sys.argv: print(script)
else: subprocess.run(['docker','exec','-i','mongodb','sh','-c','exec mongosh --quiet --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin production_db --file /dev/stdin'],input=script,text=True,check=True)
