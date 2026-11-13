#!/usr/bin/env python3
"""Test source-install resource copies without executing the installer."""
import argparse
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


EXPECTED_BUNDLES = (
    "Engram_EngramKit.bundle",
    "Engram_EngramCoreML.bundle",
    "swift-transformers_Hub.bundle",
)


def resource_recipe(source):
    start = 'if [ "$1" = "--from-source" ]; then\n'
    if start not in source:
        raise ValueError("Source-install branch is missing")
    block = source.split(start, 1)[1].split("\nelse\n", 1)[0]
    if "\nelse\n" not in source.split(start, 1)[1]:
        raise ValueError("Source-install branch has no boundary")
    recipe = []
    for line in block.splitlines():
        if not line.strip().startswith("cp ") or ".bundle" not in line:
            continue
        # Parse literals only: no shell, environment expansion or installer execution.
        args = shlex.split(line)
        if (len(args) != 4 or args[:2] != ["cp", "-R"]
                or args[3] != "$INSTALL_DIR/"
                or not re.fullmatch(r"\.build/release/[A-Za-z0-9_-]+\.bundle", args[2])):
            raise ValueError("Resource copy is not a bounded literal recipe: " + line.strip())
        recipe.append(Path(args[2]).name)
    if not recipe:
        raise ValueError("Source-install resource recipe is empty")
    return recipe


class InstallResourceTests(unittest.TestCase):
    installer = None
    scratch_root = None

    def test_source_install_copies_current_resource_bundles(self):
        recipe = resource_recipe(self.installer.read_text())
        with tempfile.TemporaryDirectory(prefix="install-resources-", dir=self.scratch_root) as tmp:
            fixture = Path(tmp)
            built = fixture / "build"
            installed = fixture / "installed"
            built.mkdir()
            installed.mkdir()
            markers = {}
            for name in EXPECTED_BUNDLES:
                bundle = built / name
                (bundle / "nested").mkdir(parents=True)
                markers[name] = (name + "\n").encode()
                (bundle / "marker.txt").write_bytes(markers[name])
                (bundle / "nested" / "marker.txt").write_bytes(markers[name][::-1])
            for name in recipe:
                # Every argument is reconstructed within the disposable fixture.
                result = subprocess.run(
                    ["/bin/cp", "-R", str(built / name), str(installed)],
                    capture_output=True, text=True, timeout=10, check=False,
                )
                self.assertEqual(result.returncode, 0,
                                 f"Resource copy failed for {name}: {result.stderr.strip()}")
            self.assertCountEqual(recipe, EXPECTED_BUNDLES)
            self.assertEqual(sorted(p.name for p in installed.iterdir()), sorted(EXPECTED_BUNDLES))
            for name, marker in markers.items():
                bundle = installed / name
                self.assertEqual((bundle / "marker.txt").read_bytes(), marker)
                self.assertEqual((bundle / "nested" / "marker.txt").read_bytes(), marker[::-1])
                self.assertEqual(sorted(str(p.relative_to(bundle)) for p in bundle.rglob("*")),
                                 ["marker.txt", "nested", "nested/marker.txt"])

    def test_legacy_resource_cleanup_remains(self):
        cleanup = 'rm -rf "$INSTALL_DIR/SwiftLM_SwiftLM.bundle"'
        self.assertEqual(self.installer.read_text().splitlines().count(cleanup), 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--installer", type=Path, default=Path(__file__).with_name("install.sh"))
    parser.add_argument("--scratch-root", type=Path, required=True,
                        help="Existing directory for disposable resource fixtures")
    args = parser.parse_args()
    if not args.installer.is_file() or not args.scratch_root.is_dir():
        parser.error("Installer and scratch directory must already exist")
    InstallResourceTests.installer = args.installer
    InstallResourceTests.scratch_root = args.scratch_root
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(InstallResourceTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
