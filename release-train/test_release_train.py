import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release_train', Path(__file__).with_name('release_train.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class ReleaseTrainTests(unittest.TestCase):
    def test_semver_precedence(self):
        values = ['1.0.0-alpha', '1.0.0-alpha.1', '1.0.0-alpha.beta', '1.0.0-beta', '1.0.0-beta.2', '1.0.0-beta.11', '1.0.0-rc.1', '1.0.0', '2.0.0']
        self.assertEqual([v.text for v in sorted(map(r.Version, reversed(values)))], values)

    def test_invalid_versions(self):
        for value in ['01.2.3', '1.2', '1.2.3-rc.01', '1.2.3;echo bad', 'v1.2.3', '1.2.3\n']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                r.Version(value)

    def test_build_metadata_does_not_change_precedence(self):
        self.assertEqual(r.Version('1.2.3+x'), r.Version('1.2.3+y'))

    def test_suggestion_keeps_independent_tag_conventions(self):
        self.assertEqual(r.next_version(['v0.1.1', 'perf-evidence-2026-08'], 'v', 'minor', 'stable'), '0.2.0')
        self.assertEqual(r.next_version(['1.7.2', '1.7.3-rc.1', '1.7.3-rc.9'], '', 'patch', 'rc'), '1.7.3-rc.10')

    def test_release_must_advance_even_over_other_prereleases(self):
        policy = {'tagPrefix': '', 'prereleaseChannels': ['rc']}
        with self.assertRaises(ValueError):
            r.check_version('1.7.2', policy, ['1.7.3-rc.1'])
        r.check_version('1.7.3', policy, ['1.7.3-rc.1'])

    def test_same_inflight_tag_only_allowed_explicitly(self):
        policy = {'tagPrefix': 'v', 'prereleaseChannels': ['rc']}
        with self.assertRaises(ValueError):
            r.check_version('1.2.3', policy, ['v1.2.3'])
        r.check_version('1.2.3', policy, ['v1.2.3'], existing_same=True)

    def test_newest_ci_failure_cannot_borrow_old_success(self):
        common = {'head_sha': 'a' * 40, 'head_branch': 'main', 'event': 'push', 'status': 'completed', 'html_url': 'https://github.com/o/r/actions/runs/1', 'id': 1}
        runs = [dict(common, run_number=1, conclusion='success'), dict(common, run_number=2, conclusion='failure')]
        with patch.object(r, 'gh_api', return_value={'workflow_runs': runs}), self.assertRaises(ValueError):
            r.verify_ci('o/r', 'a' * 40, ['ci.yml'])

    def test_absent_or_wrong_sha_ci_is_not_success(self):
        with patch.object(r, 'gh_api', return_value={'workflow_runs': []}), self.assertRaises(ValueError):
            r.verify_ci('o/r', 'a' * 40, ['ci.yml'])

    def test_ci_rerun_attempt_is_recorded(self):
        run = {'head_sha': 'a' * 40, 'head_branch': 'main', 'event': 'push', 'status': 'completed', 'conclusion': 'success', 'html_url': 'https://github.com/o/r/actions/runs/1', 'id': 1, 'run_number': 2, 'run_attempt': 3}
        with patch.object(r, 'gh_api', return_value={'workflow_runs': [run]}):
            self.assertEqual(r.verify_ci('o/r', 'a' * 40, ['ci.yml'])[0]['runAttempt'], 3)

    def test_candidate_rejects_dependency_drift(self):
        candidate = dict(schemaVersion=1, repository='o/r', source={'sha': 'a' * 40}, version='1.2.3', channel='stable', tag='v1.2.3', dependencies={'pins': {'core': 'a'}})
        changed = copy.deepcopy(candidate)
        changed['dependencies']['pins']['core'] = 'b'
        with self.assertRaises(ValueError):
            r.candidate_matches(candidate, changed)

    def test_native_receipt_requires_exact_package_and_evidence(self):
        candidate = {'source': {'sha': 'a' * 40}}
        package = {'artifact': 'digest'}
        native = {'schemaVersion': 1, 'sourceSha': 'a' * 40, 'packageReceiptDigest': r.encoded_digest(package), 'checks': [{'name': 'real-workflow', 'result': 'passed', 'evidence': {'path': __file__, 'sha256': r.digest(__file__)}}]}
        r.verify_native(native, candidate, package, ['real-workflow'])
        for mutation in [{'sourceSha': 'b' * 40}, {'packageReceiptDigest': 'old'}, {'checks': []}, {'checks': native['checks'] * 2}]:
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                r.verify_native(dict(native, **mutation), candidate, package, ['real-workflow'])

    def test_lockfile_drift_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def lock(revision):
                return {'pins': [{'identity': 'core', 'location': 'https://github.com/o/core', 'state': {'revision': revision, 'version': '1.0.0'}}]}
            r.write(root / 'one.json', lock('a' * 40))
            r.write(root / 'two.json', lock('b' * 40))
            with self.assertRaises(ValueError):
                r.snapshot(root, {'lockfiles': ['one.json', 'two.json']})

    def test_published_pin_must_match_exact_tag(self):
        snap = {'pins': {'core': {'version': '1.0.0', 'revision': 'a' * 40}}, 'localDependencies': {}}
        ref = {'ref': 'refs/tags/1.0.0', 'object': {'type': 'commit', 'sha': 'b' * 40}}
        with patch.object(r, 'gh_api', return_value=ref), self.assertRaises(ValueError):
            r.verify_dependencies(snap, {'publishedDependencies': {'core': 'o/core'}})

    def test_published_pin_rejects_branch_without_tag(self):
        snap = {'pins': {'core': {'version': '1.0.0', 'revision': 'a' * 40}}, 'localDependencies': {}}
        def branch_only(endpoint):
            if endpoint == 'repos/o/core/commits/1.0.0':
                return {'sha': 'a' * 40}
            raise subprocess.CalledProcessError(1, ['gh', 'api', endpoint])
        with patch.object(r, 'gh_api', side_effect=branch_only) as api, self.assertRaises(subprocess.CalledProcessError):
            r.verify_dependencies(snap, {'publishedDependencies': {'core': 'o/core'}})
        api.assert_called_once_with('repos/o/core/git/ref/tags/1.0.0')

    def test_published_lightweight_and_nested_annotated_tags(self):
        for annotated in (False, True):
            with self.subTest(annotated=annotated):
                target = {'type': 'commit', 'sha': 'a' * 40}
                responses = {'repos/o/core/git/ref/tags/1.0.0': {'ref': 'refs/tags/1.0.0', 'object': target}}
                if annotated:
                    responses['repos/o/core/git/ref/tags/1.0.0']['object'] = {'type': 'tag', 'sha': 'b' * 40}
                    responses['repos/o/core/git/tags/' + 'b' * 40] = {'sha': 'b' * 40, 'object': {'type': 'tag', 'sha': 'c' * 40}}
                    responses['repos/o/core/git/tags/' + 'c' * 40] = {'sha': 'c' * 40, 'object': target}
                with patch.object(r, 'gh_api', side_effect=responses.__getitem__):
                    self.assertEqual(r.published_tag_commit('o/core', '1.0.0'), 'a' * 40)

    def test_published_tag_requires_exact_ref_and_commit_target(self):
        for ref, target in [('refs/heads/1.0.0', {'type': 'commit', 'sha': 'a' * 40}), ('refs/tags/1.0.0', {'type': 'tree', 'sha': 'a' * 40})]:
            with self.subTest(ref=ref, target=target), patch.object(r, 'gh_api', return_value={'ref': ref, 'object': target}), self.assertRaises(ValueError):
                r.published_tag_commit('o/core', '1.0.0')

    def test_release_attempt_identity_includes_version_sha_and_event(self):
        sha = 'a' * 40
        selected = {'head_sha': sha, 'event': 'workflow_dispatch', 'display_title': f'Release 1.0.0 at {sha}'}
        other = [dict(selected, display_title=f'Release 1.0.0-rc.1 at {sha}'), dict(selected, head_sha='b' * 40), dict(selected, event='pull_request')]
        for prefix in ('', 'v'):
            with self.subTest(prefix=prefix):
                tag_push = dict(selected, event='push', display_title=f'Release {prefix}1.0.0 at {sha}')
                legacy = dict(selected, event='push', display_title='Old release workflow', head_branch=prefix + '1.0.0')
                self.assertEqual(r.matching_release_attempts(other + [selected, tag_push, legacy], {'tagPrefix': prefix}, '1.0.0', sha), [selected, tag_push, legacy])

    def test_dispatch_stable_after_prerelease_at_same_sha(self):
        sha = 'a' * 40
        prior = {'head_sha': sha, 'event': 'workflow_dispatch', 'display_title': f'Release 1.0.0-rc.1 at {sha}', 'run_number': 1, 'id': 1, 'status': 'completed', 'conclusion': 'success', 'html_url': 'https://github.com/o/repo/actions/runs/1'}
        policy = {'releaseMode': 'hosted', 'repository': 'o/repo', 'branch': 'main', 'tagPrefix': 'v'}
        output = io.StringIO()
        with (
            patch.object(sys, 'argv', ['release_train.py', 'dispatch', '--version', '1.0.0', '--expected-sha', sha]),
            patch.object(r, 'repository', return_value=Path('.')),
            patch.object(r, 'policy_at', return_value=policy),
            patch.object(r, 'guard', return_value={'tag': 'v1.0.0'}),
            patch.object(r, 'gh_api', return_value={'workflow_runs': [prior]}),
            patch.object(r, 'run') as invoke,
            contextlib.redirect_stdout(output),
        ):
            r.main()
        invoke.assert_called_once_with(['gh', 'workflow', 'run', 'release.yml', '--repo', 'o/repo', '--ref', 'main', '-f', 'version=1.0.0', '-f', 'expected_sha=' + sha])
        self.assertEqual(json.loads(output.getvalue())['state'], 'dispatched-awaiting-validation')

    def test_dispatch_reconciles_newest_attempt_for_selected_version(self):
        sha = 'a' * 40
        selected = {'head_sha': sha, 'event': 'workflow_dispatch', 'display_title': f'Release 1.0.0 at {sha}', 'run_number': 2, 'run_attempt': 1, 'id': 2, 'status': 'completed', 'conclusion': 'failure', 'html_url': 'https://github.com/o/repo/actions/runs/2'}
        rerun = dict(selected, run_attempt=2, status='in_progress', conclusion=None)
        other = dict(selected, display_title=f'Release 1.0.0-rc.1 at {sha}', run_number=3, id=3)
        policy = {'releaseMode': 'hosted', 'repository': 'o/repo', 'branch': 'main', 'tagPrefix': 'v'}
        output = io.StringIO()
        with (
            patch.object(sys, 'argv', ['release_train.py', 'dispatch', '--version', '1.0.0', '--expected-sha', sha]),
            patch.object(r, 'repository', return_value=Path('.')),
            patch.object(r, 'policy_at', return_value=policy),
            patch.object(r, 'guard', return_value={'tag': 'v1.0.0'}),
            patch.object(r, 'gh_api', return_value={'workflow_runs': [selected, other, rerun]}),
            patch.object(r, 'run') as invoke,
            contextlib.redirect_stdout(output),
        ):
            r.main()
        invoke.assert_not_called()
        result = json.loads(output.getvalue())
        self.assertEqual((result['runId'], result['runAttempt'], result['tag'], result['sourceSha']), (2, 2, 'v1.0.0', sha))

    def test_generated_appcast_is_only_packaging_change(self):
        with patch.object(r, 'git', return_value=' M appcast.xml'):
            r.clean(Path('.'), packaged=True)
            with self.assertRaises(ValueError):
                r.clean(Path('.'))
        with patch.object(r, 'git', return_value=' M appcast.xml\n M Package.swift'), self.assertRaises(ValueError):
            r.clean(Path('.'), packaged=True)

    def test_command_output_preserves_porcelain_leading_space(self):
        self.assertEqual(r.run(['python3', '-c', 'print(" M appcast.xml")']), ' M appcast.xml')

    def test_digest_changes_with_artifact_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'artifact'
            path.write_bytes(b'original')
            before = r.digest(path)
            path.write_bytes(b'changed')
            self.assertNotEqual(before, r.digest(path))


if __name__ == '__main__':
    unittest.main()
