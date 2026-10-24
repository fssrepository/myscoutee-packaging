import { readFileSync as _readContractInputs } from 'node:fs';
import { pathToFileURL as _contractFileURL } from 'node:url';
import { resolve as _contractResolve } from 'node:path';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const root = _contractFileURL(_contractResolve(process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT ?? process.cwd()) + '/');
const contract = JSON.parse(_readContractInputs(new URL('config/packaging/tests/contract-inputs.json', root), 'utf8')).contracts["feedback-access-migration-test"];
const contractInputs = contract.inputs;
const contractExpectations = contract.expectations ?? {};
const read = path => fs.readFileSync(new URL(path, root), 'utf8');
const input = read(contractInputs["seeds_019_feedback_access_policies_accessPolicyDefinitions_json"]);
const targets = JSON.parse(input);
assert.deepEqual(targets, JSON.parse(read(contractInputs["mongodb_myscoutee_db_accessPolicyDefinitions_json"]))
    .filter(row => row.policyKey.startsWith('feedback.')));
assert.equal(targets.length, 4);
const source = read(contractInputs["packaging_migrations_019_feedback_access_policies_js"]);
if (!process.argv.includes('--print-script')) {
    console.log('PASS: pinned Feedback policy upgrade matches the production seed.');
} else console.log(`
const target=db.getSiblingDB('qa_feedback_access_'+new ObjectId().toHexString());
const targets=EJSON.parse(${JSON.stringify(input)});
function run(){const db=target,require=()=>({readFileSync:()=>${JSON.stringify(input)}}),process={env:{MYSCOUTEE_MIGRATION_SEED_DIRECTORY:'/pinned'}};${source}}
function check(ok,message){if(!ok)throw Error(message);}
const snapshot=()=>EJSON.stringify([target.accessPolicyDefinitions.find().sort({_id:1}).toArray(),target.accessGrants.find().sort({_id:1}).toArray()]);
try {
 run();check(target.accessPolicyDefinitions.countDocuments({})===4,'fresh defaults missing');
 const fresh=snapshot();run();check(snapshot()===fresh,'fresh replay changed state');
 target.accessPolicyDefinitions.deleteMany({});
 const old=targets.map(row=>({...row,_id:row._id.replace('policy-feedback','policy-event-feedback'),syncKey:row.syncKey.replace('policy-feedback','policy-event-feedback'),policyKey:'event.'+row.policyKey,permission:'event.'+row.permission}));
 old[0].status='inactive';old[1].required=['noExplicitDeny'];old[1].anyOf=['explicitAllow'];
 target.accessPolicyDefinitions.insertMany(old);
 target.accessGrants.insertMany([
  {_id:'deny',syncKey:'deny',permission:'event.feedback.submit',resourceType:'event',effect:'DENY',subjectUserId:'a',resourceId:'e',expiresAtIso:'2030-01-01T00:00:00Z'},
  {_id:'allow',permission:'event.feedback.note',resourceType:'event',effect:'ALLOW',subjectUserId:'b',resourceId:'e'},
  {_id:'other',permission:'event.edit',resourceType:'event',effect:'DENY'}]);
 const legacy=EJSON.stringify(target.accessPolicyDefinitions.find().sort({_id:1}).toArray());
 run();
 check(target.accessPolicyDefinitions.findOne({policyKey:'feedback.submit'}).status==='inactive','operator inactive selection lost');
 const note=target.accessPolicyDefinitions.findOne({policyKey:'feedback.note'});
 check(JSON.stringify(note.required)==='["noExplicitDeny"]'&&JSON.stringify(note.anyOf)==='["explicitAllow"]','operator restrictions lost');
 const deny=target.accessGrants.findOne({_id:'deny'});
 check(deny.permission==='feedback.submit'&&deny.effect==='DENY'&&deny.expiresAtIso==='2030-01-01T00:00:00Z'&&deny.syncKey==='deny','deny grant or identity lost');
 check(target.accessGrants.findOne({_id:'allow'}).permission==='feedback.note','allow grant not advanced');
 check(target.accessGrants.findOne({_id:'other'}).permission==='event.edit','unrelated grant changed');
 check(EJSON.stringify(target.accessPolicyDefinitions.find({policyKey:/^event\\./}).sort({_id:1}).toArray())===legacy,'legacy policy overwritten');
 const upgraded=snapshot();run();check(snapshot()===upgraded,'upgrade replay changed state');
 target.accessPolicyDefinitions.updateOne({policyKey:'feedback.remove'},{$set:{status:'inactive',permission:'operator.custom'}});
 run();check(target.accessPolicyDefinitions.findOne({policyKey:'feedback.remove'}).permission==='operator.custom','current custom policy overwritten');
 target.accessPolicyDefinitions.deleteOne({policyKey:'feedback.restore'});
 target.accessPolicyDefinitions.insertOne({_id:targets[3]._id,syncKey:targets[3].syncKey,policyKey:'operator.collision'});
 let rejected=false;try{run();}catch(error){rejected=error.message.includes('Conflicting Feedback policy identity');}
 check(rejected,'identity collision accepted');
 print('PASS: fresh/retained Feedback policy upgrade, inactive/custom restrictions, ALLOW/DENY/expiry retention, replay and collision rejection.');
} finally {target.dropDatabase();}
`);
