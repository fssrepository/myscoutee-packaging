#!/usr/bin/env python3
"""Run the route generator bundled in the pinned shared nginx image."""
import json
import os
from pathlib import Path
import subprocess
root = Path(os.environ['MYSCOUTEE_PACKAGING_PROJECT_ROOT']).resolve()
defaults = json.loads((Path(__file__).resolve().parent.parent / 'lib/defaults.json').read_text())
settings = json.loads((root / 'config/packaging/release/settings.json').read_text())
image = os.environ.get('NGINX_BASE_IMAGE', settings.get('build', {}).get('nginxNativeImage', defaults['build']['nginxNativeImage']))
source = subprocess.check_output(['docker', 'run', '--rm', '--network=none',
    '--entrypoint', 'cat', image, '/opt/myscoutee-nginx/tools/render-routes.py'], text=True)
exec(compile(source, image + '/tools/render-routes.py', 'exec'),
     {'PROJECT_ROOT': root, '__name__': '__main__'})
