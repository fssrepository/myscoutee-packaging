#!/usr/bin/env python3
"""Explicit, independent VMware resource qualification. No installer invokes this.
Run inside the designated guest; --restart explicitly measures myscoutee.service.
Records public identity, memory samples and readiness, never environment values.
"""
import argparse, datetime, json, subprocess, time
from pathlib import Path

def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=20).strip()

def snapshot():
    stats = [json.loads(x) for x in run('docker', 'stats', '--no-stream', '--format', '{{json .}}').splitlines()]
    mem = dict(line.split(':',1) for line in Path('/proc/meminfo').read_text().splitlines())
    return {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'containers': stats, 'hostMemory': {k:mem[k].strip() for k in ('MemTotal','MemAvailable','SwapTotal','SwapFree')}}

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', required=True, type=Path)
p.add_argument('--samples',type=int,default=6)
p.add_argument('--restart',action='store_true')
p.add_argument('--config', type=Path, required=True)
a=p.parse_args()
qualification=json.loads(a.config.read_text())
config=json.loads((a.config.parent / qualification['releaseProject']).read_text())
if not 1 <= a.samples <= 60: p.error('samples must be 1..60')
if a.output.exists(): p.error('Use a new output file')
version=run('dpkg-query','-W','-f=${Version}',config['packageName'])
if '~qa.' not in version: p.error('This runner currently permits only a QA guest')
containers=json.loads(run('docker','inspect',*run('docker','ps','-q').split()))
r={'startedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'packageVersion':version,
   'cpuCount':run('nproc'),'kernel':run('uname','-r'),
   'containers':[{'name':c['Name'],'image':c['Config']['Image'],'imageId':c['Image'],
                  'networks':list(c['NetworkSettings']['Networks']), 'ports':c['NetworkSettings']['Ports']} for c in containers],
   'idleSamples':[], 'restartSamples':[], 'note':'Docker working-set samples, not exact peak RSS or JVM heap; ordinary warm restart, not host cold boot.'}
def save(): a.output.write_text(json.dumps(r,indent=2)+'\n')
for _ in range(a.samples):
    r['idleSamples'].append(snapshot());save();time.sleep(3)
if a.restart:
    start=time.monotonic()
    proc=subprocess.Popen(['systemctl','restart',qualification['service']],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    while time.monotonic()-start < 420:
        r['restartSamples'].append(snapshot());save()
        if proc.poll() is not None:
            if proc.returncode: r['restartFailure']='systemctl exit '+str(proc.returncode);break
            health=run('docker','inspect','--format','{{.State.Health.Status}}',qualification['applicationContainer'])
            if health=='healthy':
                r['restartToHealthySeconds']=round(time.monotonic()-start,2);break
        time.sleep(2)
    else: r['restartFailure']='420s readiness deadline; no process killed'
    r['systemdPhases']=run('systemctl','show',qualification['service'],'-p','ExecStartPre','-p','ExecMainStartTimestamp','-p','ActiveEnterTimestamp')
    r['postRestart']=snapshot();save()
print(json.dumps({'output':str(a.output),'packageVersion':version,'idleSamples':len(r['idleSamples']),
                  'restartToHealthySeconds':r.get('restartToHealthySeconds'),'error':r.get('restartFailure')}))
