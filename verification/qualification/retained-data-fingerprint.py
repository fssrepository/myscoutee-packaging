#!/usr/bin/env python3
"""Read-only production Mongo/media fingerprints before/after a QA package update.
No record values, record IDs, media paths, credentials, or full backups are saved.
"""
import argparse, datetime, hashlib, json, re, subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',required=True,type=Path)
p.add_argument('--compare',type=Path)
p.add_argument('--config', type=Path, required=True)
a=p.parse_args()
qualification=json.loads(a.config.read_text())
config=json.loads((a.config.parent / qualification['releaseProject']).read_text())
if a.output.exists():p.error('Use a new output path')
def run(*args,data=None):return subprocess.check_output(args,input=data,timeout=90)
version=run('dpkg-query','-W','-f=${Version}',config['packageName']).decode().strip()
if not re.fullmatch(r'\d+\.\d+\.\d+(~qa\.[1-9]\d*)?',version):p.error('Stable or QA guest package required')
js=r'''
const crypto=require('crypto');
function canonical(v) {
 if(Array.isArray(v)) return v.map(canonical);
 if(v && typeof v==='object') return Object.fromEntries(Object.keys(v).sort().map(k=>[k,canonical(v[k])]));
 return v;
}
function hash(v) {return crypto.createHash('sha256').update(JSON.stringify(canonical(EJSON.serialize(v,{relaxed:false})))).digest('hex');}
const result={};
for(const name of db.getCollectionNames().sort()) {
 if(name.startsWith('system.'))continue;
 const records={};
 db.getCollection(name).find().forEach(doc=>{
  const fields={};for(const key of Object.keys(doc))fields[key]=hash(doc[key]);
  records[hash(doc._id)]={sha256:hash(doc),fields};
 });
 result[name]={count:Object.keys(records).length,records,indexesSha256:hash(db.getCollection(name).getIndexes())};
}
print(JSON.stringify(result));
'''
collections=json.loads(run('docker','exec','-i',qualification['mongoContainer'],'sh','-c',
 'exec mongosh --quiet --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin "$1" --file /dev/stdin', 'qualification-mongo', qualification['database'],data=js.encode()))
listing=run('docker','exec',qualification['minioContainer'],'sh','-c','exec mc ls --recursive --json "$1/${MEDIA_BUCKET:-$2}/"', 'qualification-media', qualification['mediaAlias'], qualification['mediaBucket']).decode()
media={}
for line in listing.splitlines():
 row=json.loads(line)
 if row.get('status')=='error':raise RuntimeError('Media inventory failed')
 if row.get('type')=='file':
  key=hashlib.sha256(row['key'].encode()).hexdigest()
  media[key]={'etag':row.get('etag'),'size':row['size']}
  if not media[key]['etag']:raise RuntimeError('Media ETag missing')
result={'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'version':version,'database':qualification['database'],
 'collections':collections,'media':media,'scope':'All production document/field hashes and media key/size/ETag. No user dataset copied; ETags are storage fingerprints, not an independent streamed SHA256.'}
if a.compare:
 before=json.loads(a.compare.read_text());changes={}
 for name in sorted(set(before['collections'])|set(collections)):
  old=before['collections'].get(name,{'records':{},'indexesSha256':None});new=collections.get(name,{'records':{},'indexesSha256':None})
  removed=set(old['records'])-set(new['records']);added=set(new['records'])-set(old['records']);modified=[]
  for key in set(old['records'])&set(new['records']):
   x,y=old['records'][key],new['records'][key]
   if x['sha256']!=y['sha256']:
    modified.append({'recordIdHash':key,'fields':[k for k in sorted(set(x['fields'])|set(y['fields'])) if x['fields'].get(k)!=y['fields'].get(k)]})
  if removed or added or modified or old['indexesSha256']!=new['indexesSha256']:
   changes[name]={'removed':sorted(removed),'added':sorted(added),'modified':modified,'indexesChanged':old['indexesSha256']!=new['indexesSha256']}
 result['comparison']={'sourceVersion':before['version'],'collectionChanges':changes,
  'mediaRemoved':sorted(set(before['media'])-set(media)), 'mediaAdded':sorted(set(media)-set(before['media'])),
  'mediaModified':sorted(k for k in set(media)&set(before['media']) if media[k]!=before['media'][k])}
 result['comparison']['exactMatch']=not changes and before['media']==media
with a.output.open('x') as f:json.dump(result,f,indent=2);f.write('\n')
print(json.dumps({'version':version,'collections':len(collections),'documents':sum(c['count'] for c in collections.values()),'mediaObjects':len(media),'output':str(a.output), **({'comparison':result['comparison']} if a.compare else {})}))
