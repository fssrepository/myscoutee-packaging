#!/usr/bin/env python3
"""Test the deployed native nginx modules in a disposable container."""
import runpy
import os
from pathlib import Path
root=Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()
runpy.run_path(str(root/'nginx/tests/edge-test.py'),run_name='__main__')
