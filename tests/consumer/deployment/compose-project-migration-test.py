#!/usr/bin/env python3
"""The installed Compose owner may migrate its own project, never a foreign one."""
from pathlib import Path
import os,re,subprocess,tempfile
ROOT=Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()
source=(ROOT/'build/scripts/myscoutee-compose.sh').read_text()
function=re.search(r'^ensure_installed_compose_project\(\) \{\n.*?^\}',source,re.M|re.S).group()
harness=r"""
RELEASE_PROJECT_ROOT=/opt/myscoutee-template
SERVER_DIR=$RELEASE_PROJECT_ROOT/server
if [[ "$CASE" == checkout ]]; then SERVER_DIR=/workspace/server; fi
run_compose() {
  if [[ "$1" == config ]]; then printf '{"name":"myscoutee-template"}\n'; else printf '%s\n' "$*" >> "$TRACE"; fi
}
docker() {
  case "$1 $2" in
    'ps -a')
      case "$CASE" in none|checkout) :;; current) echo myscoutee-template;; *) echo server;; esac;;
    'ps -aq') printf 'first\nsecond\n';;
    'inspect --format')
      if [[ "$CASE" == foreign && "$4" == second ]]; then echo /opt/other/server; else echo "$SERVER_DIR"; fi;;
    *) return 90;;
  esac
}
ensure_installed_compose_project
"""
with tempfile.TemporaryDirectory(prefix='compose-project-test-') as temp:
 for case in ['none','current','legacy','foreign','checkout']:
  trace=Path(temp)/case;env=dict(os.environ,CASE=case,TRACE=str(trace))
  result=subprocess.run(['bash','-euc',function+'\n'+harness],env=env,capture_output=True,text=True)
  assert (result.returncode==0)==(case!='foreign'),(case,result.stderr)
  assert (trace.read_text() if trace.exists() else '')==('--project-name server down\n' if case=='legacy' else ''),case
print('PASS: owned legacy project migration, current/source no-op, foreign project rejection, no volume removal')
