"""Authored transport DATA/real-file tests, UNRUN; no CI or role simulation."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import stat
import tempfile
import unittest
from unittest import mock


_source = Path(__file__).with_name('prepare_hosted_legacy_mcp_inputs.py')
_spec = importlib.util.spec_from_file_location('legacy_mcp_input_data_subject', _source)
subject = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(subject)


def actual_metadata_data():
    # Literal original API fields, not a positive role/build/profile fixture.
    return dict(id=11954047235, name='owner-image-build-fixed-legacy4-38693144742-1',
        size_in_bytes=167333147, expired=False,
        digest='sha256:34d36f0cad321c2d85206a2a7649cb09ad4a4acc1765f91b0bec064df19f286d',
        workflow_run=dict(id=38693144742,
            head_sha='caa6573d8d70f76c8973cc27445e0d9ebf28239a',
            repository_id=1157371341, head_repository_id=1157371341,
            head_branch='codex/owner-image-builds-20261015-001'))


class LegacyMCPInputDataTests(unittest.TestCase):
    def setUp(self):
        # Every future test-created file stays inside the actual account localdev.
        base = Path(pwd.getpwuid(os.geteuid()).pw_dir) / 'localdev'
        self.temporary = tempfile.TemporaryDirectory(prefix='mcp-input-data-test-', dir=base)
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)

    def tearDown(self):
        self.temporary.cleanup()  # This test's exclusive namespace only.

    def test_exact_api_metadata_is_only_validated_data(self):
        metadata = actual_metadata_data()
        original = copy.deepcopy(metadata)
        self.assertIsNone(subject.validate_metadata(metadata))
        self.assertEqual(metadata, original)
        self.assertNotIn('roleSpawnQualified', metadata)
        self.assertNotIn('nativeAuthority', metadata)
        self.assertNotIn('legacySemanticProfileQualified', metadata)

    def test_wrong_artifact_and_original_producer_identity_refused(self):
        for field, value in [('id', 11954047236), ('name', 'other-artifact')]:
            with self.subTest(field=field):
                metadata = actual_metadata_data(); metadata[field] = value
                with self.assertRaises(RuntimeError):
                    subject.validate_metadata(metadata)
        for field, value in [('id', 38693144743), ('head_sha', '0' * 40),
            ('repository_id', 1), ('head_repository_id', 1), ('head_branch', 'main')]:
            with self.subTest(run_field=field):
                metadata = actual_metadata_data(); metadata['workflow_run'][field] = value
                with self.assertRaises(RuntimeError):
                    subject.validate_metadata(metadata)
        metadata = actual_metadata_data(); metadata['workflow_run'] = []
        with self.assertRaises(RuntimeError):
            subject.validate_metadata(metadata)

    def test_digest_expiry_sizes_and_boolean_integer_substitutions_refused(self):
        for field, value in [('digest', 'sha256:' + '0' * 64), ('expired', True),
            ('expired', 0), ('size_in_bytes', 167333146), ('size_in_bytes', True),
            ('size_in_bytes', '167333147'), ('id', True)]:
            with self.subTest(field=field, value=value):
                metadata = actual_metadata_data(); metadata[field] = value
                with self.assertRaises(RuntimeError):
                    subject.validate_metadata(metadata)
        metadata = actual_metadata_data(); metadata['workflow_run']['id'] = True
        with self.assertRaises(RuntimeError):
            subject.validate_metadata(metadata)
        for metadata in [None, [], True]:
            with self.subTest(shape=metadata), self.assertRaises(RuntimeError):
                subject.validate_metadata(metadata)

    def test_duplicate_json_keys_at_any_level_refused(self):
        for raw in ['{"id":1,"id":2}', '{"workflow_run":{"id":1,"id":2}}']:
            with self.subTest(raw=raw), self.assertRaisesRegex(RuntimeError, 'mcp_input_duplicate_json'):
                json.loads(raw, object_pairs_hook=subject.unique)
        self.assertEqual(json.loads('{"id":1,"nested":{"id":2}}', object_pairs_hook=subject.unique),
                         {'id': 1, 'nested': {'id': 2}})

    def test_actual_bounded_regular_read_and_oversize_refusal(self):
        source = self.root/'source.json'
        raw = b'actual source bytes\x00\xff'
        source.write_bytes(raw)
        before = subject.identity(source.lstat())
        self.assertEqual(subject.bounded_bytes(source, len(raw)), raw)
        self.assertEqual(subject.identity(source.lstat()), before)
        with self.assertRaisesRegex(RuntimeError, 'mcp_input_source_type_size'):
            subject.bounded_bytes(source, len(raw)-1)
        self.assertEqual(source.read_bytes(), raw)
        empty = self.root/'empty'; empty.touch()
        self.assertEqual(subject.bounded_bytes(empty, 0), b'')

    def test_actual_alias_directory_fifo_and_hardlink_refused(self):
        source = self.root/'source'; source.write_bytes(b'unchanged')
        alias = self.root/'alias'; alias.symlink_to(source.name)
        directory = self.root/'directory'; directory.mkdir(mode=0o700)
        fifo = self.root/'fifo'; os.mkfifo(fifo, 0o600)
        for path in [alias, directory, fifo]:
            with self.subTest(path=path.name), self.assertRaises(RuntimeError):
                subject.bounded_bytes(path, 1024)
        hard = self.root/'hard'; os.link(source, hard)
        for path in [source, hard]:
            with self.subTest(hardlink=path.name), self.assertRaises(RuntimeError):
                subject.bounded_bytes(path, 1024)
        self.assertEqual(source.read_bytes(), b'unchanged')

    def test_actual_exclusive_receipt_content_mode_and_no_overwrite(self):
        target = self.root/'receipt.json'
        value = dict(schema='test-data-only/1', nativeAuthority=False, values=[1, 'actual bytes'])
        expected = (json.dumps(value, indent=2, sort_keys=True)+'\n').encode()
        receipt = subject.exclusive_receipt(target, value)
        self.assertEqual(target.read_bytes(), expected)
        self.assertEqual(receipt, dict(path=str(target), bytes=len(expected), sha256=hashlib.sha256(expected).hexdigest()))
        self.assertEqual(stat.S_IMODE(target.lstat().st_mode), 0o600)
        first = subject.identity(target.lstat())
        with self.assertRaises(FileExistsError):
            subject.exclusive_receipt(target, {'replacement': True})
        self.assertEqual(target.read_bytes(), expected)
        self.assertEqual(subject.identity(target.lstat()), first)
        too_large = self.root/'oversized.json'
        with self.assertRaisesRegex(RuntimeError, 'mcp_input_receipt_bound'):
            subject.exclusive_receipt(too_large, {'data': 'x' * (1024**2)})
        self.assertFalse(too_large.exists())

    def test_first_write_failure_partial_bytes_and_ambiguous_close_preserved(self):
        target = self.root/'partial.json'
        first_failure = OSError('injected write failure after real partial bytes')
        close_failure = OSError('injected ambiguous close after actual close')
        real_write, real_close = os.write, os.close
        calls = []
        def partial_write(descriptor, body):
            if not calls:
                count = real_write(descriptor, body[:2]); calls.append(count); return count
            raise first_failure
        closed = []
        def close_once(descriptor):
            real_close(descriptor); closed.append(descriptor); raise close_failure
        with mock.patch.object(subject.os, 'write', partial_write), mock.patch.object(subject.os, 'close', close_once):
            with self.assertRaises(OSError) as caught:
                subject.exclusive_receipt(target, {'first': 'retained'})
        self.assertIs(caught.exception, first_failure)
        self.assertIs(caught.exception.__cause__, close_failure)
        self.assertEqual(len(closed), 1)
        self.assertEqual(target.read_bytes(), b'{\n')
        with self.assertRaises(FileExistsError):
            subject.exclusive_receipt(target, {'reset': 'refused'})
        self.assertEqual(target.read_bytes(), b'{\n')
        complete = self.root/'close-failed.json'
        closed.clear()
        with mock.patch.object(subject.os, 'close', close_once):
            with self.assertRaises(OSError) as caught:
                subject.exclusive_receipt(complete, {'data': 'written'})
        self.assertIs(caught.exception, close_failure)
        self.assertEqual(len(closed), 1)
        self.assertEqual(json.loads(complete.read_bytes()), {'data': 'written'})


if __name__ == '__main__':
    unittest.main()
