#!/usr/bin/env python3
"""Release train protocol v1. Metadata is data; it never supplies executable commands."""
import argparse
import datetime
import functools
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import quote

SEMVER = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?')
SHA = re.compile(r'[0-9a-f]{40}')


def require(ok, message):
    if not ok:
        raise ValueError(message)


@functools.total_ordering
class Version:
    def __init__(self, text):
        match = SEMVER.fullmatch(text)
        require(match is not None, 'version must be SemVer 2.0.0')
        self.text = text
        self.core = tuple(int(match[i]) for i in (1, 2, 3))
        self.pre = tuple((match[4] or '').split('.')) if match[4] else ()
        require(not any(p.isdigit() and len(p) > 1 and p[0] == '0' for p in self.pre), 'numeric prerelease identifiers cannot have leading zeroes')

    def __eq__(self, other):
        return self.core == other.core and self.pre == other.pre

    def __lt__(self, other):
        if self.core != other.core:
            return self.core < other.core
        if not self.pre or not other.pre:
            return bool(self.pre) and not other.pre
        for a, b in zip(self.pre, other.pre):
            if a == b:
                continue
            if a.isdigit() and b.isdigit():
                return int(a) < int(b)
            if a.isdigit() != b.isdigit():
                return a.isdigit()
            return a < b
        return len(self.pre) < len(other.pre)


def run(args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True, stderr=subprocess.PIPE).rstrip('\n')


def git(*args, cwd=None):
    return run(['git', *args], cwd=cwd)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def encoded_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def write(path, value):
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def gh_api(endpoint):
    return json.loads(run(['gh', 'api', endpoint]))


def repository():
    return Path(git('rev-parse', '--show-toplevel'))


def policy_at(root):
    return json.loads((root / 'release-train/policy.json').read_text())


def versions(tags, prefix):
    result = []
    for tag in tags:
        if not tag.startswith(prefix):
            continue
        try:
            result.append(Version(tag[len(prefix):]))
        except ValueError:
            pass  # Bench/evidence tags are deliberately outside release versioning.
    return result


def next_version(tags, prefix, bump, channel):
    all_versions = versions(tags, prefix)
    stable = [v for v in all_versions if not v.pre]
    base = max(stable).core if stable else (0, 0, 0)
    major, minor, patch = base
    base = {'major': (major + 1, 0, 0), 'minor': (major, minor + 1, 0), 'patch': (major, minor, patch + 1)}[bump]
    if channel != 'stable':
        counters = [int(v.pre[1]) for v in all_versions if v.core == base and len(v.pre) == 2 and v.pre[0] == channel and v.pre[1].isdigit()]
        return '.'.join(map(str, base)) + f'-{channel}.{max(counters, default=0) + 1}'
    return '.'.join(map(str, base))


def snapshot(root, policy):
    locks, pins = {}, {}
    for relative in policy['lockfiles']:
        path = root / relative
        data = json.loads(path.read_text())
        locks[relative] = digest(path)
        for pin in data.get('pins', []):
            identity, state = pin['identity'], pin['state']
            revision = state.get('revision', '')
            require(SHA.fullmatch(revision), f'{relative}: {identity} has no exact revision')
            value = {'revision': revision, 'version': state.get('version'), 'location': pin.get('location')}
            require(identity not in pins or pins[identity] == value, f'dependency drift across lockfiles: {identity}')
            pins[identity] = value
    local = {}
    # The policy enumerates the existing local release dependencies. Never discover
    # or execute shell snippets from Package.swift or a candidate manifest.
    for relative in policy.get('localDependencies', []):
        path = (root / relative).resolve()
        require(path.is_dir(), f'local release dependency unavailable: {relative}')
        require(not git('status', '--porcelain', cwd=path), f'local release dependency is dirty: {relative}')
        local[relative] = {'sha': git('rev-parse', 'HEAD', cwd=path), 'tree': git('rev-parse', 'HEAD^{tree}', cwd=path), 'remote': git('remote', 'get-url', 'origin', cwd=path)}
    return {'lockfiles': locks, 'pins': pins, 'localDependencies': local}


def clean(root, packaged=False):
    status = git('status', '--porcelain', '--untracked-files=all', cwd=root).splitlines()
    allowed = {' M appcast.xml', '?? appcast.xml'} if packaged else set()
    require(all(line in allowed for line in status), 'working tree has changes outside the allowed generated appcast')


