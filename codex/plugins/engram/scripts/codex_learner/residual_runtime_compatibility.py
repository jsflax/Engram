"""Explicit residual-only admission of closed released sealed runtimes.

The predecessor files remain present and freshly authenticated. The running
successor files have a closed reviewed pin set; callers cannot supply mappings.
This module and CLI are bound by the surrounding source/release qualification,
not by a circular self-hash. No sealed bytes or native routes are rewritten.
"""
from dataclasses import dataclass
from pathlib import Path
import os
import stat
from . import execution_manifest as J

PROFILE = 'engram-0.15.1-validation-budget-v1'
RELEASED_PROFILE = 'engram-0.15.2-reviewed-accounting-v1'
OLD_HASHES = {'execution_context.py': 'f5c871eac53036eb217cdabca2b0ea5a99a9401dbc55ee76a6e6b7e61e1f7f49', 'execution_manifest.py': 'ca886dbbb7a6f15e83ebac253fa6137665282996b548523d0a27267666df3a50', 'legacy_reconciliation.py': 'c51db740945976d4fae05b2283d067b32d2dcfce4ed5bd87908c2ebd88227560', 'native_executor.py': 'fb3ef0232a1f5d72774e9a5383d19da52d79301655a4b59ea305dd3bcefedaee', 'operation_gateway.py': '333eabc06b20ff6a7c0b4dda05b70fad2b80c91b07faf40778edcedb602205e6', 'operation_probe.py': 'f2b006c9c7e2af462aa5d640b7ac7b2145e3fbf05b8caa7c143b3bf3d631ebd1', 'publication_coordinator.py': 'ce386e02bca7cd190812761d8e6ecc23f606aab96dde7c22805e8461a657f99f', 'residual_context.py': '2cede6d967b174d6fee75e3d0668c7a582b9309a14920823b15540daa62326dd', 'residual_driver.py': 'e8c95a032306ee7fe360ed78ff2e5976334d915ff6eef4e97331251c1277be41', 'residual_publication.py': '02a56af699f1341e237d9b965227975d14004e96ffd9613573e2f1142a8ca371', 'writer_fence.py': 'e55e1c6a993cdf84ea0ff5acab01b84ef72495f58f7f78ff6648fc57a9ca44e3'}
PARSER_SHA256 = '8338508fce42afabdd90b853b9f38ce10deb408762d205ad18b600cddf96d173'
# Exact 05b8f886 predecessor; retained independently of future successor pins.
RELEASED_HASHES = {'execution_context.py': '381c2775b599fffedaf2021e2b425716297f9585118e428b6670a7c5514708af', 'execution_manifest.py': '8b0833fe5d052975140ad0c70f9b7cb0951d5b9a495c5fae555e5b197703aafe', 'legacy_reconciliation.py': 'd0235d493330411d6ef057ae43f0fce4f81cce69e67dc85aed94091096fc2557', 'native_executor.py': 'fb3ef0232a1f5d72774e9a5383d19da52d79301655a4b59ea305dd3bcefedaee', 'operation_gateway.py': '333eabc06b20ff6a7c0b4dda05b70fad2b80c91b07faf40778edcedb602205e6', 'operation_probe.py': '2ad37c0101defbf0547c7eb8658c074b5a23be159d67637525a92220ea887413', 'publication_coordinator.py': '2381c8034c9973ec849b37ccf5393a9f737c7e7839f968d40dad7c1b58a9bbc7', 'residual_context.py': 'e4f8d647796be1895d88302b26a26322c75797930d98cde369eaf263dc2a99ee', 'residual_driver.py': '42efd64f00d47f7786cf906330ac073e1bf3fe3ac9ed79aaef7f32b2273109fa', 'residual_publication.py': 'af156165dd86f07da8080cfd80a981da8bbe365026ddb3e9ef712b7f727b9663', 'writer_fence.py': 'e68bda762cec23c3cfaebd9caabd6dfb00ac376b8f49a424552ad628f4b0a31d'}
# Refreshed only when this exact successor source is independently qualified.
CURRENT_HASHES = {'execution_context.py': '381c2775b599fffedaf2021e2b425716297f9585118e428b6670a7c5514708af', 'execution_manifest.py': 'd60c11230ec77f403305ba583d993954ef93256c8058a84701395834a063c927', 'legacy_reconciliation.py': '489e74f46927e8c576751c3e6a5bbb7e9953ae928590d537fd8330b350b408d1', 'native_executor.py': 'fb3ef0232a1f5d72774e9a5383d19da52d79301655a4b59ea305dd3bcefedaee', 'operation_gateway.py': '333eabc06b20ff6a7c0b4dda05b70fad2b80c91b07faf40778edcedb602205e6', 'operation_probe.py': '2ad37c0101defbf0547c7eb8658c074b5a23be159d67637525a92220ea887413', 'publication_coordinator.py': '2381c8034c9973ec849b37ccf5393a9f737c7e7839f968d40dad7c1b58a9bbc7', 'residual_context.py': '234adb12906bc07d6e5e051e27be541bcf411e46ea17b3100d4d9e556d772051', 'residual_driver.py': '42efd64f00d47f7786cf906330ac073e1bf3fe3ac9ed79aaef7f32b2273109fa', 'residual_publication.py': '0de2505ca1a7371447dab1004f93a8a217e4390770a13d7cc3a32ae1165fdf63', 'writer_fence.py': 'e68bda762cec23c3cfaebd9caabd6dfb00ac376b8f49a424552ad628f4b0a31d'}


