#!/usr/bin/env python3
"""Preserve all original service/account files while extracting project values."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('renderer',ROOT/'release/build/render-debian.py')
renderer=importlib.util.module_from_spec(spec);spec.loader.exec_module(renderer)
FIXTURES=json.loads((ROOT/'tests/fixtures/service-manager-products.json').read_text())


class ServiceManager(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup)
        self.root=Path(temp.name);self.packaging=self.root/'packaging';self.packaging.mkdir()
        self.config=self.root/'config/packaging';self.config.mkdir(parents=True)
        self.select('myscoutee-backend')

    def select(self,product):
        self.product=copy.deepcopy(FIXTURES[product])
        self.write('release-project.json',self.product['release'])
        self.write('systemd.json',self.product['systemd'])

    def write(self,name,value): (self.config/name).write_text(json.dumps(value))

    def test_all_twenty_original_files_are_byte_identical(self):
        for product in FIXTURES:
            self.select(product)
            for component,expected in self.product['files'].items():
                actual=renderer.render_host_files(self.packaging,component)
                self.assertEqual(set(actual),set(expected))
                for name,digest in expected.items():
                    self.assertEqual(hashlib.sha256(actual[name].encode()).hexdigest(),digest,(product,name))

    def test_identity_and_display_configuration_only_change_their_values(self):
        before=renderer.render_host_files(self.packaging,'systemd')
        self.product['release']['packageName']='another-product'
        self.product['release']['runtimeIdentity']={'uid':12000,'gid':12000}
        self.write('release-project.json',self.product['release'])
        self.write('systemd.json',{'schemaVersion':1,'displayName':'Another Product'})
        actual=renderer.render_host_files(self.packaging,'systemd')
        for name,body in before.items():
            filename=name.replace('myscoutee','another-product',1)
            expected=body.replace('/packaging/scripts/myscoutee','/packaging/scripts/PROTECTED').replace('/run/myscoutee-update-reader','/run/READER')
            expected=expected.replace('MyScoutee','Another Product').replace('myscoutee','another-product').replace('/packaging/scripts/PROTECTED','/packaging/scripts/myscoutee').replace('/run/READER','/run/myscoutee-update-reader')
            self.assertEqual(actual[filename],expected)
        self.assertIn('u another-product-runtime 12000 "Another Product runtime"',renderer.render_host_files(self.packaging,'sysusers')['another-product.conf'])

    def test_unsafe_or_unexpected_configuration_is_rejected(self):
        for value in ('Bad\nExecStart=/bin/false','"break"','$(command)',''):
            self.write('systemd.json',{'schemaVersion':1,'displayName':value})
            with self.assertRaises(ValueError):renderer.render_host_files(self.packaging,'systemd')
        self.write('systemd.json',{'schemaVersion':1,'displayName':'Good','other':1})
        with self.assertRaises(ValueError):renderer.render_host_files(self.packaging,'systemd')

    def test_cli_preserves_non_executable_file_modes(self):
        for component in ('systemd','sysusers'):
            output=self.root/component
            subprocess.run(['python3',str(ROOT/'release/build/render-debian.py'),str(self.packaging),str(output),'--component',component],check=True)
            for path in output.iterdir():self.assertEqual(path.stat().st_mode&0o777,0o644)


if __name__=='__main__': unittest.main()
