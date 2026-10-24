#!/usr/bin/env python3
"""Test host identity migration with real Linux accounts in an isolated container.

No application server, host account or deployment data is started or changed.
The systemctl double records service ordering; passwd and filesystem operations
are real Ubuntu tools from the already-used Mongo runtime image.
"""
import json
import re
import subprocess
import tempfile
import os
from pathlib import Path

ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()
source = subprocess.check_output(['python3', str(ROOT / 'config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py'), str(ROOT / 'packaging'), '-', '--hook', 'postinst'], text=True)
function = re.search(r'^migrate_runtime_identity\(\) \{\n.*?^\}', source, re.M | re.S).group()
preinst = subprocess.check_output(['python3', str(ROOT / 'config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py'), str(ROOT / 'packaging'), '-', '--hook', 'preinst'], text=True)
preinst = re.sub(r'^TARGET_(UID|GID)=\d+$', r'TARGET_\1=10002', preinst, flags=re.M)
script = r"""set -euo pipefail
export PACKAGE_NAME=myscoutee-template MYSCOUTEE_API_UID=10002 MYSCOUTEE_API_GID=10002
export PACKAGE_ETC=/etc/myscoutee-template PACKAGE_STATE=/var/lib/myscoutee-template
export PACKAGE_CACHE=/var/cache/myscoutee-template-update PACKAGE_LOG=/var/log/myscoutee-template
export PACKAGE_ROOT=/opt/myscoutee-template INSTALL_POLICY=/test/policy.json DPKG_MAINTSCRIPT_PACKAGE=myscoutee-template
mkdir -p /test-bin "$PACKAGE_ETC" "$PACKAGE_STATE" "$PACKAGE_CACHE" "$PACKAGE_LOG" "$PACKAGE_ROOT"
cat > /test-bin/systemctl <<'SH'
#!/bin/sh
if [ "$1" = is-active ]; then exit "${TEST_WORKER_INACTIVE:-1}"; fi
printf '%s\n' "$*" >> /tmp/systemctl-trace
SH
mkdir -p "$PACKAGE_ROOT/packaging/scripts"
printf '#!/bin/sh\nprintf "old-compose-down\\n" >> /tmp/systemctl-trace\n' > "$PACKAGE_ROOT/packaging/scripts/stop-production.sh"
chmod +x "$PACKAGE_ROOT/packaging/scripts/stop-production.sh"
chmod +x /test-bin/systemctl
export PATH=/test-bin:$PATH
groupadd -g 10001 myscoutee-template-runtime
useradd -M -u 10001 -g 10001 -s /usr/sbin/nologin myscoutee-template-runtime
printf 'retained\n' > "$PACKAGE_STATE/document"
chown 10001:10001 "$PACKAGE_STATE/document"
printf 'secret\n' > "$PACKAGE_ETC/key"
chown 0:10001 "$PACKAGE_ETC/key"; chmod 0640 "$PACKAGE_ETC/key"
printf 'mongo\n' > "$PACKAGE_STATE/mongo"
chown 999:999 "$PACKAGE_STATE/mongo"
printf 'external\n' > /tmp/external
chown 10001:10001 /tmp/external
ln -s /tmp/external "$PACKAGE_STATE/link"
chown -h 10001:10001 "$PACKAGE_STATE/link"
sha256sum "$PACKAGE_STATE/document" "$PACKAGE_ETC/key" "$PACKAGE_STATE/mongo" /tmp/external > /tmp/hashes
# A live old worker must be rejected before shutdown or account mutation.
if TEST_WORKER_INACTIVE=0 bash /test/preinst upgrade 1.0.0; then exit 10; fi
test ! -e /tmp/systemctl-trace
# A foreign target account must also remain untouched.
groupadd -g 10002 foreign-runtime
useradd -M -u 10002 -g 10002 foreign-runtime
if bash /test/preinst upgrade 1.0.0; then exit 11; fi
test "$(id -u foreign-runtime)" = 10002; test ! -e /tmp/systemctl-trace
userdel foreign-runtime; getent group foreign-runtime >/dev/null && groupdel foreign-runtime
bash /test/preinst upgrade 1.0.0
grep -q '^stop myscoutee-template.service' /tmp/systemctl-trace
source /test/function.sh
migrate_runtime_identity 1.0.0
test "$(id -u myscoutee-template-runtime):$(id -g myscoutee-template-runtime)" = 10002:10002
test "$(stat -c %u:%g "$PACKAGE_STATE/document")" = 10002:10002
test "$(stat -c %u:%g:%a "$PACKAGE_ETC/key")" = 0:10002:640
test "$(stat -c %u:%g "$PACKAGE_STATE/mongo")" = 999:999
test "$(stat -c %u:%g /tmp/external)" = 10001:10001
sha256sum -c /tmp/hashes
# An interrupted file pass is completed by the same versioned migration.
chown 10001:10001 "$PACKAGE_STATE/document"
migrate_runtime_identity 1.0.0
test "$(stat -c %u:%g "$PACKAGE_STATE/document")" = 10002:10002
migrate_runtime_identity 1.0.0
sha256sum -c /tmp/hashes
# Once migrated, preinst does not stop an ordinary same-identity upgrade.
rm /tmp/systemctl-trace
bash /test/preinst upgrade 1.4.0
test ! -e /tmp/systemctl-trace
printf 'PASS: real account migration, content/modes, scoped ownership, collision rejection, worker gate and interruption retry\n'
"""
with tempfile.TemporaryDirectory(prefix='runtime-identity-test-') as temp:
    root = Path(temp)
    (root / 'function.sh').write_text(function)
    (root / 'preinst').write_text(preinst)
    (root / 'policy.json').write_text(json.dumps({'runtimeIdentityMigrations': [{'maximumVersion':'1.0.0','uid':10001,'gid':10001}]}))
    (root / 'test.sh').write_text(script)
    subprocess.run(['docker','run','--rm','--network','none','--user','0','--entrypoint','bash',
                    '-v',str(root)+':/test:ro','mongo:8.0.4','/test/test.sh'], check=True)
