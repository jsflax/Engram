#!/usr/bin/env python3
"""Bounded evidence and TERM-only cleanup for the workflow's owned HTTP mirror."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import time

LIMIT = 16 * 1024


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
    suffix = ' -B -m http.server 8765 --bind 127.0.0.1 --directory ' + str(root / 'mirror')
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
        receipt['listener'] = command(['/usr/sbin/lsof', '-nP', '-a', '-p', str(current['pid']),
                                       '-iTCP:8765', '-sTCP:LISTEN', '-FpcnT'])
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
                if after['status'] == 'absent' or time.monotonic() >= deadline:
                    break
                if after != current:
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
