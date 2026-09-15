"""End-to-end local git/CLI test; no GitHub mutation or native toolchain."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class ProtocolCLITests(unittest.TestCase):
    def test_candidate_package_native_receipt_and_tamper(self):
        with tempfile.TemporaryDirectory() as directory:
            top = Path(directory)
            root = top/'repo'; root.mkdir()
            tool = Path(__file__).with_name('release_train.py')
            def command(args, **kwargs):
                return subprocess.run(args, cwd=root, text=True, capture_output=True, **kwargs)
            def git(*args):
                result = command(['git', *args]); self.assertEqual(result.returncode, 0, result.stderr); return result.stdout.strip()
            git('init', '-b', 'main')
            git('config', 'user.name', 'Release protocol fixture')
            git('config', 'user.email', 'release-fixture@example.invalid')
            (root/'release-train').mkdir()
            policy = dict(repository='fixture/repo', branch='main', tagPrefix='v', prereleaseChannels=['rc'], lockfiles=[], changelog='CHANGELOG.md', requiredPriorCI=[], publishedDependencies={}, localDependencies=[], artifacts=['dmg'], requiredNativeChecks=['workflow'])
            (root/'release-train/policy.json').write_text(json.dumps(policy))
            (root/'CHANGELOG.md').write_text('## [1.0.1]\n\nFixture change.\n')
            (root/'.gitignore').write_text('dist/\n')
            git('add', '.'); git('commit', '-m', 'fixture')
            sha = git('rev-parse', 'HEAD')
            remote = top/'remote.git'
            result = subprocess.run(['git', 'clone', '--bare', str(root), str(remote)],capture_output=True)
            self.assertEqual(result.returncode,0)
            git('remote', 'add', 'origin', str(remote))
            bin_dir=top/'bin'; bin_dir.mkdir()
            gh=bin_dir/'gh'
            gh.write_text('#!'+sys.executable+'\nimport json,sys\nendpoint=sys.argv[2]\nprint(json.dumps({"sha":"'+sha+'"} if "/commits/" in endpoint else []))\n')
            gh.chmod(0o755)
            env=dict(os.environ,PATH=str(bin_dir)+os.pathsep+os.environ['PATH'])
            def cli(*args):
                return command([sys.executable,str(tool.resolve()),*args],env=env)
            candidate=top/'candidate.json'
            result=cli('candidate','--version','1.0.1','--expected-sha',sha,'--output',str(candidate))
            self.assertEqual(result.returncode,0,result.stderr)
            bad=cli('check','--version','1.0.1','--expected-sha','b'*40)
            self.assertNotEqual(bad.returncode,0)
            (root/'dist').mkdir(); artifact=root/'dist/review.dmg'; artifact.write_bytes(b'fixture package, not an actual DMG')
            receipt=root/'dist/receipt.json'
            result=cli('receipt','--candidate',str(candidate),'--output',str(receipt),'--artifact','dmg='+str(artifact))
            self.assertEqual(result.returncode,0,result.stderr)
            evidence=top/'workflow.json'; evidence.write_text('{"test":"fixture-only", "result":"passed"}')
            data=json.loads(receipt.read_text())
            package_digest=hashlib.sha256(json.dumps(data,sort_keys=True,separators=(',',':')).encode()).hexdigest()
            native=top/'native.json'; native.write_text(json.dumps(dict(schemaVersion=1,sourceSha=sha,packageReceiptDigest=package_digest,checks=[dict(name='workflow',result='passed',evidence=dict(path=str(evidence),sha256=hashlib.sha256(evidence.read_bytes()).hexdigest()))])))
            args=['verify-package','--candidate',str(candidate),'--receipt',str(receipt),'--native-receipt',str(native),'--artifact','dmg='+str(artifact)]
            result=cli(*args); self.assertEqual(result.returncode,0,result.stderr)
            artifact.write_bytes(b'tampered package')
            result=cli(*args); self.assertNotEqual(result.returncode,0)
            self.assertIn('artifact changed',result.stderr)


if __name__ == '__main__':
    unittest.main()
