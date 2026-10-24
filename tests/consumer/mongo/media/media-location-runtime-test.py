#!/usr/bin/env python3
"""Run missing media/locale/location HTTP cases with the existing disabled policy flag."""
import json,os,subprocess,sys,uuid
from pathlib import Path
ROOT=Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd()))
CONTRACT = json.loads((Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'config/packaging/tests/contract-inputs.json').read_text())['contracts']['media-location-runtime-test']
CONTRACT_INPUTS = CONTRACT['inputs']
CONTRACT_EXPECTATIONS = CONTRACT.get('expectations', {})
import os as _runtime_context_os
_runtime_context_os.environ.setdefault('MYSCOUTEE_BACKEND_SOURCE', str(ROOT))
sys.path.insert(0, str(Path(_runtime_context_os.environ.get('MYSCOUTEE_MICROSERVICES_SOURCE', (ROOT).parent / 'myscoutee-microservices')) / 'tools'))
import workloads as w
w.namespace_owned()
original=w.kube_json('-n',w.NAMESPACE,'get','deployment','identity')['spec']['template']['spec']['containers'][0]['env']
backup=ROOT/'.e2e-artifacts/fixtures'/('qa-location-'+uuid.uuid4().hex+'.json')
backup.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
backup.write_text(json.dumps(original));backup.chmod(0o600)
def change(values):
 w.kube('-n',w.NAMESPACE,'scale','deployment/identity','--replicas=0')
 w.kube('-n',w.NAMESPACE,'wait','--for=delete','pod','-l','app.kubernetes.io/name=identity','--timeout=90s')
 w.kube('-n',w.NAMESPACE,'patch','deployment/identity','--type=json','-p',json.dumps([{'op':'replace','path':'/spec/template/spec/containers/0/env','value':values}]))
 w.kube('-n',w.NAMESPACE,'scale','deployment/identity','--replicas=1')
 w.kube('-n',w.NAMESPACE,'rollout','status','deployment/identity','--timeout=120s',timeout=150)
try:
 change([e for e in original if e['name']!='AUTH_REGION_SECURITY_ENABLED']+[{'name':'AUTH_REGION_SECURITY_ENABLED','value':'false'}])
 env=dict(os.environ,E2E_MONGO_TRANSPORT='kvm',E2E_DATABASE=w.CONFIG['databases']['demo'],E2E_SERVER_BASE_URL='http://'+w.vm.IP+':30080',E2E_EXPECT_REGION_SECURITY='false')
 subprocess.run(['node',CONTRACT_INPUTS['media_private_authorization_run_mjs']],cwd=ROOT,env=env,check=True)
finally:
 change(original);backup.unlink()
print('DONE original location policy/runtime restored.',flush=True)
