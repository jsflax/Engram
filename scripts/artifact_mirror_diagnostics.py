#!/usr/bin/env python3
"""Bounded evidence and TERM-only cleanup for the workflow's owned HTTP mirror."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import signal
import stat
import subprocess
import time

LIMIT = 16 * 1024
SAMPLE_LIMIT = 256 * 1024
SAMPLE_TIMEOUT = 10


def read_owned(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise ValueError('unsafe diagnostic input')
        value = os.read(fd, limit)
        return value, info.st_size > limit
    finally:
        os.close(fd)


def command(argv):
    try:
        result = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, timeout=2)
        # Never retain tool stderr (or an unexpected process's arguments).
        if len(result.stdout) > LIMIT:
            return {'status': 'output_limit'}
        return {'status': 'complete', 'exit_code': result.returncode,
                'stdout': result.stdout.decode('utf-8', errors='replace')}
    except subprocess.TimeoutExpired:
        return {'status': 'timeout'}
    except OSError:
        return {'status': 'unavailable'}


def process(pid, root):
    result = command(['/bin/ps', '-p', str(pid), '-o', 'pid=,uid=,lstart=,command='])
    if result.get('exit_code') == 1 and not result.get('stdout'):
        return {'status': 'absent', 'pid': pid}
    if result.get('exit_code') != 0:
        return {'status': 'inspection_failed', 'pid': pid, 'inspection': result['status']}
    fields = result['stdout'].strip().split(None, 7)
    if len(fields) != 8 or fields[0] != str(pid) or fields[1] != str(os.getuid()):
        return {'status': 'identity_mismatch', 'pid': pid}
    argv = fields[7]
    suffix = (' -B ' + str(root / 'repo/scripts/artifact_mirror_server.py')
              + ' --directory ' + str(root / 'mirror'))
    interpreter = argv[:-len(suffix)] if argv.endswith(suffix) else ''
    matched = bool(interpreter and ' ' not in interpreter
                   and re.fullmatch(r'(?:Python|python3(?:\.\d+)?)', Path(interpreter).name))
    return {'status': 'owned' if matched else 'identity_mismatch', 'pid': pid,
            'started': ' '.join(fields[2:7]), 'command_sha256': hashlib.sha256(argv.encode()).hexdigest(),
            **({'command': argv} if matched else {})}


def inspect(root):
    try:
        raw, truncated = read_owned(root / 'private/mirror.pid', 32)
        if truncated or not re.fullmatch(rb'[1-9][0-9]{0,9}\n?', raw):
            raise ValueError('invalid mirror pid')
        return process(int(raw), root)
    except FileNotFoundError:
        return {'status': 'not_started'}
    except (OSError, ValueError):
        return {'status': 'invalid_pid_file'}


def sockets(root, expected):
    before = process(expected['pid'], root)
    if before != expected:
        return {'status': 'identity_changed', 'before': before, 'qualified': False}
    result = command(['/usr/sbin/lsof', '-nP', '-a', '-p', str(expected['pid']),
                      '-iTCP:8765', '-FpcnT'])
    after = process(expected['pid'], root)
    return {'result': result, 'before': before, 'after': after,
            'qualified': after == expected and result.get('exit_code') in (0, 1),
            'scope': 'Exact owned PID and port; all TCP states, not only LISTEN.'}


def sample_limit():
    # Applies only in the sample child; never changes the workflow process.
    _, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
    limit = SAMPLE_LIMIT if hard == resource.RLIM_INFINITY else min(SAMPLE_LIMIT, hard)
    resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))


def sample_mirror(root, expected):
    before = process(expected['pid'], root)
    if before != expected:
        return {'status': 'identity_changed', 'before': before, 'qualified': False}
    path = root / 'evidence/mirror-sample.txt'
    receipt = {'before': before, 'qualified': False, 'seconds_requested': 1,
               'helper_timeout_seconds': SAMPLE_TIMEOUT, 'output_limit': SAMPLE_LIMIT}
    try:
        # Refuse an existing destination rather than overwrite prior evidence.
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except OSError:
        receipt['status'] = 'output_unavailable_or_exists'
        return receipt
    os.close(fd)
    began = time.monotonic()
    try:
        result = subprocess.run(['/usr/bin/sample', str(expected['pid']), '1', '10',
                                 '-file', str(path)], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=SAMPLE_TIMEOUT, preexec_fn=sample_limit)
        receipt.update(status='complete', exit_code=result.returncode)
    except subprocess.TimeoutExpired:
        # subprocess.run kills and joins only its own helper on timeout.
        receipt['status'] = 'timeout'
    except (OSError, subprocess.SubprocessError):
        receipt['status'] = 'unavailable'
    finally:
        receipt['elapsed_seconds'] = time.monotonic() - began
        receipt['after'] = process(expected['pid'], root)
    try:
        raw, truncated = read_owned(path, SAMPLE_LIMIT)
        # Reaching the child file limit can leave a partial sample at exactly
        # the cap; preserve it, but never call it a complete stack report.
        truncated = truncated or len(raw) == SAMPLE_LIMIT
        receipt.update(path=path.name, retained_bytes=len(raw), truncated=truncated,
                       sha256=hashlib.sha256(raw).hexdigest())
        receipt['qualified'] = (receipt['status'] == 'complete' and receipt.get('exit_code') == 0
                                and receipt['after'] == expected and bool(raw) and not truncated)
    except (OSError, ValueError):
        receipt['output_status'] = 'unavailable_or_unsafe'
    return receipt


def diagnose(root, curl_status):
    current = inspect(root)
    receipt = {'curl_exit_code': curl_status, 'process': current}
    try:
        raw, truncated = read_owned(root / 'private/mirror.log', LIMIT)
        (root / 'evidence/mirror-stderr.log').write_bytes(raw)
        receipt['stderr'] = {'retained_bytes': len(raw), 'truncated': truncated,
                             'sha256': hashlib.sha256(raw).hexdigest()}
    except (OSError, ValueError):
        receipt['stderr'] = {'status': 'unavailable_or_unsafe'}
    if current['status'] == 'owned':
        receipt['sockets'] = sockets(root, current)
        receipt['sample'] = sample_mirror(root, current)
    (root / 'evidence/mirror-failure.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


def stop(root):
    current = inspect(root)
    receipt = {'before': current, 'signal': None}
    if current['status'] == 'owned':
        # Compare birth and exact command again immediately before signaling.
        confirmed = process(current['pid'], root)
        if confirmed == current:
            try:
                os.kill(current['pid'], signal.SIGTERM)
                receipt['signal'] = 'SIGTERM'
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + 3
            while True:
                after = process(current['pid'], root)
                if after['status'] != 'absent' and after != current:
                    # Exiting processes can lose argv before disappearing. Keep
                    # observing, but never signal a changed identity or accept
                    # the transition itself as successful cleanup.
                    receipt.setdefault('first_transition', {
                        key: after[key] for key in
                        ('status', 'pid', 'started', 'command_sha256', 'inspection')
                        if key in after
                    })
                if after['status'] == 'absent' or time.monotonic() >= deadline:
                    break
                time.sleep(0.1)
            receipt['after'] = after
        else:
            receipt['after'] = confirmed
    else:
        receipt['after'] = current
    receipt['stopped_or_not_started'] = receipt['after']['status'] in {'absent', 'not_started'}
    (root / 'evidence/mirror-cleanup.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('failure', 'stop'))
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--curl-status', type=int)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    for name in ('private', 'evidence', 'mirror'):
        if (root / name).resolve(strict=True) != root / name or not (root / name).is_dir():
            parser.error('expected owned workflow directories')
    if args.action == 'failure':
        if args.curl_status is None or not 1 <= args.curl_status <= 255:
            parser.error('failure requires original nonzero curl status')
        diagnose(root, args.curl_status)
        return 0
    return 0 if stop(root)['stopped_or_not_started'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
