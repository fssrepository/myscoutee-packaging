#!/usr/bin/env python3
"""Bounded QA JVM idle-heap experiment; restore the original manageable flag.

Run on the designated QA guest as root. Requires the small host jattach tool.
No restart, heap dump, DB mutation, or permanent runtime configuration change.
"""
import argparse
import datetime
import json
import re
import signal
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--config', type=Path, required=True)
args = parser.parse_args()
qualification=json.loads(args.config.read_text())
config=json.loads((args.config.parent / qualification['releaseProject']).read_text())
if args.output.exists():
    parser.error('Use a new evidence path')

def run(*command):
    return subprocess.check_output(command, text=True, timeout=10)

version = run('dpkg-query', '-W', '-f=${Version}', config['packageName']).strip()
if '~qa.' not in version:
    raise SystemExit('Only a QA Debian package is eligible for this experiment')
pid = run('docker', 'inspect', qualification['applicationContainer'], '--format', '{{.State.Pid}}').strip()
flags = run('jattach', pid, 'jcmd', 'VM.flags -all')
match = re.search(r'G1PeriodicGCInterval\s*=\s*(\d+)', flags)
if not match or not re.search(r'G1PeriodicGCInvokesConcurrent\s*=\s*true', flags):
    raise SystemExit('Expected G1 concurrent periodic collection flags are absent')
original = match.group(1)
result = {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'packageVersion': version, 'pid': int(pid), 'originalIntervalMs': int(original),
          'trialIntervalMs': 30000, 'samples': [], 'restored': False,
          'scope': 'Live user activity may vary; idle heap attribution, not a load or latency benchmark.'}

def alive():
    if run('docker', 'inspect', qualification['applicationContainer'], '--format', '{{.State.Pid}}').strip() != pid:
        raise RuntimeError('Container process changed during measurement')

def flag(value):
    alive()
    output = run('jattach', pid, 'setflag', 'G1PeriodicGCInterval', str(value))
    if 'JVM response code = 0' not in output:
        raise RuntimeError('JVM did not accept the diagnostic flag')

started = time.monotonic()
def sample(phase):
    alive()
    status = Path(f'/proc/{pid}/status').read_text()
    heap = run('jattach', pid, 'jcmd', 'GC.heap_info')
    row = {'phase': phase, 'elapsedSeconds': round(time.monotonic()-started, 2),
           'rssKiB': int(re.search(r'VmRSS:\s+(\d+)', status).group(1)),
           'heapInfo': heap.split('JVM response code = 0', 1)[-1].strip()}
    result['samples'].append(row)
    print(json.dumps(row), flush=True)

def interrupted(signum, frame):
    raise KeyboardInterrupt(f'Signal {signum}')
signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
try:
    sample('baseline')
    time.sleep(15)
    sample('baseline')
    flag(30000)
    for _ in range(7):
        time.sleep(10)
        sample('periodic-gc')
finally:
    try:
        flag(original)
        check = run('jattach', pid, 'jcmd', 'VM.flags -all')
        result['restored'] = bool(re.search(r'G1PeriodicGCInterval\s*=\s*'+original+r'\b', check))
    finally:
        args.output.write_text(json.dumps(result, indent=2)+'\n')
    if not result['restored']:
        raise RuntimeError('Original flag restoration could not be verified')
print(json.dumps({'output': str(args.output), 'restored': result['restored']}))
