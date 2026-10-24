"""Check project selection without contacting Docker, a guest, or a database."""
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[2] / 'verification/qualification'


class QualificationTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'release-project.json').write_text(json.dumps({'packageName': 'selected-product'}))
        self.config = self.root / 'qualification.json'
        self.config.write_text(json.dumps({
            'releaseProject': 'release-project.json', 'applicationContainer': 'selected-java',
            'mongoContainer': 'selected-mongo', 'minioContainer': 'selected-media',
            'database': 'selected_db', 'mediaAlias': 'selected-alias', 'mediaBucket': 'selected-bucket',
            'service': 'selected-product.service'}))

    def execute(self, name, arguments, output):
        with patch('sys.argv', [name, '--config', str(self.config), *arguments]), \
                patch('subprocess.check_output', side_effect=output) as commands, \
                redirect_stdout(io.StringIO()):
            runpy.run_path(str(SOURCE / name), run_name='__main__')
        return [call.args[0] for call in commands.call_args_list]

    def test_memory_inspection_uses_only_selected_container_names(self):
        def output(command, **kwargs):
            return b'{}' if 'mongosh' in command[-1] else b'fixture'

        result = self.root / 'memory.json'
        commands = self.execute('inspect-memory.py', [str(result)], output)
        self.assertEqual(['selected-java', 'selected-java', 'selected-java'],
                         [command[2] for command in commands[:3]])
        self.assertEqual('selected-mongo', commands[3][3])
        self.assertEqual(('selected-java', 'selected-mongo', 'selected-media'), commands[2][2:5])
        self.assertEqual({}, json.loads(result.read_text())['mongoCache'])

    def test_data_fingerprint_keeps_selected_database_and_media_scope(self):
        def output(command, **kwargs):
            if command[0] == 'dpkg-query':
                self.assertEqual('selected-product', command[-1])
                return b'1.0.0~qa.1'
            if 'selected-mongo' in command:
                self.assertEqual('selected_db', command[-1])
                return b'{}'
            self.assertEqual('selected-media', command[2])
            self.assertEqual(('selected-alias', 'selected-bucket'), command[-2:])
            return b''

        result = self.root / 'fingerprint.json'
        self.execute('retained-data-fingerprint.py', ['--output', str(result)], output)
        self.assertEqual('selected_db', json.loads(result.read_text())['database'])

    def test_runtime_measurement_binds_identity_without_starting_a_service(self):
        def output(command, **kwargs):
            if command[0] == 'dpkg-query':
                self.assertEqual('selected-product', command[-1])
                return '1.0.0~qa.1'
            if command[:2] == ('docker', 'ps'):
                return 'fixture-id'
            if command[:2] == ('docker', 'inspect'):
                return json.dumps([{'Name': 'selected-java', 'Config': {'Image': 'fixture-image'},
                                    'Image': 'fixture-id', 'NetworkSettings': {'Networks': {}, 'Ports': {}}}])
            if command[:2] == ('docker', 'stats'):
                return '{}'
            return 'fixture'

        result = self.root / 'runtime.json'
        with patch('time.sleep'), patch('subprocess.Popen') as start:
            self.execute('measure-runtime.py', ['--output', str(result), '--samples', '1'], output)
        start.assert_not_called()
        self.assertEqual('1.0.0~qa.1', json.loads(result.read_text())['packageVersion'])


if __name__ == '__main__':
    unittest.main()
