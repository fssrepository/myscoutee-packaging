#!/usr/bin/env python3
"""Exercise the partial image helper without contacting Docker or a server."""
import json,os,shutil,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()
HELPER=ROOT/'config/packaging/node_modules/@fssrepository/myscoutee-packaging/client-tools/install-temporary-frontend.sh'
os.environ.setdefault('MYSCOUTEE_PACKAGING_PROJECT_ROOT',str(ROOT))
OLD='sha256:'+'1'*64
NEW='sha256:'+'2'*64
REF='ghcr.io/fssrepository/myscoutee-nginx@sha256:'+'3'*64
DOCKER=r'''#!/usr/bin/env python3
import io,json,os,sys,tarfile
from pathlib import Path
p=Path(os.environ['MOCK_DOCKER_STATE']);c=json.loads(p.read_text());a=sys.argv[1:]
with open(os.environ['MOCK_DOCKER_LOG'],'a') as f:f.write(json.dumps(a)+'\n')
old='sha256:'+'1'*64;new='sha256:'+'2'*64
server=os.environ.get('MOCK_SERVER_DIR') or os.environ['MYSCOUTEE_SERVER_DIR']
if a[:2]==['compose','version']:print('Docker Compose v2.39.0')
elif a[0]=='inspect':print(json.dumps([{'Image':c['current'],'State':{'Status':c.get('status','running'),'ExitCode':c.get('exitCode',0),'OOMKilled':c.get('oomKilled',False),'Health':{'Status':c.get('health','healthy')}},'Config':{'Labels':{'com.docker.compose.project':'server','com.docker.compose.service':os.environ.get('MOCK_COMPOSE_SERVICE','nginx'),'com.docker.compose.project.working_dir':server,'com.docker.compose.project.config_files':server+'/'+os.environ.get('MOCK_PRIMARY_COMPOSE','docker-compose-prod.yml')+os.environ.get('MOCK_OVERLAY','')}}}]))
elif a[:2]==['image','inspect']:
 image=old if a[2]==old else new
 print(json.dumps([{'Id':image,'Os':'linux','Architecture':'amd64','Config':{'Labels':{'io.myscoutee.service':os.environ.get('MOCK_SERVICE','nginx'),'io.myscoutee.package-version':os.environ.get('MOCK_VERSION','1.0.0'),'io.myscoutee.compatible-package-versions':os.environ.get('MOCK_COMPATIBLE',''),'io.myscoutee.upstream-reference':(os.environ.get('MOCK_UPSTREAM','mongo:8.0.4') if image==new else 'mongo:8.0.4')}}}]))
elif a[0]=='pull':print('Pulled trusted digest')
elif a[0]=='create':print('probe-container')
elif a[0]=='rm':pass
elif a[0]=='cp':
 payload=json.dumps({'version':os.environ.get('MOCK_CONTENT_VERSION',os.environ.get('MOCK_VERSION','1.0.0'))}).encode()
 with tarfile.open(fileobj=sys.stdout.buffer,mode='w|') as t:
  info=tarfile.TarInfo('app-version.json');info.size=len(payload);t.addfile(info,io.BytesIO(payload))
elif a[0]=='compose' and 'config' in a:print(json.dumps({'services':{os.environ.get('MOCK_COMPOSE_SERVICE','nginx'):{'image':os.environ.get('MOCK_INSTALLED_UPSTREAM','mongo:8.0.4')}}}))
elif a[0]=='compose' and 'up' in a:
 key=os.environ.get('MOCK_IMAGE_VAR','NGINX_PRODUCTION_IMAGE')
 configured=next((line.split('=',1)[1] for line in (Path(server)/'.env').read_text().splitlines() if line.startswith(key+'=')),'myscoutee-nginx:1.0.0-prod')
 c.update(status='running',health='healthy',exitCode=0,oomKilled=False)
 image=os.environ.get(key,configured);c['current']=old if image in (old,'myscoutee-nginx:1.0.0-prod') else new;p.write_text(json.dumps(c))
 if c['current']==new and os.environ.get('MOCK_FAIL')=='1':sys.exit(1)
else:raise SystemExit('Unexpected docker invocation '+repr(a))
'''
class TemporaryFrontendTest(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
  self.bin=self.root/'bin';self.bin.mkdir();self.server=self.root/'server';self.server.mkdir()
  for n in ['docker-compose-prod.yml','.env','.env.secrets']:(self.server/n).write_text('unchanged\n')
  for n,body in [('docker',DOCKER),('id','#!/bin/sh\nprintf "0\\n"\n'),('dpkg-query','#!/bin/sh\nprintf "1.0.0"\n')]:
   p=self.bin/n;p.write_text(body);p.chmod(0o755)
  self.mock=self.root/'docker.json';self.mock.write_text(json.dumps({'current':OLD}));self.log=self.root/'calls';self.log.touch()
  self.env={**os.environ,'PATH':str(self.bin)+':'+os.environ['PATH'],'MYSCOUTEE_SERVER_DIR':str(self.server),'MYSCOUTEE_TEMP_FRONTEND_STATE_DIR':str(self.root/'state'),'MOCK_DOCKER_STATE':str(self.mock),'MOCK_DOCKER_LOG':str(self.log)}
 def run_helper(self,*args,ok=True,**env):
  r=subprocess.run(['bash',str(HELPER),*args],env={**self.env,**env},capture_output=True,text=True)
  self.assertEqual(r.returncode==0,ok,r.stdout+'\n'+r.stderr)
  return r
 def test_apply_and_explicit_rollback_preserve_configuration(self):
  self.run_helper('install',REF)
  self.assertEqual(json.loads(self.mock.read_text())['current'],NEW)
  state=json.loads((self.root/'state/state.json').read_text());self.assertEqual(state['phase'],'applied');self.assertEqual(state['previousId'],OLD)
  self.assertTrue(json.loads(self.run_helper('status').stdout)['matchesSelectedImage'])
  self.run_helper('rollback');self.assertEqual(json.loads(self.mock.read_text())['current'],OLD)
  for n in ['docker-compose-prod.yml','.env','.env.secrets']:self.assertEqual((self.server/n).read_text(),'unchanged\n')
  operations=[json.loads(l) for l in self.log.read_text().splitlines()]
  for op in operations:
   if op[0]=='compose' and 'up' in op:
    self.assertIn('--no-deps',op);self.assertIn('--pull',op);self.assertEqual(op[-1],'nginx');self.assertNotIn('down',op)
 def test_failure_rolls_back_and_still_reports_failure(self):
  self.run_helper('install',REF,ok=False,MOCK_FAIL='1')
  self.assertEqual(json.loads(self.mock.read_text())['current'],OLD)
  self.assertEqual(json.loads((self.root/'state/state.json').read_text())['phase'],'rolled-back')
 def test_mutable_tag_is_rejected_before_docker_access(self):
  self.run_helper('install','ghcr.io/fssrepository/myscoutee-nginx:1.0.0',ok=False)
  self.assertEqual(self.log.read_text(),'')
 def test_local_image_uses_same_checks_persistence_and_rollback_without_pull(self):
  self.run_helper('install-local',NEW)
  self.assertIn('NGINX_PRODUCTION_IMAGE='+NEW,(self.server/'.env').read_text())
  self.assertFalse(any(json.loads(line)[0]=='pull' for line in self.log.read_text().splitlines()))
  self.run_helper('rollback')
  self.assertEqual(json.loads(self.mock.read_text())['current'],OLD)
 def test_local_image_refuses_mutable_tags_and_wrong_service(self):
  self.run_helper('install-local','myscoutee-nginx:test',ok=False)
  self.assertEqual(self.log.read_text(),'')
  self.run_helper('install-local',NEW,ok=False,MOCK_SERVICE='registry-demo')
  self.assertEqual(json.loads(self.mock.read_text())['current'],OLD)
 def test_version_change_is_rejected_before_recreation(self):
  self.run_helper('install',REF,ok=False,MOCK_VERSION='2.0.0')
  self.assertEqual(json.loads(self.mock.read_text())['current'],OLD)
  self.assertFalse((self.root/'state/state.json').exists())
 def test_completed_old_package_history_uses_current_package_as_rollback_baseline(self):
  state=self.root/'state';state.mkdir()
  (state/'state.json').write_text(json.dumps({'phase':'applied','version':'0.9.0','project':'server','reference':REF,'previousId':'sha256:'+'4'*64,'targetId':'sha256:'+'5'*64}))
  self.run_helper('install',REF)
  current=json.loads((state/'state.json').read_text())
  self.assertEqual(current['version'],'1.0.0');self.assertEqual(current['previousId'],OLD)
  self.assertEqual(json.loads((state/'previous-operation.json').read_text())['version'],'0.9.0')
  self.run_helper('rollback');self.assertEqual(json.loads(self.mock.read_text())['current'],OLD)
  self.assertEqual((self.server/'.env').read_text(),'unchanged\n')
 def test_stale_history_cannot_adopt_newer_other_or_interrupted_deployments(self):
  state=self.root/'state';state.mkdir()
  for overrides in [{'version':'2.0.0'},{'version':'0.9.0','project':'other'},
                    {'version':'0.9.0','phase':'applying'},{'version':'1.0.0'}]:
   with self.subTest(overrides=overrides):
    record={'phase':'applied','version':'0.9.0','project':'server','previousId':OLD,'targetId':'sha256:'+'5'*64,**overrides}
    original=json.dumps(record);(state/'state.json').write_text(original)
    self.run_helper('install',REF,ok=False)
    self.assertEqual((state/'state.json').read_text(),original)
    self.assertEqual(json.loads(self.mock.read_text())['current'],OLD)
 def test_explicit_cross_version_compatibility_keeps_host_package_and_supports_rollback(self):
  self.run_helper('install',REF,MOCK_VERSION='1.0.2',MOCK_COMPATIBLE='1.0.0,1.0.1')
  self.assertEqual(json.loads(self.mock.read_text())['current'],NEW)
  self.assertEqual(json.loads((self.root/'state/state.json').read_text())['version'],'1.0.0')
  self.run_helper('rollback');self.assertEqual(json.loads(self.mock.read_text())['current'],OLD)
 def test_cross_version_compatibility_requires_exact_valid_version(self):
  for allowed in ['1.0.01','1.0.1','1.0.0,*']:
   self.run_helper('install',REF,ok=False,MOCK_VERSION='1.0.2',MOCK_COMPATIBLE=allowed)
   self.assertEqual(json.loads(self.mock.read_text())['current'],OLD)
 def test_cross_version_frontend_must_match_its_release(self):
  self.run_helper('install',REF,ok=False,MOCK_VERSION='1.0.2',MOCK_COMPATIBLE='1.0.0',MOCK_CONTENT_VERSION='1.0.0')
  self.assertEqual(json.loads(self.mock.read_text())['current'],OLD)
 def test_rollback_does_not_overwrite_a_later_deployment(self):
  self.run_helper('install',REF)
  self.mock.write_text(json.dumps({'current':'sha256:'+'4'*64}))
  self.run_helper('rollback',ok=False)
  self.assertEqual(json.loads(self.mock.read_text())['current'],'sha256:'+'4'*64)
 def test_interrupted_operation_can_be_rolled_back(self):
  self.run_helper('install',REF)
  p=self.root/'state/state.json';c=json.loads(p.read_text());c['phase']='applying';p.write_text(json.dumps(c))
  self.run_helper('rollback');self.assertEqual(json.loads(self.mock.read_text())['current'],OLD)
 def test_each_runtime_service_is_scoped_and_preserves_overlays(self):
  generic=HELPER.with_name('install-temporary-image.sh')
  cases=[('profilemanagement','MYSCOUTEE_PRODUCTION_IMAGE','profilemanagement'),('mongodb','MONGO_IMAGE','mongodb'),('redis','REDIS_IMAGE','redis'),('minio','MINIO_PRODUCTION_IMAGE','minio'),('registry','REGISTRY_DEMO_IMAGE','registry-demo'),('payment-simulator','PAYMENT_SIMULATOR_IMAGE','payment-simulator')]
  overlay=self.server/'docker-compose.replicaset.yml';overlay.write_text('existing overlay')
  for service,var,label in cases:
   with self.subTest(service=service):
    env={**self.env,'MOCK_COMPOSE_SERVICE':service,'MOCK_SERVICE':label,'MOCK_IMAGE_VAR':var,'MOCK_OVERLAY':','+str(overlay),'MYSCOUTEE_TEMP_IMAGE_STATE_DIR':str(self.root/service)}
    self.mock.write_text(json.dumps({'current':OLD}))
    r=subprocess.run(['bash',str(generic),'install',service,REF],env=env,capture_output=True,text=True)
    self.assertEqual(r.returncode,0,r.stderr)
    op=next(json.loads(l) for l in reversed(self.log.read_text().splitlines()) if '"up"' in l)
    self.assertEqual(op[-1],service);self.assertIn(str(overlay),op);self.assertIn('--no-deps',op);self.assertIn('--no-build',op)
 def test_explicit_stopped_api_requires_clean_exit_and_opt_in(self):
  generic=HELPER.with_name('install-temporary-image.sh')
  env={**self.env,'MOCK_COMPOSE_SERVICE':'profilemanagement','MOCK_SERVICE':'profilemanagement','MOCK_IMAGE_VAR':'MYSCOUTEE_PRODUCTION_IMAGE','MYSCOUTEE_TEMP_IMAGE_STATE_DIR':str(self.root/'api-state')}
  for overrides,allowed,opt_in in [({},False,False),({'exitCode':1},False,True),({'oomKilled':True},False,True),({'status':'running'},False,True),({},True,True)]:
   with self.subTest(overrides=overrides,opt_in=opt_in):
    self.mock.write_text(json.dumps({'current':OLD,'status':'exited','health':'unhealthy','exitCode':143,'oomKilled':False,**overrides}))
    r=subprocess.run(['bash',str(generic),'install-local','profilemanagement',NEW],env={**env,'MYSCOUTEE_TEMP_IMAGE_STOPPED_API':str(opt_in).lower()},capture_output=True,text=True)
    self.assertEqual(r.returncode==0,allowed,r.stdout+r.stderr)
  self.assertEqual(json.loads(self.mock.read_text())['current'],NEW)
 def test_stopped_opt_in_does_not_allow_other_services(self):
  self.mock.write_text(json.dumps({'current':OLD,'status':'exited','health':'unhealthy','exitCode':0}))
  self.run_helper('install-local',NEW,ok=False,MYSCOUTEE_TEMP_IMAGE_STOPPED_API='true')
 def test_wrong_service_image_is_rejected(self):
  self.run_helper('install',REF,ok=False,MOCK_SERVICE='registry-demo')
  self.assertEqual(json.loads(self.mock.read_text())['current'],OLD)
 def test_database_version_change_is_rejected(self):
  env={**self.env,'MOCK_COMPOSE_SERVICE':'mongodb','MOCK_SERVICE':'mongodb','MOCK_IMAGE_VAR':'MONGO_IMAGE','MOCK_UPSTREAM':'mongo:9.0.0','MYSCOUTEE_TEMP_IMAGE_STATE_DIR':str(self.root/'db-state')}
  r=subprocess.run(['bash',str(HELPER.with_name('install-temporary-image.sh')),'install','mongodb',REF],env=env,capture_output=True,text=True)
  self.assertNotEqual(r.returncode,0);self.assertEqual(json.loads(self.mock.read_text())['current'],OLD)
 def test_service_restart_reads_persisted_same_version_digest(self):
  self.run_helper('install',REF)
  self.assertIn('NGINX_PRODUCTION_IMAGE='+REF,(self.server/'.env').read_text())
  # Normal startup has no one-shot image environment override.
  subprocess.run(['docker','compose','up','-d','nginx'],env=self.env,check=True)
  self.assertEqual(json.loads(self.mock.read_text())['current'],NEW)
  self.assertTrue(json.loads(self.run_helper('status').stdout)['persistentSelectionMatches'])
 def test_repeated_same_digest_is_idempotent(self):
  self.run_helper('install',REF)
  old=(self.root/'state/state.json').read_text();calls=self.log.read_text().count('"up"')
  self.run_helper('install',REF)
  self.assertEqual((self.root/'state/state.json').read_text(),old)
  self.assertEqual(self.log.read_text().count('"up"'),calls)
 def test_next_patch_rolls_back_to_previous_patch_and_setting(self):
  self.run_helper('install',REF)
  next_ref=REF[:-64]+'5'*64
  self.run_helper('install',next_ref)
  self.assertIn(next_ref,(self.server/'.env').read_text())
  self.run_helper('rollback')
  self.assertIn(REF,(self.server/'.env').read_text())
  self.assertNotIn(next_ref,(self.server/'.env').read_text())
 def test_canonical_environment_symlink_mode_and_other_keys_preserved(self):
  target=self.root/'canonical.env';target.write_text('DOMAIN=example.test\nNGINX_PRODUCTION_IMAGE=myscoutee-nginx:1.0.0-prod\nOTHER=value\n');target.chmod(0o640)
  link=self.server/'.env';link.unlink();link.symlink_to(target)
  self.run_helper('install',REF)
  self.assertTrue(link.is_symlink());self.assertEqual(target.stat().st_mode & 0o777,0o640)
  self.assertIn('DOMAIN=example.test\n',target.read_text());self.assertIn('OTHER=value\n',target.read_text())
  self.run_helper('rollback')
  self.assertEqual(target.read_text(),'DOMAIN=example.test\nNGINX_PRODUCTION_IMAGE=myscoutee-nginx:1.0.0-prod\nOTHER=value\n')
 def test_rollback_does_not_overwrite_later_configuration(self):
  self.run_helper('install',REF)
  (self.server/'.env').write_text('NGINX_PRODUCTION_IMAGE=myscoutee-nginx:1.0.1-prod\n')
  self.run_helper('rollback',ok=False)
  self.assertIn('1.0.1-prod',(self.server/'.env').read_text());self.assertEqual(json.loads(self.mock.read_text())['current'],NEW)
 def test_legacy_runtime_only_update_is_adopted_and_remains_rollbackable(self):
  state=self.root/'state';state.mkdir()
  (state/'state.json').write_text(json.dumps({'phase':'applied','version':'1.0.0','project':'server','reference':REF,'previousId':OLD,'targetId':NEW}))
  self.mock.write_text(json.dumps({'current':NEW}))
  self.run_helper('install',REF)
  self.assertTrue(json.loads(self.run_helper('status').stdout)['persistentSelectionMatches'])
  self.run_helper('rollback');self.assertEqual(json.loads(self.mock.read_text())['current'],OLD)
  self.assertEqual((self.server/'.env').read_text(),'unchanged\n')
 def configured_archive(self):
  bundle=self.root/'client-tools';bundle.mkdir()
  for name in ['install-temporary-image.sh','install-temporary-frontend.sh','client-project.sh']:
   shutil.copy2(HELPER.with_name(name),bundle/name)
  shutil.copy2(ROOT/'build/scripts/release-project.sh',bundle/'release-project.sh')
  policy=json.loads((ROOT/'config/packaging/release-project.json').read_text())
  return bundle,policy
 def test_archive_uses_configured_identity_frontend_and_paths(self):
  bundle,policy=self.configured_archive()
  policy['packageName']='sample-app'
  policy['images'][1].update(service='web',container='custom-web',environment='WEB_IMAGE')
  policy['clientTools'].update(serverDirectory=str(self.server),stateDirectory=str(self.root/'operations'),
    installationPendingFile='upgrade.pending',composeFiles=['compose.release.yml','compose.cluster.yml'],
    services=[{'name':'web','imageService':'web','stateDirectory':'web-updates','frontendVersionFile':'/custom-ui/version.json'}])
  (bundle/'release-project.json').write_text(json.dumps(policy));(bundle/'release-project.json').chmod(0o644)
  (self.server/'docker-compose-prod.yml').rename(self.server/'compose.release.yml')
  overlay=self.server/'compose.cluster.yml';overlay.touch()
  package_log=self.root/'package-calls'
  (self.bin/'dpkg-query').write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "'+str(package_log)+'"\nprintf "1.0.0"\n')
  env={k:v for k,v in self.env.items() if k not in ['MYSCOUTEE_SERVER_DIR','MYSCOUTEE_TEMP_FRONTEND_STATE_DIR']}
  env.update(MOCK_SERVER_DIR=str(self.server),MOCK_COMPOSE_SERVICE='web',MOCK_SERVICE='web',MOCK_IMAGE_VAR='WEB_IMAGE',
    MOCK_PRIMARY_COMPOSE='compose.release.yml',MOCK_OVERLAY=','+str(overlay))
  for args in [('install',REF),('status',),('rollback',)]:
   result=subprocess.run(['bash',str(bundle/'install-temporary-frontend.sh'),*args],env=env,capture_output=True,text=True)
   self.assertEqual(result.returncode,0,result.stdout+result.stderr)
  self.assertIn('sample-app',package_log.read_text())
  self.assertEqual(json.loads((self.root/'operations/web-updates/state.json').read_text())['phase'],'rolled-back')
  self.assertEqual((self.server/'.env').read_text(),'unchanged\n')
  calls=[json.loads(line) for line in self.log.read_text().splitlines()]
  self.assertIn(['cp','probe-container:/custom-ui/version.json','-'],calls)
  self.assertTrue(all(call[1]=='custom-web' for call in calls if call[0]=='inspect'))
  up=[call for call in calls if call[0]=='compose' and 'up' in call]
  self.assertEqual(len(up),2)
  for call in up:
   self.assertEqual(call[-1],'web');self.assertIn(str(overlay),call);self.assertIn(str(self.server/'compose.release.yml'),call)
  # A configured pending-install marker blocks mutation before Docker Compose up.
  (self.root/'operations/upgrade.pending').touch();self.log.write_text('')
  result=subprocess.run(['bash',str(bundle/'install-temporary-frontend.sh'),'install',REF],env=env,capture_output=True,text=True)
  self.assertNotEqual(result.returncode,0);self.assertIn('installation is pending',result.stderr)
  self.assertNotIn('"up"',self.log.read_text())
 def test_archive_database_role_uses_configured_service(self):
  bundle,policy=self.configured_archive()
  policy['clientTools']['services']=[{'name':'storage','container':'custom-storage','environment':'STORAGE_IMAGE','labelService':'storage','sameUpstream':True}]
  (bundle/'release-project.json').write_text(json.dumps(policy));(bundle/'release-project.json').chmod(0o644)
  env={**self.env,'MYSCOUTEE_TEMP_IMAGE_STATE_DIR':str(self.root/'storage-state'),
    'MOCK_COMPOSE_SERVICE':'storage','MOCK_SERVICE':'storage','MOCK_IMAGE_VAR':'STORAGE_IMAGE','MOCK_UPSTREAM':'mongo:9.0.0'}
  result=subprocess.run(['bash',str(bundle/'install-temporary-image.sh'),'install','storage',REF],env=env,capture_output=True,text=True)
  self.assertNotEqual(result.returncode,0);self.assertIn('Database image version differs',result.stderr)
  self.assertNotIn('"up"',self.log.read_text());self.assertEqual(json.loads(self.mock.read_text())['current'],OLD)
if __name__=='__main__':unittest.main()
