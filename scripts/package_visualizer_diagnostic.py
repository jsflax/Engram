#!/usr/bin/env python3
"""Package an optimized, unsigned visualizer and its exact symbols; never launch it."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import uuid


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def arm64_uuid(path):
    """Read the bounded Mach-O load commands; do not load the executable."""
    with path.open('rb') as stream:
        header = stream.read(32)
        require(len(header) == 32, 'truncated Mach-O header')
        magic, cpu, _, _, count, size, _, _ = struct.unpack('<8I', header)
        require(magic == 0xFEEDFACF and cpu == 0x0100000C, 'expected thin arm64 Mach-O')
        require(0 < count <= 65536 and 0 < size <= 16 * 1024 * 1024, 'invalid load-command bounds')
        commands = stream.read(size)
        require(len(commands) == size, 'truncated Mach-O commands')
    offset, found = 0, []
    for _ in range(count):
        require(offset + 8 <= size, 'missing load command')
        command, length = struct.unpack_from('<II', commands, offset)
        require(length >= 8 and length % 8 == 0 and offset + length <= size, 'invalid load command')
        if command == 0x1B:
            require(length == 24, 'invalid UUID command')
            found.append(str(uuid.UUID(bytes=commands[offset + 8:offset + 24])).upper())
        offset += length
    require(offset == size and len(found) == 1, 'expected exactly one UUID')
    return found[0]


def owned(root, path):
    require(path.exists() and path.resolve().is_relative_to(root), 'missing or escaped artifact input')
    return path


def validate_receipt(receipt):
    require(receipt['exit_code'] == receipt['child_exit_code'] == 0 and receipt['reason'] == 'exit',
            'diagnostic build did not succeed')
    require(not receipt['errors'] and not receipt['signals_received'] and receipt['reader_complete']
            and receipt['reader_error'] is None and not receipt['log_truncated'], 'incomplete build receipt')
    require(not any(receipt['cleanup'][key] for key in ('remaining', 'errors', 'signals')),
            'diagnostic build cleanup incomplete')
    command = receipt['command']
    require(command[0] == 'xcodebuild' and command[1] == 'archive', 'unexpected diagnostic builder')
    require(command.count('-configuration') == 1 and command[command.index('-configuration') + 1] == 'Release',
            'diagnostic is not Release configuration')
    for setting in ('ARCHS=arm64', 'DEBUG_INFORMATION_FORMAT=dwarf-with-dsym', 'CODE_SIGNING_ALLOWED=NO'):
        require(setting in command, 'missing diagnostic build setting: ' + setting)
        key = setting.split('=', 1)[0] + '='
        require(sum(value.startswith(key) for value in command) == 1, 'ambiguous build setting: ' + key)


def inspect(root, source_sha):
    require(re.fullmatch('[0-9a-f]{40}', source_sha) is not None, 'invalid source SHA')
    identity = json.loads(owned(root, root / 'evidence/source-identity.json').read_text())
    require(identity['source_sha'] == source_sha, 'source identity mismatch')
    inputs_path = owned(root, root / 'evidence/inputs-diagnostic.json')
    require(json.loads(inputs_path.read_text())['source_sha'] == source_sha, 'diagnostic input source mismatch')
    receipt_path = owned(root, root / 'evidence/diagnostic-build/receipt.json')
    receipt = json.loads(receipt_path.read_text())
    validate_receipt(receipt)
    archive = owned(root, root / 'diagnostic/Engram.xcarchive')
    command = receipt['command']
    require(command.count('-archivePath') == 1
            and Path(command[command.index('-archivePath') + 1]).resolve() == archive.resolve(),
            'build receipt belongs to a different archive')
    app = owned(root, archive / 'Products/Applications/Engram.app')
    dsym = owned(root, archive / 'dSYMs/Engram.app.dSYM')
    executable = owned(root, app / 'Contents/MacOS/Engram')
    dwarf = owned(root, dsym / 'Contents/Resources/DWARF/Engram')
    app_uuid = arm64_uuid(executable)
    require(app_uuid == arm64_uuid(dwarf), 'app and dSYM UUID mismatch')
    info = plistlib.loads(owned(root, app / 'Contents/Info.plist').read_bytes())
    require(info['CFBundleIdentifier'] == 'io.engram.app', 'unexpected app identity')
    require(info.get('CFBundleExecutable') == 'Engram', 'unexpected app executable')
    for bundle in (app, dsym):
        for item in bundle.rglob('*'):
            require(item.resolve().is_relative_to(bundle.resolve()), 'bundle symlink escapes artifact')
    return app, dsym, {
        'schema_version': 1, 'purpose': 'visualizer-only diagnostic; not a published or installed release',
        'source_sha': source_sha, 'run_id': identity['run_id'], 'run_attempt': identity['run_attempt'],
        'configuration': 'Release', 'architecture': 'arm64', 'app_and_dsym_uuid': app_uuid,
        'app_executable_sha256': digest(executable), 'dwarf_sha256': digest(dwarf),
        'build_receipt_sha256': digest(receipt_path), 'build_command': receipt['command'],
        'input_verification_sha256': digest(inputs_path),
        'xcode_version': owned(root, root / 'evidence/xcode-version.txt').read_text().strip(),
        'bundle_id': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
        'build': str(info['CFBundleVersion']), 'code_signing_allowed': False,
        'bundled_cli_present': (app / 'Contents/Resources/cli').exists(),
        'requires_local_signing_and_validation_before_launch': True,
        'package_resolved_sha256': digest(owned(root, root / 'repo/Package.resolved')),
    }


def package(root, source_sha):
    root = root.resolve(strict=True)
    app, dsym, manifest = inspect(root, source_sha)
    output = root / 'diagnostic-artifact'
    output.mkdir()  # Do not mix a new build with stale artifacts.
    manifest['archives'] = {}
    for name, bundle in (('Engram.app.zip', app), ('Engram.app.dSYM.zip', dsym)):
        destination = output / name
        # zip inside the Actions artifact preserves bundle permissions/symlinks.
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(bundle), str(destination)],
                       check=True, timeout=180)
        manifest['archives'][name] = {'sha256': digest(destination), 'bytes': destination.stat().st_size}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'artifact': str(output), 'source_sha': source_sha,
                      'uuid': manifest['app_and_dsym_uuid']}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--source-sha', required=True)
    args = parser.parse_args()
    package(args.root, args.source_sha)
