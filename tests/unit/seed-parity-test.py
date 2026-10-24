"""Shared seed auditing must keep each consumer's policy and delivery boundaries."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[2] / 'release/audit/check-seed-parity.py'
spec = importlib.util.spec_from_file_location('seed_parity', SOURCE)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def fixture(root, catalog):
    seeds = root / 'server/docker/conf/mongodb'
    rule = f'production_db:{catalog},appSettings;myscoutee_db:{catalog},appSettings'
    config = root / 'config/packaging'
    (config / 'templates').mkdir(parents=True)
    (config / 'release-project.json').write_text(json.dumps({'packageName': catalog}))
    (config / 'templates/install-policy.json').write_text(json.dumps({
        'mongoSeedFallback': rule, 'requiredMongoCollections': [catalog, 'appSettings']}))
    (config / f'templates/{catalog}.env').write_text('MONGO_IMPORT_ALLOWED_COLLECTIONS_BY_DB=' + rule)
    for mode in ('demo_db', 'myscoutee_db', 'e2e_db'):
        (seeds / mode).mkdir(parents=True)
        for name in (catalog, 'appSettings', 'users'):
            (seeds / mode / (name + '.json')).write_text(json.dumps(
                [] if name == 'users' else [{'_id': name}]))
    (root / 'server/.env').write_text('MONGO_IMPORT_ALLOWED_COLLECTIONS_BY_DB=' + rule)
    (seeds / 'mongo-seed-policy.inc').write_text(
        'allowed_collections_by_db="${MONGO_IMPORT_ALLOWED_COLLECTIONS_BY_DB:-' + rule + '}"')
    (config / 'tests').mkdir()
    (config / 'tests/release-seeds.json').write_text(json.dumps({
        'schemaVersion': 1, 'inventory': {'shared': [catalog], 'configured': ['appSettings'],
        'runtime': ['users'], 'demoOnlyRuntime': []},
        'parity': {'comparisons': [{'source': 'demo_db', 'target': 'e2e_db', 'collections': [catalog], 'byId': False}]}}))
    return seeds


class SeedParityTest(unittest.TestCase):
    def test_two_consumers_keep_their_own_classification_and_policy_in_one_process(self):
        with tempfile.TemporaryDirectory() as directory:
            for name in ('first', 'second', 'first'):
                root = Path(directory) / name
                if not root.exists():
                    fixture(root, name)
                self.assertEqual([], audit.audit(root))

    def test_missing_duplicate_and_unclassified_inputs_still_fail(self):
        for defect in ('missing', 'duplicate', 'unclassified'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                seeds = fixture(root, 'catalog')
                target = seeds / 'e2e_db/catalog.json'
                if defect == 'missing':
                    target.unlink()
                elif defect == 'duplicate':
                    target.write_text('[{"_id":"same"},{"_id":"same"}]')
                else:
                    (seeds / 'e2e_db/foreign.json').write_text('[]')
                self.assertTrue(audit.audit(root))

    def test_packaged_e2e_inputs_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            seeds = fixture(root, 'catalog')
            self.assertIn('installed Mongo inputs contain E2E fixtures',
                          audit.audit(root, packaged_root=root))
            self.assertTrue((seeds / 'e2e_db/catalog.json').is_file())


if __name__ == '__main__':
    unittest.main()
