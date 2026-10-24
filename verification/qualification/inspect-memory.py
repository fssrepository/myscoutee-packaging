#!/usr/bin/env python3
"""Read-only memory attribution on the designated guest, no configuration writes."""
import argparse,json,subprocess,sys
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('output',type=Path);parser.add_argument('--config',type=Path,required=True);args=parser.parse_args();p=args.output
qualification=json.loads(args.config.read_text())
config=json.loads((args.config.parent / qualification['releaseProject']).read_text())
if p.exists():raise SystemExit('Use a new output file')
def run(*args,data=None):return subprocess.check_output(args,input=data).decode()
r={'javaSmapsRollup':run('docker','exec',qualification['applicationContainer'],'cat','/proc/1/smaps_rollup'),
   'javaStatus':'\n'.join(x for x in run('docker','exec',qualification['applicationContainer'],'cat','/proc/1/status').splitlines() if x.startswith(('VmRSS:','VmPeak:','VmData:','Threads:'))),
   'containerMemoryLimits':run('docker','inspect',qualification['applicationContainer'],qualification['mongoContainer'],qualification['minioContainer'],'--format','{{.Name}} memoryLimit={{.HostConfig.Memory}}')}
js='const c=db.serverStatus().wiredTiger.cache; print(JSON.stringify({currentBytes:Number(c["bytes currently in the cache"]),maxBytes:Number(c["maximum bytes configured"]),dirtyBytes:Number(c["tracked dirty bytes in the cache"])}));'
r['mongoCache']=json.loads(run('docker','exec','-i',qualification['mongoContainer'],'sh','-c','exec mongosh --quiet --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --file /dev/stdin',data=js.encode()))
p.write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r))
