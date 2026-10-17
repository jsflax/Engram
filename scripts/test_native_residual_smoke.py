"""Fast harness guards; no native executable, provider, or live resources."""
from pathlib import Path
import contextlib
import json
import os
import sqlite3
import tempfile
import unittest
import uuid
import native_residual_smoke as H

HERE = Path(__file__).resolve().parent


class NativeResidualHarnessTests(unittest.TestCase):
    def setUp(self):
        parent = Path(os.environ.get('ENGRAM_NATIVE_RESIDUAL_TEST_ROOT', str(HERE / '.tmp')))
        parent.mkdir(mode=0o700, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=parent)
        self.base = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def database(self):
        store = self.base / 'memory.sqlite'
        receipt = {'version': 1, 'operationID': str(uuid.uuid4()), 'outcome': 'applied',
                   'memoryIDs': [str(uuid.uuid4())], 'edgeIDs': []}
        with contextlib.closing(sqlite3.connect(store)) as db:
            db.executescript('CREATE TABLE Memory(globalId TEXT COLLATE NOCASE UNIQUE, content TEXT, embedding BLOB);'
                'CREATE TABLE Edge(id INTEGER); CREATE TABLE EngramOperationReceiptV1(operationID TEXT, receiptJSON TEXT);')
            db.execute('INSERT INTO Memory VALUES(?,?,?)', (receipt['memoryIDs'][0], 'bootstrap', b'exact embedding'))
            db.execute('INSERT INTO EngramOperationReceiptV1 VALUES(?,?)',
                       (receipt['operationID'], json.dumps(receipt)))
            db.commit()
        return store, receipt

    def snapshot(self, store):
        return (H.rows(store, 'SELECT * FROM Memory'), H.rows(store, 'SELECT * FROM EngramOperationReceiptV1'))

    def test_work_dir_is_fresh_private_and_existing_path_is_never_reused(self):
        selected = H.create_work_dir(self.base / 'work')
        self.assertEqual(selected.stat().st_mode & 0o777, 0o700)
        with self.assertRaisesRegex(H.GateFailure, 'not_fresh'):
            H.create_work_dir(selected)

    def test_symlink_and_non_private_parent_are_refused(self):
        linked = self.base / 'linked'
        linked.symlink_to(self.base, target_is_directory=True)
        with self.assertRaisesRegex(H.GateFailure, 'not_canonical'):
            H.create_work_dir(linked / 'work')
        parent = self.base / 'unsafe'; parent.mkdir(mode=0o700); parent.chmod(0o777)
        with self.assertRaisesRegex(H.GateFailure, 'not_owned'):
            H.create_work_dir(parent / 'work')
        self.assertFalse((parent / 'work').exists())

    def test_seed_changes_only_known_fields_and_known_receipt(self):
        store, receipt = self.database()
        expected = {'globalId': str(uuid.uuid4()), 'content': 'synthetic historical append'}
        H.seed_preserved_row(store, expected, receipt)
        self.assertEqual(H.rows(store, 'SELECT * FROM Memory'),
                         [(expected['globalId'], expected['content'], b'exact embedding')])
        self.assertEqual(H.rows(store, 'SELECT * FROM EngramOperationReceiptV1'), [])

    def test_seed_refuses_extra_row_before_mutation(self):
        store, receipt = self.database()
        with contextlib.closing(sqlite3.connect(store)) as db:
            db.execute('INSERT INTO Memory VALUES(?,?,?)', (str(uuid.uuid4()), 'other', b'other'))
            db.commit()
        before = self.snapshot(store)
        with self.assertRaisesRegex(H.GateFailure, 'row_count'):
            H.seed_preserved_row(store, {'globalId': str(uuid.uuid4())}, receipt)
        self.assertEqual(self.snapshot(store), before)

    def test_seed_refuses_unknown_receipt_and_rolls_back_wrong_memory(self):
        store, receipt = self.database()
        before = self.snapshot(store)
        altered = {**receipt, 'operationID': str(uuid.uuid4())}
        with self.assertRaisesRegex(H.GateFailure, 'receipt_changed'):
            H.seed_preserved_row(store, {'content': 'not written'}, altered)
        self.assertEqual(self.snapshot(store), before)
        altered = {**receipt, 'memoryIDs': [str(uuid.uuid4())]}
        with contextlib.closing(sqlite3.connect(store)) as db:
            db.execute('UPDATE EngramOperationReceiptV1 SET receiptJSON=?', (json.dumps(altered),))
            db.commit()
        before = self.snapshot(store)
        with self.assertRaisesRegex(H.GateFailure, 'memory_changed'):
            H.seed_preserved_row(store, {'content': 'not written'}, altered)
        self.assertEqual(self.snapshot(store), before)

    def test_seed_refuses_extra_receipt_before_mutation(self):
        store, receipt = self.database()
        with contextlib.closing(sqlite3.connect(store)) as db:
            db.execute('INSERT INTO EngramOperationReceiptV1 VALUES(?,?)', (str(uuid.uuid4()), '{}'))
            db.commit()
        before = self.snapshot(store)
        with self.assertRaisesRegex(H.GateFailure, 'receipt_count'):
            H.seed_preserved_row(store, {'content': 'not written'}, receipt)
        self.assertEqual(self.snapshot(store), before)


if __name__ == '__main__':
    unittest.main()
