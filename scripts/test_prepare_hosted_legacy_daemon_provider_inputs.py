"""Pure DATA and real-file refusals only: never invoke TLS/guardian main."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

source=Path(__file__).with_name('prepare_hosted_legacy_daemon_provider_inputs.py')
spec=importlib.util.spec_from_file_location('selected_daemon_input_data',source)
selected=importlib.util.module_from_spec(spec);spec.loader.exec_module(selected)
ACTUAL_METADATA={'id': 11970489149, 'node_id': 'MDg6QXJ0aWZhY3QxMTk3MDQ4OTE0OQ==', 'name': 'owner-image-build-provider-history-38731936118-1', 'size_in_bytes': 44913234, 'url': 'https://api.github.com/repos/jsflax/Engram/actions/artifacts/11970489149', 'archive_download_url': 'https://api.github.com/repos/jsflax/Engram/actions/artifacts/11970489149/zip', 'expired': False, 'digest': 'sha256:fae2e7a2f82e99e7b296997b032ffad5c165a15b3eca7bcd44c65d4922810b8c', 'created_at': '2026-10-15T12:21:02Z', 'updated_at': '2026-10-15T12:21:02Z', 'expires_at': '2026-10-29T12:20:56Z', 'workflow_run': {'id': 38731936118, 'repository_id': 1157371341, 'head_repository_id': 1157371341, 'head_branch': 'codex/terminal-collection-provider-20261015-001', 'head_sha': 'caa6573d8d70f76c8973cc27445e0d9ebf28239a'}}

class DaemonProviderInputData(unittest.TestCase):
    def test_actual_original_metadata(self):
        selected.validate_metadata(copy.deepcopy(ACTUAL_METADATA))
    def test_wrong_archive_digest_refuses(self):
        row=copy.deepcopy(ACTUAL_METADATA);row['digest']='sha256:'+'0'*64
        with self.assertRaisesRegex(RuntimeError,'artifact_correspondence'):selected.validate_metadata(row)
    def test_wrong_actual_head_refuses(self):
        row=copy.deepcopy(ACTUAL_METADATA);row['workflow_run']['head_sha']='0'*40
        with self.assertRaisesRegex(RuntimeError,'producer_correspondence'):selected.validate_metadata(row)
    def test_boolean_size_refuses(self):
        row=copy.deepcopy(ACTUAL_METADATA);row['size_in_bytes']=True
        with self.assertRaisesRegex(RuntimeError,'artifact_correspondence'):selected.validate_metadata(row)
    def test_boolean_repository_refuses(self):
        row=copy.deepcopy(ACTUAL_METADATA);row['workflow_run']['repository_id']=True
        with self.assertRaisesRegex(RuntimeError,'producer_correspondence'):selected.validate_metadata(row)
    def test_duplicate_metadata_refuses(self):
        with self.assertRaisesRegex(RuntimeError,'duplicate_json'):
            json.loads('{"id":11970489149,"id":11970489149}',object_pairs_hook=selected.unique)
    def test_real_file_alias_refuses(self):
        with tempfile.TemporaryDirectory(prefix='daemon-input-data-',dir=Path.home()/'localdev') as work:
            root=Path(work);actual=root/'actual';actual.write_bytes(b'original')
            alias=root/'alias';alias.symlink_to(actual)
            with self.assertRaisesRegex(RuntimeError,'source_type_size'):selected.bounded_bytes(alias,64)
            self.assertEqual(actual.read_bytes(),b'original')
    def test_real_first_receipt_never_overwrites(self):
        with tempfile.TemporaryDirectory(prefix='daemon-input-data-',dir=Path.home()/'localdev') as work:
            path=Path(work)/'first.json';first=selected.exclusive_receipt(path,{'first':True})
            with self.assertRaises(FileExistsError):selected.exclusive_receipt(path,{'first':False})
            self.assertEqual(json.loads(path.read_bytes()),{'first':True})
            self.assertEqual(path.stat().st_size,first['bytes'])

if __name__=='__main__':unittest.main()