def require(ok):
    if not ok:
        raise ValueError('residual_runtime_compatibility_changed')


def _root(path):
    require(type(path) is type(Path()) and path.is_absolute()
            and path.resolve(strict=True) == path)
    J.durable._directory(path)
    return path


def _hash(path):
    require(path.resolve(strict=True) == path)
    raw, identity = J.durable._read(path, private=False)
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
            and info.st_nlink == 1 and not info.st_mode & 0o022
            and J.durable._identity(info) == identity)
    return J.sha256(raw)


@dataclass(frozen=True)
class RuntimeAdmission:
    old_root: Path
    current_root: Path
    profile: str = PROFILE

    def predecessor(self):
        require(self.profile in (PROFILE, RELEASED_PROFILE))
        return OLD_HASHES if self.profile == PROFILE else RELEASED_HASHES

    def verify_runtime(self, sealed, running):
        _root(self.old_root); _root(self.current_root)
        predecessor = self.predecessor()
        require(self.old_root != self.current_root
                and self.current_root == Path(__file__).resolve().parents[2]
                and set(sealed) == set(running) == set(predecessor) == set(CURRENT_HASHES))
        for name, old_hash in predecessor.items():
            before = self.old_root / 'scripts/codex_learner' / name
            after = self.current_root / 'scripts/codex_learner' / name
            require(sealed[name] == {'path':str(before), 'sha256':old_hash}
                    and running[name] == {'path':str(after), 'sha256':CURRENT_HASHES[name]}
                    and _hash(before) == old_hash and _hash(after) == CURRENT_HASHES[name])
        return True

    def verify_parser(self, sealed, running):
        self.predecessor()
        _root(self.old_root); _root(self.current_root)
        require(self.current_root == Path(__file__).resolve().parents[2])
        before = self.old_root / 'scripts/codex_learner/transcript.py'
        after = self.current_root / 'scripts/codex_learner/transcript.py'
        require(sealed == {'path':str(before), 'sha256':PARSER_SHA256}
                and running == {'path':str(after), 'sha256':PARSER_SHA256}
                and _hash(before) == PARSER_SHA256 and _hash(after) == PARSER_SHA256)
        return True


def admit(profile, old_root):
    require(type(profile) is str and profile in (PROFILE, RELEASED_PROFILE))
    return RuntimeAdmission(_root(old_root), _root(Path(__file__).resolve().parents[2]), profile)
