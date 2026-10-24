#!/usr/bin/env python3
"""Check projection and project data without starting a service or touching a host."""
import copy
import importlib.util
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PACKAGE = Path(__file__).resolve().parents[2]
WORKSPACE = PACKAGE.parent
spec = importlib.util.spec_from_file_location('runtime_stage', PACKAGE/'release/build/stage-runtime.py')
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)


class RuntimeConfiguration(unittest.TestCase):
    def fixture(self, product='myscoutee-backend'):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        shutil.copytree(WORKSPACE/product/'config/packaging', root/'config/packaging',
                        ignore=shutil.ignore_patterns('node_modules', 'install.env', '*credentials*', '*.local*'))
        return root

    def test_source_selection_is_exact_and_byte_preserving(self):
        for product in ('myscoutee-backend', 'myscoutee-template'):
            root = self.fixture(product)
            names = set(json.loads((root/'config/packaging/runtime-inputs.json').read_text())['files'])
            target = root/'build/scripts'
            selected = staging.stage(root, target)
            self.assertEqual({p.name for p in target.iterdir()}, names)
            for name, source in selected.items():
                self.assertEqual((target/name).read_bytes(), source.read_bytes())
                if name.endswith('.sh'):
                    for peer in re.findall(r'^source "\$\{SCRIPT_DIR\}/([^"$]+)"$', source.read_text(), re.M):
                        self.assertTrue((target/peer).is_file(), (product, name, peer))
            self.assertEqual('ensure-deployment-identity.sh' in selected, product=='myscoutee-backend')
            self.assertEqual('facebook-coming-soon.html' in selected, product=='myscoutee-backend')

    def test_projection_rejects_source_traversal_and_output_symlinks(self):
        root = self.fixture()
        selection_path = root/'config/packaging/runtime-inputs.json'
        original = json.loads(selection_path.read_text())
        for field in ('projectSources', 'packageSources'):
            selection = copy.deepcopy(original)
            selection[field]['start-production.sh'] = '../outside.sh'
            selection_path.write_text(json.dumps(selection))
            with self.assertRaises(ValueError): staging.stage(root, root/'build/scripts')
        selection_path.write_text(json.dumps(original))
        output = root/'output'
        output.symlink_to(root/'config', target_is_directory=True)
        with self.assertRaises(ValueError): staging.stage(root, output)

    def test_registry_defaults_and_numeric_identity_come_from_selected_policy(self):
        root = self.fixture()
        policy_path = root/'config/packaging/release-project.json'
        policy = json.loads(policy_path.read_text())
        policy['hostTools']['registry'].update(serverDirectory='/opt/custom/server',
            keyDirectory='/etc/custom/identity', stateDirectory='/var/lib/custom/receipts')
        policy['runtimeIdentity'] = {'uid': 12001, 'gid': 12002}
        policy_path.write_text(json.dumps(policy))
        staging.stage(root, root/'build/scripts')
        output = subprocess.check_output(['bash', '-ec',
            'source "$1/build/scripts/release-project.sh"; '
            'release_project_load "$1/config/packaging" "$(id -u)"; '
            'source "$1/build/scripts/recovery-project.sh"; SERVER_DIR=/opt/custom/server; '
            'default_registry_key_dir; default_registry_state_dir; '
            'printf "%s:%s\\n" "$RELEASE_PROJECT_UID" "$RELEASE_PROJECT_GID"', '_', str(root)], text=True)
        self.assertEqual(output.splitlines(), ['/etc/custom/identity', '/var/lib/custom/receipts', '12001:12002'])

    def test_facebook_patch_loads_selected_input_and_is_idempotent(self):
        root = self.fixture()
        staging.stage(root, root/'build/scripts')
        bin_dir = root/'bin'; bin_dir.mkdir()
        html = root/'index.html'; html.write_text('<html><body>fixture</body></html>\n')
        docker = bin_dir/'docker'
        docker.write_text('''#!/bin/sh
case "$1" in
 inspect) echo true;;
 cp) case "$2" in *:*) cp "$HTML_INPUT" "$3";; *) cp "$2" "$HTML_INPUT";; esac;;
 exec) :;;
 *) exit 1;;
esac
''')
        docker.chmod(0o755)
        custom = root/'custom.html'; custom.write_text('<!-- myscoutee-facebook-coming-soon-patch:start -->\nCUSTOM\n<!-- myscoutee-facebook-coming-soon-patch:end -->\n')
        env = dict(os.environ, PATH=str(bin_dir)+':'+os.environ['PATH'], HTML_INPUT=str(html),
                   BACKUP_DIR=str(root), NGINX_FACEBOOK_PATCH_FILE=str(custom))
        script = root/'build/scripts/patch-facebook-coming-soon.sh'
        subprocess.run(['bash', str(script)], env=env, check=True, stdout=subprocess.DEVNULL)
        applied = html.read_bytes(); self.assertIn(b'CUSTOM', applied)
        subprocess.run(['bash', str(script)], env=env, check=True, stdout=subprocess.DEVNULL)
        self.assertEqual(html.read_bytes(), applied)
        subprocess.run(['bash', str(script), 'remove'], env=env, check=True, stdout=subprocess.DEVNULL)
        self.assertNotIn(b'CUSTOM', html.read_bytes())


if __name__ == '__main__':
    unittest.main()
