"""V2 admission fixtures; native identity calls are replaced by an explicit oracle.

These tests qualify binding/lifecycle logic, not Darwin volume persistence. The
real extractor and owned-volume remount qualification have independent tests.
"""
import contextlib
import copy
import importlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import test_frontier as F

HOST = TRANSCRIPT = IDENTITY = None
VOLUME = '11111111-2222-4333-8444-555555555555'
OTHER_VOLUME = '22222222-3333-4444-8555-666666666666'


def setUpModule():
    global HOST, TRANSCRIPT, IDENTITY
    F.setUpModule()
    HOST = importlib.import_module(F.PACKAGE + '.host_admission')
    TRANSCRIPT = importlib.import_module(F.PACKAGE + '.transcript')
    IDENTITY = importlib.import_module(F.PACKAGE + '.file_identity')


def tearDownModule():
    F.tearDownModule()


class DeviceNumber:
    def __init__(self, value, delta):
        self.value, self.delta = value, delta

    def __getattr__(self, name):
        return getattr(self.value, name) + self.delta if name == 'st_dev' else getattr(self.value, name)


class HostV2Tests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='v2-admission-')
        self.addCleanup(temp.cleanup)
        self.fixture = F.Fixture(Path(temp.name).resolve())
        self.f = self.fixture
        self.capture = mock.patch.object(IDENTITY, 'capture_fd', side_effect=self.identity)
        self.capture.start()
        self.addCleanup(self.capture.stop)
        self.policy = {'schema_version': 2, 'mode': HOST.MODE_V2, 'enabled': True,
                       'activation_id': F.ACTIVATION, 'cutoff': F.CUTOFF,
                       'state_dir': str(self.f.root),
                       'sessions_dir': F.ADMISSION._directory_binding(self.f.sessions, stable_identity=True)}
        self.save_policy()

    def identity(self, fd):
        return {'scheme': IDENTITY.SCHEME, 'volume_uuid': VOLUME, 'inode': os.fstat(fd).st_ino}

    def save_policy(self):
        F.write_json(self.f.policy_path, self.policy)

    def enroll(self, event='SessionStart', **changes):
        return HOST.observe(self.f.root, {**self.f.payload, 'hook_event_name': event, **changes})

    def entry_path(self):
        return self.f.root / 'enrollments' / (self.f.sid + '.json')

    def entry(self):
        return json.loads(self.entry_path().read_text())

    def request(self):
        value = self.entry()
        return {'session_id': self.f.sid, 'hook_session_id': self.f.sid,
                'event': 'Stop', 'turn_id': F.TURN2, 'cwd': str(self.f.project),
                'hook_cwd': str(self.f.project), 'transcript_path': str(self.f.path),
                'identity': value['identity']}

    def hold(self, kind='file'):
        parent = F.private_directory(self.f.root / 'migration-holds')
        path = parent / (self.f.sid + '.json')
        if kind == 'file':
            F.write_json(path, {'opaque': True})
        elif kind == 'symlink':
            path.symlink_to(self.f.root / 'missing-target')
        elif kind == 'directory':
            path.mkdir(mode=0o700)
        return path

    @contextlib.contextmanager
    def renumbered(self):
        original_fstat, original_stat = os.fstat, Path.stat
        with mock.patch.object(os, 'fstat', side_effect=lambda fd: DeviceNumber(original_fstat(fd), 2)), \
                mock.patch.object(Path, 'stat', autospec=True,
                                  side_effect=lambda path, **kwargs: DeviceNumber(original_stat(path, **kwargs), 2)):
            yield

    def test_v2_origin_and_binding_have_only_stable_identity(self):
        self.assertEqual(self.enroll(), (self.f.sid, True, False))
        entry = self.entry()
        self.assertEqual(set(entry['project']), {'path', 'identity'})
        self.assertIn('identity', entry)
        self.assertNotIn('device', entry)
        self.assertNotIn('inode', entry)
        binding = F.ADMISSION.check(self.f.root, self.request())
        self.assertEqual(binding['mode'], HOST.MODE_V2)
        self.assertEqual(F.ADMISSION.enrollment_ids(self.f.root, self.policy), [self.f.sid])

    def test_v2_accepts_device_renumbering_without_recapture(self):
        self.enroll()
        before = self.entry_path().read_bytes()
        binding_before = HOST.check(self.f.root, self.request())
        self.f.append_turn(F.TURN2, 'New fact after the captured frontier.')
        with self.renumbered():
            self.assertEqual(self.enroll(), (self.f.sid, False, False))
            self.assertEqual(HOST.check(self.f.root, self.request()), binding_before)
            parsed = TRANSCRIPT.read_excerpt(self.f.path, binding_before['frontier_offset'], stable_identity=True)
            self.assertEqual(parsed.metadata.identity, binding_before['identity'])
        self.assertEqual(self.entry_path().read_bytes(), before)
        self.assertIn('New fact after', parsed.text)

    def test_v1_still_refuses_device_renumbering(self):
        self.policy.update(schema_version=1, mode=HOST.MODE,
                           sessions_dir=F.Fixture.binding(self.f.sessions))
        self.save_policy()
        self.enroll()
        before = self.entry_path().read_bytes()
        with self.renumbered(), self.assertRaisesRegex(ValueError, '^admission_directory_identity_changed$'):
            self.enroll()
        self.assertEqual(self.entry_path().read_bytes(), before)

    def test_policy_schema_mode_and_directory_shapes_are_paired_strictly(self):
        original = copy.deepcopy(self.policy)
        candidates = [dict(original, schema_version=1), dict(original, schema_version=True),
                      dict(original, mode=HOST.MODE),
                      dict(original, sessions_dir=F.Fixture.binding(self.f.sessions)),
                      dict(original, schema_version=1, mode=HOST.MODE)]
        for candidate in candidates:
            with self.subTest(candidate=candidate):
                self.policy = candidate
                self.save_policy()
                with self.assertRaises(ValueError):
                    HOST.policy(self.f.root)

    def test_legacy_entry_under_v2_requires_migration_without_reset(self):
        stable_policy = copy.deepcopy(self.policy)
        self.policy.update(schema_version=1, mode=HOST.MODE,
                           sessions_dir=F.Fixture.binding(self.f.sessions))
        self.save_policy()
        self.enroll()
        before = self.entry_path().read_bytes()
        self.policy = stable_policy
        self.save_policy()
        self.f.append_turn(F.TURN2, 'Pending legacy content must remain pending.')
        with self.assertRaisesRegex(ValueError, '^admission_legacy_migration_required$'):
            self.enroll()
        self.assertEqual(self.entry_path().read_bytes(), before)

    def test_different_uuid_same_inode_and_device_refused(self):
        self.enroll()
        def other(fd):
            return dict(self.identity(fd), volume_uuid=OTHER_VOLUME)
        with mock.patch.object(IDENTITY, 'capture_fd', side_effect=other), \
                self.assertRaisesRegex(ValueError, '^admission_directory_identity_changed$'):
            self.enroll()

    def test_changed_transcript_uuid_with_unchanged_directories_refused(self):
        self.enroll()
        inode = self.f.path.stat().st_ino
        def other(fd):
            value = self.identity(fd)
            return dict(value, volume_uuid=OTHER_VOLUME) if value['inode'] == inode else value
        with mock.patch.object(IDENTITY, 'capture_fd', side_effect=other), \
                self.assertRaisesRegex(ValueError, '^admission_enrollment_origin_changed$'):
            self.enroll()

    def test_replaced_transcript_inode_refused(self):
        self.enroll()
        replacement = self.f.path.with_suffix('.replacement')
        replacement.write_bytes(self.f.path.read_bytes())
        os.replace(replacement, self.f.path)
        with self.assertRaisesRegex(ValueError, '^admission_enrollment_origin_changed$'):
            self.enroll()

    def test_initial_metadata_change_refused(self):
        self.enroll()
        self.f.meta['payload']['cli_version'] = 'mutated-version'
        self.f.rewrite_initial()
        with self.assertRaisesRegex(ValueError, '^admission_enrollment_origin_changed$'):
            self.enroll()

    def test_frontier_content_change_refused(self):
        self.enroll()
        self.f.path.write_bytes(self.f.path.read_bytes().replace(b'example marker is amber', b'example marker is azure'))
        with self.assertRaisesRegex(ValueError, '^admission_frontier_anchor_changed$'):
            self.enroll()

    def test_frontier_truncation_refused(self):
        self.enroll()
        self.f.path.write_bytes(self.f.path.read_bytes().split(b'\n', 1)[0] + b'\n')
        with self.assertRaisesRegex(ValueError, '^admission_frontier_truncated_or_invalid$'):
            self.enroll()

    def test_frontier_rechecks_initial_metadata_on_its_actual_fd(self):
        self.enroll()
        origin = HOST._origin(self.policy, self.f.payload)
        self.f.meta['payload']['cli_version'] = 'mutated-version'
        self.f.rewrite_initial()
        with self.assertRaisesRegex(ValueError, '^admission_initial_metadata_changed$'):
            F.ADMISSION._frontier(origin)

    def test_hold_file_symlink_or_directory_prevents_learning_preserves_entry(self):
        self.enroll()
        before = self.entry_path().read_bytes()
        for kind in ('file', 'symlink', 'directory'):
            with self.subTest(kind=kind):
                path = self.hold(kind)
                with self.assertRaisesRegex(ValueError, '^admission_migration_held$'):
                    HOST.check(self.f.root, self.request())
                self.assertEqual(self.enroll(), (self.f.sid, False, False))
                self.assertEqual(self.entry_path().read_bytes(), before)
                path.rmdir() if kind == 'directory' else path.unlink()

    def test_hold_does_not_create_missing_enrollment(self):
        self.hold()
        with self.assertRaisesRegex(ValueError, '^admission_migration_held$'):
            self.enroll()
        self.assertFalse(self.entry_path().exists())

    def test_unsafe_hold_directory_refuses_even_if_target_absent(self):
        self.enroll()
        parent = self.f.root / 'migration-holds'
        parent.symlink_to(self.f.root / 'absent')
        with self.assertRaisesRegex(ValueError, '^admission_migration_held$'):
            HOST.check(self.f.root, self.request())
        parent.unlink()
        parent.mkdir(mode=0o755)
        with self.assertRaisesRegex(ValueError, '^admission_migration_held$'):
            F.ADMISSION.ensure_no_migration_hold(self.f.root, self.f.sid)

    def test_missing_enrollment_with_state_is_never_recaptured(self):
        self.enroll()
        self.entry_path().unlink()
        F.write_json(self.f.state, {'offset': 333, 'reconciliation_required': {'reason': 'retained'}})
        before = self.f.state.read_bytes()
        with self.assertRaisesRegex(ValueError, '^admission_unowned_existing_state$'):
            self.enroll()
        self.assertEqual(self.f.state.read_bytes(), before)
        self.assertFalse(self.entry_path().exists())

    def test_request_rejects_legacy_numbers_and_malformed_identity(self):
        self.enroll()
        for changed in ({'device': 0}, {'inode': 1}, {'identity': None},
                        {'identity': {'scheme': IDENTITY.SCHEME, 'volume_uuid': VOLUME, 'inode': True}}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                HOST.check(self.f.root, {**self.request(), **changed})

    def test_manual_precompact_still_refused(self):
        with self.assertRaisesRegex(ValueError, '^admission_manual_compaction_not_enabled$'):
            self.enroll(event='PreCompact', trigger='manual')
        self.assertFalse(self.entry_path().exists())

    def make_child(self, *, known=True):
        parent = F.uuid7(F.ORIGIN, suffix=900)
        meta = self.f.meta['payload']
        meta.update(session_id=parent, source={'subagent': {'thread_spawn': {'parent_thread_id': parent}}})
        if known:
            meta['subagent_history_start_ordinal'] = 10
        self.f.rewrite_initial()
        self.f.payload.update(session_id=parent, agent_id=self.f.sid)
        # The inherited content is ordinal 1; the new message belongs to child 11.
        rows = self.f.path.read_bytes().splitlines(keepends=True)
        first = rows[0]
        self.f.path.write_bytes(first)
        for ordinal, text in ((1, 'Inherited parent fact'), (11, 'New child fact')):
            with self.f.path.open('a') as stream:
                stream.write(json.dumps({'type': 'response_item', 'ordinal': ordinal,
                    'payload': {'type': 'message', 'role': 'user', 'content': text}}) + '\n')
        return len(first)

    def test_fresh_v2_child_preserves_known_inherited_boundary(self):
        boundary = self.make_child()
        self.assertEqual(self.enroll(event='SubagentStop'), (self.f.sid, True, True))
        self.assertEqual(self.entry()['frontier_offset'], boundary)
        excerpt = TRANSCRIPT.read_excerpt(self.f.path, boundary, stable_identity=True)
        self.assertIn('New child fact', excerpt.text)
        self.assertNotIn('Inherited parent', excerpt.text)

    def test_old_v2_child_baselines_without_backfill(self):
        self.make_child()
        self.policy['cutoff'] = '2026-01-03T00:00:00Z'
        self.save_policy()
        self.assertEqual(self.enroll(event='SubagentStop'), (self.f.sid, True, False))
        self.assertEqual(self.entry()['frontier_offset'], self.f.path.stat().st_size)

    def test_unknown_v2_child_boundary_refuses_without_enrollment(self):
        self.make_child(known=False)
        with self.assertRaisesRegex(ValueError, '^admission_unknown_inherited_boundary$'):
            self.enroll(event='SubagentStop')
        self.assertFalse(self.entry_path().exists())

    def test_v2_origin_hash_and_semantics_share_one_metadata_read(self):
        # V2 origin parses the exact sealed line, rather than opening the path
        # again to interpret its session/parent metadata.
        with mock.patch.object(HOST, 'inspect_rollout', side_effect=AssertionError('unexpected second metadata read')):
            origin = HOST._origin(self.policy, self.f.payload)
        self.assertEqual(origin['identity']['inode'], self.f.path.stat().st_ino)

    def test_frontier_rechecks_identity_after_reading(self):
        self.enroll()
        origin = HOST._origin(self.policy, self.f.payload)
        count = []
        def capture(fd):
            count.append(fd)
            value = self.identity(fd)
            return value if len(count) == 1 else dict(value, volume_uuid=OTHER_VOLUME)
        with mock.patch.object(IDENTITY, 'capture_fd', side_effect=capture), \
                self.assertRaisesRegex(ValueError, '^admission_transcript_identity_changed$'):
            F.ADMISSION._frontier(origin)

    def test_migration_hold_preserves_gate_cursor_and_pending_pause(self):
        self.enroll()
        F.write_json(self.f.state, {'offset': 333, 'frontier_offset': 100,
            'reconciliation_required': {'reason': 'uncertain_write'}, 'recent_messages': ['sealed']})
        F.write_json(self.f.pending, {'request_id': 'retained', 'paused_request_id': 'retained',
            'pause_reason': 'batch_limit'})
        before = self.f.state.read_bytes(), self.f.pending.read_bytes(), self.entry_path().read_bytes()
        self.hold()
        self.assertEqual(self.enroll(), (self.f.sid, False, False))
        with self.assertRaisesRegex(ValueError, '^admission_migration_held$'):
            HOST.check(self.f.root, self.request())
        self.assertEqual((self.f.state.read_bytes(), self.f.pending.read_bytes(),
                          self.entry_path().read_bytes()), before)

    def test_stable_transcript_identity_comes_from_read_fd(self):
        called = []
        def capture(fd):
            called.append(fd)
            self.assertEqual(os.fstat(fd).st_ino, self.f.path.stat().st_ino)
            return self.identity(fd)
        with mock.patch.object(IDENTITY, 'capture_fd', side_effect=capture):
            excerpt = TRANSCRIPT.read_excerpt(self.f.path, stable_identity=True)
        self.assertTrue(called)
        self.assertEqual(len(set(called)), 1)
        self.assertEqual(excerpt.metadata.identity['inode'], self.f.path.stat().st_ino)
        self.assertIn('example marker', excerpt.text)

    def test_stable_transcript_refuses_path_replacement_during_read(self):
        real_visible = TRANSCRIPT._visible_message
        replaced = []
        def visible(*args):
            if not replaced:
                replaced.append(True)
                replacement = self.f.path.with_suffix('.replacement')
                replacement.write_bytes(self.f.path.read_bytes())
                os.replace(replacement, self.f.path)
            return real_visible(*args)
        with mock.patch.object(TRANSCRIPT, '_visible_message', side_effect=visible), \
                self.assertRaisesRegex(ValueError, '^admission_transcript_identity_changed$'):
            TRANSCRIPT.read_excerpt(self.f.path, stable_identity=True)

    def test_v1_transcript_never_captures_persistent_identity(self):
        with mock.patch.object(IDENTITY, 'capture_fd', side_effect=AssertionError('v1 must not capture UUID')):
            self.assertIsNone(TRANSCRIPT.inspect_rollout(self.f.path).identity)
            self.assertIsNone(TRANSCRIPT.read_excerpt(self.f.path).metadata.identity)

    def test_stable_transcript_refuses_symlink(self):
        alias = self.f.path.with_suffix('.alias')
        alias.symlink_to(self.f.path)
        with self.assertRaisesRegex(ValueError, '^admission_noncanonical_path$'):
            TRANSCRIPT.inspect_rollout(alias, stable_identity=True)


if __name__ == '__main__':
    unittest.main()