def check_version(version, policy, tags, existing_same=False):
    proposed = Version(version)
    # Build metadata does not change precedence and must not be used to bypass the
    # one-version-one-release rule.
    require('+' not in version, 'release tags do not use SemVer build metadata')
    if proposed.pre:
        require(len(proposed.pre) == 2 and proposed.pre[0] in policy['prereleaseChannels'] and proposed.pre[1].isdigit(), 'unsupported release channel; use alpha.N, beta.N, or rc.N as allowed by this repository')
    for old in versions(tags, policy['tagPrefix']):
        if old.text == version and existing_same:
            continue
        require(proposed > old, f'version must exceed existing release tag {old.text}')
    return proposed


def check_notes(root, policy, version):
    if policy['changelog']:
        text = (root / policy['changelog']).read_text()
        pattern = r'^## \[' + re.escape(version) + r'\][^\n]*\n(.*?)(?=^## \[|\Z)'
        section = re.search(pattern, text, re.M | re.S)
        require(section and section[1].strip(), f'nonempty CHANGELOG section [{version}] required')


def verify_dependencies(snap, policy):
    for identity, repo in policy.get('publishedDependencies', {}).items():
        pin = snap['pins'].get(identity)
        require(pin and pin['version'], f'{identity}: published version pin required')
        commit = gh_api(f'repos/{repo}/commits/{quote(pin["version"], safe="")}')
        require(commit['sha'] == pin['revision'], f'{identity}: pin does not match its published tag')
    for relative, dep in snap['localDependencies'].items():
        remote = dep['remote']
        match = re.fullmatch(r'(?:https://github\.com/|git@github\.com:)([^/]+/[^/]+?)(?:\.git)?', remote)
        require(match, f'{relative}: GitHub origin required to verify published source')
        commit = gh_api(f'repos/{match[1]}/commits/{dep["sha"]}')
        require(commit['sha'] == dep['sha'], f'{relative}: local dependency commit is not published')


def verify_ci(repo, sha, workflows):
    evidence = []
    for workflow in workflows:
        query = f'repos/{repo}/actions/workflows/{workflow}/runs?head_sha={sha}&event=push&per_page=100'
        runs = gh_api(query)['workflow_runs']
        runs = [r for r in runs if r['head_sha'] == sha and r.get('head_branch') == 'main' and r['event'] == 'push']
        require(runs, f'{workflow}: no main push CI run for the exact candidate')
        newest = max(runs, key=lambda r: (r['run_number'], r.get('run_attempt', 1)))
        require(newest['status'] == 'completed' and newest['conclusion'] == 'success', f'{workflow}: newest exact-commit CI is {newest["status"]}/{newest["conclusion"]}')
        evidence.append({'workflow': workflow, 'runId': newest['id'], 'runAttempt': newest.get('run_attempt', 1), 'url': newest['html_url'], 'sha': sha, 'result': 'passed'})
    return evidence


def guard(root, policy, version, expected_sha, packaged=False):
    require(SHA.fullmatch(expected_sha), 'expected SHA must be a full 40-character commit')
    require(git('rev-parse', 'HEAD', cwd=root) == expected_sha, 'checkout does not match candidate SHA')
    clean(root, packaged)
    remote_main = gh_api(f'repos/{policy["repository"]}/commits/{policy["branch"]}')['sha']
    require(remote_main == expected_sha, 'candidate must equal the current canonical main commit')
    git('fetch', 'origin', '--tags', cwd=root)
    tag = policy['tagPrefix'] + version
    tags = git('tag', '--list', cwd=root).splitlines()
    existing_same = False
    if tag in tags:
        require(git('rev-parse', f'{tag}^{{commit}}', cwd=root) == expected_sha, 'existing tag points to another commit; tags are immutable')
        existing_same = True
    proposed = check_version(version, policy, tags, existing_same)
    # Published releases are immutable to this owner, including assets. Retry
    # failures before publication; never turn an existing release into a new one.
    releases = gh_api(f'repos/{policy["repository"]}/releases?per_page=100')
    require(not any(r['tag_name'] == tag for r in releases), 'release already exists; inspect it instead of overwriting')
    check_notes(root, policy, version)
    snap = snapshot(root, policy)
    verify_dependencies(snap, policy)
    ci = verify_ci(policy['repository'], expected_sha, policy['requiredPriorCI'])
    return {'schemaVersion': 1, 'repository': policy['repository'], 'source': {'sha': expected_sha, 'tree': git('rev-parse', 'HEAD^{tree}', cwd=root)}, 'version': version, 'channel': proposed.pre[0] if proposed.pre else 'stable', 'tag': tag, 'dependencies': snap, 'priorCI': ci, 'checkedAt': now()}


