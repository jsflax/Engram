#!/usr/bin/env python3
"""Exercise artifact rejection boundaries and a real small bundle zip round trip."""
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import uuid
import zipfile

spec = importlib.util.spec_from_file_location('diagnostic', Path(__file__).with_name('package_visualizer_diagnostic.py'))
diagnostic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostic)


class DiagnosticArtifactTests(unittest.TestCase):
    source = 'a' * 40
    identifier = '013DF6F6-4370-3D50-8B55-77E5CD879C63'

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.archive = self.root / 'diagnostic/Engram.xcarchive'
        self.app = self.archive / 'Products/Applications/Engram.app'
        self.dsym = self.archive / 'dSYMs/Engram.app.dSYM'
        self.executable = self.app / 'Contents/MacOS/Engram'
        self.dwarf = self.dsym / 'Contents/Resources/DWARF/Engram'
        for path in (self.executable, self.dwarf):
            path.parent.mkdir(parents=True)
            path.write_bytes(self.macho(self.identifier))
        self.executable.chmod(0o755)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'io.engram.app', 'CFBundleShortVersionString': '0.15.28',
            'CFBundleVersion': '46', 'CFBundleExecutable': 'Engram',
        }))
        (self.root / 'evidence/diagnostic-build').mkdir(parents=True)
        (self.root / 'evidence/source-identity.json').write_text(json.dumps({
            'source_sha': self.source, 'run_id': '123', 'run_attempt': '1',
        }))
        (self.root / 'evidence/inputs-diagnostic.json').write_text(json.dumps({'source_sha': self.source}))
        (self.root / 'evidence/xcode-version.txt').write_text('Xcode fixture\nBuild version fixture\n')
        (self.root / 'repo').mkdir()
        (self.root / 'repo/Package.resolved').write_text('{}\n')
        self.receipt = {
            'command': ['xcodebuild', 'archive', '-configuration', 'Release',
                        '-archivePath', str(self.archive), 'ARCHS=arm64',
                        'DEBUG_INFORMATION_FORMAT=dwarf-with-dsym', 'CODE_SIGNING_ALLOWED=NO'],
            'exit_code': 0, 'child_exit_code': 0, 'reason': 'exit', 'errors': [],
            'signals_received': [], 'reader_complete': True, 'reader_error': None,
            'log_truncated': False, 'cleanup': {'remaining': [], 'errors': [], 'signals': []},
        }
        self.write_receipt()

    @staticmethod
    def macho(identifier, cpu=0x0100000C):
        return struct.pack('<8I', 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0) + \
            struct.pack('<II', 0x1B, 24) + uuid.UUID(identifier).bytes

    def write_receipt(self):
        (self.root / 'evidence/diagnostic-build/receipt.json').write_text(json.dumps(self.receipt))

    def test_arm64_uuid_and_bounds(self):
        self.assertEqual(diagnostic.arm64_uuid(self.executable), self.identifier)
        for invalid in (b'', self.macho(self.identifier)[:-1], self.macho(self.identifier, cpu=7),
                        self.macho(self.identifier)[:36] + struct.pack('<I', 0) + bytes(16)):
            self.executable.write_bytes(invalid)
            with self.assertRaises(ValueError):
                diagnostic.arm64_uuid(self.executable)

    def test_rejects_mismatched_symbols(self):
        self.dwarf.write_bytes(self.macho('113DF6F6-4370-3D50-8B55-77E5CD879C63'))
        with self.assertRaisesRegex(ValueError, 'UUID mismatch'):
            diagnostic.inspect(self.root, self.source)

    def test_rejects_unbound_source(self):
        with self.assertRaisesRegex(ValueError, 'source identity mismatch'):
            diagnostic.inspect(self.root, 'b' * 40)

    def test_rejects_different_bundle_executable(self):
        path = self.app / 'Contents/Info.plist'
        info = plistlib.loads(path.read_bytes())
        info['CFBundleExecutable'] = 'Other'
        path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, 'unexpected app executable'):
            diagnostic.inspect(self.root, self.source)

    def test_rejects_debug_configuration(self):
        self.receipt['command'][3] = 'Debug'
        self.write_receipt()
        with self.assertRaisesRegex(ValueError, 'Release'):
            diagnostic.inspect(self.root, self.source)

    def test_rejects_failed_or_incomplete_build(self):
        for key, value in (('child_exit_code', 1), ('reader_complete', False), ('log_truncated', True)):
            original = self.receipt[key]
            self.receipt[key] = value
            self.write_receipt()
            with self.assertRaises(ValueError):
                diagnostic.inspect(self.root, self.source)
            self.receipt[key] = original
        self.receipt['cleanup']['remaining'] = [123]
        self.write_receipt()
        with self.assertRaisesRegex(ValueError, 'cleanup'):
            diagnostic.inspect(self.root, self.source)

    def test_rejects_stale_archive_receipt(self):
        self.receipt['command'][5] = str(self.root / 'old.xcarchive')
        self.write_receipt()
        with self.assertRaisesRegex(ValueError, 'different archive'):
            diagnostic.inspect(self.root, self.source)

    def test_rejects_conflicting_build_settings(self):
        self.receipt['command'].append('CODE_SIGNING_ALLOWED=YES')
        self.write_receipt()
        with self.assertRaisesRegex(ValueError, 'ambiguous'):
            diagnostic.inspect(self.root, self.source)

    def test_rejects_escaping_bundle_symlink(self):
        (self.app / 'outside').symlink_to(self.root / 'repo', target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink escapes'):
            diagnostic.inspect(self.root, self.source)

    @unittest.skipUnless(Path('/usr/bin/ditto').exists(), 'macOS bundle packager')
    def test_real_zip_round_trip_and_manifest(self):
        (self.app / 'Contents/Engram-link').symlink_to('MacOS/Engram')
        diagnostic.package(self.root, self.source)
        output = self.root / 'diagnostic-artifact'
        manifest = json.loads((output / 'manifest.json').read_text())
        self.assertEqual(manifest['app_and_dsym_uuid'], self.identifier)
        self.assertEqual(manifest['source_sha'], self.source)
        self.assertEqual(manifest['configuration'], 'Release')
        self.assertFalse(manifest['bundled_cli_present'])
        self.assertTrue(manifest['requires_local_signing_and_validation_before_launch'])
        self.assertEqual(manifest['app_executable_sha256'], diagnostic.digest(self.executable))
        for name, identity in manifest['archives'].items():
            self.assertEqual(identity['sha256'], diagnostic.digest(output / name))
            self.assertEqual(identity['bytes'], (output / name).stat().st_size)
        with zipfile.ZipFile(output / 'Engram.app.zip') as archive:
            executable = archive.getinfo('Engram.app/Contents/MacOS/Engram')
            self.assertEqual((executable.external_attr >> 16) & 0o777, 0o755)
            link = archive.getinfo('Engram.app/Contents/Engram-link')
            self.assertEqual((link.external_attr >> 16) & 0o170000, 0o120000)
            self.assertEqual(archive.read(link), b'MacOS/Engram')
        with self.assertRaises(FileExistsError):
            diagnostic.package(self.root, self.source)


if __name__ == '__main__':
    unittest.main()