def candidate_matches(candidate, checked):
    for key in ['schemaVersion', 'repository', 'source', 'version', 'channel', 'tag', 'dependencies']:
        require(candidate.get(key) == checked.get(key), f'candidate {key} does not match the checkout')


def verify_native(receipt, candidate, package_receipt, required):
    require(receipt.get('schemaVersion') == 1 and receipt.get('sourceSha') == candidate['source']['sha'], 'native receipt source does not match candidate')
    require(receipt.get('packageReceiptDigest') == encoded_digest(package_receipt), 'native validation must refer to this exact prepared package receipt')
    checks = receipt.get('checks', [])
    for name in required:
        matching = [c for c in checks if c.get('name') == name]
        require(len(matching) == 1 and matching[0].get('result') == 'passed', f'native check needs one passing evidence receipt: {name}')
        evidence = matching[0].get('evidence', {})
        require(isinstance(evidence, dict) and evidence.get('path') and evidence.get('sha256'), f'native check requires a retained evidence file and digest: {name}')
        require(Path(evidence['path']).is_file() and digest(evidence['path']) == evidence['sha256'], f'native evidence changed or is unavailable: {name}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    suggest = sub.add_parser('suggest')
    suggest.add_argument('--bump', choices=['major', 'minor', 'patch'], required=True)
    suggest.add_argument('--channel', choices=['stable', 'alpha', 'beta', 'rc'], default='stable')
    notes = sub.add_parser('notes')
    notes.add_argument('--version', required=True)
    notes.add_argument('--output', required=True)
    dispatch = sub.add_parser('dispatch')
    dispatch.add_argument('--version', required=True)
    dispatch.add_argument('--expected-sha', required=True)
    for command in ['check', 'candidate']:
        p = sub.add_parser(command)
        p.add_argument('--version', required=True)
        p.add_argument('--expected-sha', required=True)
        p.add_argument('--output', required=command == 'candidate')
        p.add_argument('--packaged', action='store_true', help='allow only the generated appcast source change')
    for command in ['receipt', 'workflow-receipt']:
        receipt = sub.add_parser(command)
        receipt.add_argument('--candidate', required=True)
        receipt.add_argument('--output', required=True)
        receipt.add_argument('--artifact', action='append', default=[])
    verify = sub.add_parser('verify-package')
    verify.add_argument('--candidate', required=True)
    verify.add_argument('--receipt', required=True)
    verify.add_argument('--native-receipt', required=True)
    verify.add_argument('--artifact', action='append', required=True)
    args = parser.parse_args()
    root = repository()
    policy = policy_at(root)
    if args.command == 'suggest':
        print(next_version(git('tag', '--list', cwd=root).splitlines(), policy['tagPrefix'], args.bump, args.channel))
        return
    if args.command == 'notes':
        Version(args.version)
        tags = versions(git('tag', '--list', cwd=root).splitlines(), policy['tagPrefix'])
        older = [v for v in tags if v < Version(args.version)]
        revision_range = policy['tagPrefix'] + max(older).text + '..HEAD' if older else 'HEAD'
        subjects = git('log', '--format=- %s (%h)', revision_range, cwd=root)
        Path(args.output).write_text(f'## [{args.version}]\n\n{subjects}\n')
        return
    if args.command == 'dispatch':
        require(policy['releaseMode'] == 'hosted', 'this repository uses the allocated local prepare/publish pipeline')
        checked = guard(root, policy, args.version, args.expected_sha)
        runs = gh_api(f'repos/{policy["repository"]}/actions/workflows/release.yml/runs?head_sha={args.expected_sha}&per_page=100')['workflow_runs']
        # Any previous release attempt for this exact SHA must be reconciled;
        # repeated heartbeat ticks never launch duplicate native work.
        if runs:
            latest = max(runs, key=lambda run: (run['run_number'], run.get('run_attempt', 1)))
            print(json.dumps({'state': 'existing-release-attempt', 'runId': latest['id'], 'status': latest['status'], 'conclusion': latest['conclusion'], 'url': latest['html_url']}, indent=2))
            return
        run(['gh', 'workflow', 'run', 'release.yml', '--repo', policy['repository'], '--ref', policy['branch'], '-f', 'version=' + args.version, '-f', 'expected_sha=' + args.expected_sha])
        print(json.dumps({'state': 'dispatched-awaiting-validation', 'sourceSha': args.expected_sha, 'tag': checked['tag'], 'dispatchedAt': now()}, indent=2))
        return
    if args.command in ['check', 'candidate']:
        result = guard(root, policy, args.version, args.expected_sha, packaged=args.packaged)
        result['state'] = 'candidate-preflight-passed'
        # Passing preflight means eligibility to BUILD. It is never a product test
        # or release receipt; existing native jobs still supply those gates.
        if args.output:
            write(args.output, result)
        print(json.dumps(result, indent=2))
        return
    candidate = json.loads(Path(args.candidate).read_text())
    checked = guard(root, policy, candidate['version'], candidate['source']['sha'], packaged=True)
    candidate_matches(candidate, checked)
    if args.command in ['receipt', 'workflow-receipt']:
        artifacts = {}
        for value in args.artifact:
            name, separator, raw_path = value.partition('=')
            require(separator and name and name not in artifacts, 'artifacts require unique NAME=PATH values')
            path = Path(raw_path).resolve()
            require(path.is_file(), f'artifact is missing: {name}')
            artifacts[name] = {'path': str(path), 'sha256': digest(path), 'bytes': path.stat().st_size}
        require(set(artifacts) == set(policy['artifacts']), 'receipt must include exactly the configured artifact set')
        result = {'schemaVersion': 1, 'sourceSha': candidate['source']['sha'], 'candidateDigest': encoded_digest(candidate), 'state': 'packaged-awaiting-native-validation', 'artifacts': artifacts, 'createdAt': now()}
        if args.command == 'workflow-receipt':
            require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_SHA') == candidate['source']['sha'], 'workflow receipt requires the exact Actions candidate')
            run_id = os.environ.get('GITHUB_RUN_ID', '')
            require(run_id.isdigit(), 'workflow run ID required')
            result['state'] = 'validated-and-packaged'
            result['workflowRun'] = f'https://github.com/{policy["repository"]}/actions/runs/{run_id}'
            result['runAttempt'] = os.environ.get('GITHUB_RUN_ATTEMPT', '1')
        write(args.output, result)
        print(encoded_digest(result))
    elif args.command == 'verify-package':
        result = json.loads(Path(args.receipt).read_text())
        require(result['sourceSha'] == candidate['source']['sha'] and result['candidateDigest'] == encoded_digest(candidate), 'package receipt belongs to a different candidate')
        require(set(result['artifacts']) == set(policy['artifacts']), 'package artifact set mismatch')
        actual_paths = {}
        for value in args.artifact:
            name, separator, path = value.partition('=')
            require(separator and name not in actual_paths, 'unique NAME=PATH publication artifacts required')
            actual_paths[name] = str(Path(path).resolve())
        require(set(actual_paths) == set(policy['artifacts']), 'publication artifact set mismatch')
        for name, artifact in result['artifacts'].items():
            require(actual_paths[name] == artifact['path'], f'publication path differs from validated package: {name}')
            require(Path(artifact['path']).is_file() and digest(artifact['path']) == artifact['sha256'], f'packaged artifact changed: {name}')
        native = json.loads(Path(args.native_receipt).read_text())
        verify_native(native, candidate, result, policy['requiredNativeChecks'])
        print(json.dumps({'state': 'publication-eligible', 'sourceSha': result['sourceSha'], 'packageReceiptDigest': encoded_digest(result)}, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as exc:
        # Do not echo subprocess stderr: authentication tools may include secrets.
        print('Release train stopped: ' + (str(exc) if not isinstance(exc, subprocess.CalledProcessError) else 'required git/GitHub operation failed'), file=sys.stderr)
        sys.exit(1)
