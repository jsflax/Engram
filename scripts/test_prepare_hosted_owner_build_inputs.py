"""Real-file DATA tests only; these never qualify Git sources or built images."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import struct
import tempfile
from types import SimpleNamespace
import unittest
import zipfile


class BuildInputDataTests(unittest.TestCase):
    def setUp(self):
        tmp = Path(os.environ["TMPDIR"])
        self.assertIn("localdev", tmp.parts)
        self.temporary = tempfile.TemporaryDirectory(dir=tmp)
        self.base = Path(self.temporary.name)
        module_path = Path(__file__).with_name("prepare_hosted_owner_build_inputs.py")
        spec = importlib.util.spec_from_file_location("build_input_data_under_test", module_path)
        self.inputs = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.inputs)
        # The unchanged bounded ZIP supplier must exist in this selected graph.
        self.zip = self.inputs.zip_helper()

    def tearDown(self):
        self.temporary.cleanup()

    def raw(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(body)
        return hashlib.sha256(body).hexdigest()

    def transport_case(self):
        files = {"SOURCE-GRAPH-SEAL.json": b"DATA source seal; not an accepted graph\n",
            "OWNER-DEPENDENCIES.json": b"DATA required sources\n", "OwnerImages.Package.resolved": b"DATA owner lock\n",
            "CACHE-SEAL.json": b"DATA cache seal\n", "CONFIG-SEAL.json": b"DATA config seal\n",
            "legacy.bundle": b"DATA only; not a genuine Git bundle\n"}
        keys = {"SOURCE-GRAPH-SEAL.json": "graphSealSHA256", "OWNER-DEPENDENCIES.json": "requiredSHA256",
            "OwnerImages.Package.resolved": "ownerLockSHA256", "CACHE-SEAL.json": "cacheSealSHA256",
            "CONFIG-SEAL.json": "configSealSHA256", "legacy.bundle": "legacyBundleSHA256"}
        values = {"schema": "lattice-owner-build-inputs/1", **{keys[name]: hashlib.sha256(raw).hexdigest() for name, raw in files.items()}}
        files["BUILD-INPUTS.json"] = (json.dumps(values) + "\n").encode()
        archive = self.base / "input.zip"
        with zipfile.ZipFile(archive, "w") as output:
            for name, raw in files.items():
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o600) << 16
                output.writestr(info, raw)
        payload_raw = archive.read_bytes()
        archive = self.base / "actions-envelope.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr(self.inputs.PAYLOAD_NAME, payload_raw)
        metadata = self.base / "metadata.json"
        metadata.write_text(json.dumps(dict(id=11, workflow_run=dict(id=12), name="lattice-owner-build-inputs-v1",
            expired=False, size_in_bytes=archive.stat().st_size)))
        env = self.base / "github-env"
        env.touch()
        args = SimpleNamespace(archive_sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
            payload_sha256=hashlib.sha256(payload_raw).hexdigest(), payload_bytes=len(payload_raw),
            graph_seal_sha256=values["graphSealSHA256"], required_sha256=values["requiredSHA256"],
            artifact_id="11", producer_run_id="12", root=self.base / "inputs", metadata=metadata,
            archive=archive, github_env=env)
        return args, files

    def test_actual_file_transport_preserves_exact_bytes_without_qualification(self):
        args, files = self.transport_case()
        self.inputs.prepare(args, self.zip)
        for name, raw in files.items():
            self.assertEqual((args.root / name).read_bytes(), raw)
        exported = args.github_env.read_text()
        self.assertIn("OWNER_BUILD_INPUT_ROOT=", exported)
        self.assertNotIn("QUALIFIED", exported)
        self.assertFalse((args.root / "legacy.hpp").exists())

    def test_actual_wrong_artifact_lane_refuses_before_extraction(self):
        args, files = self.transport_case()
        metadata = json.loads(args.metadata.read_text())
        metadata["name"] = "lattice-owner-inputs-v1"
        args.metadata.write_text(json.dumps(metadata))
        with self.assertRaisesRegex(RuntimeError, "^actual_build_artifact_correspondence$"):
            self.inputs.prepare(args, self.zip)
        self.assertFalse(args.root.exists())

    def test_actual_wrong_archive_sha_refuses_without_namespace(self):
        args, files = self.transport_case()
        args.archive_sha256 = "0" * 64
        with self.assertRaisesRegex(RuntimeError, "^build_envelope_digest$"):
            self.inputs.prepare(args, self.zip)
        self.assertFalse(args.root.exists())

    def rewrap(self, args, payload, extra=False):
        args.archive.unlink()
        with zipfile.ZipFile(args.archive, "w") as output:
            output.writestr(self.inputs.PAYLOAD_NAME, payload)
            if extra:
                output.writestr("unexpected.txt", b"not permitted")
        args.archive_sha256 = hashlib.sha256(args.archive.read_bytes()).hexdigest()
        args.payload_sha256 = hashlib.sha256(payload).hexdigest()
        args.payload_bytes = len(payload)
        metadata = json.loads(args.metadata.read_text())
        metadata["size_in_bytes"] = args.archive.stat().st_size
        args.metadata.write_text(json.dumps(metadata))

    def payload_from(self, args):
        with zipfile.ZipFile(args.archive) as archive:
            return archive.read(self.inputs.PAYLOAD_NAME)

    def test_real_raw_inner_zip_is_not_an_actions_envelope(self):
        args, _ = self.transport_case()
        args.archive.write_bytes(self.payload_from(args))
        args.archive_sha256 = hashlib.sha256(args.archive.read_bytes()).hexdigest()
        with self.assertRaisesRegex(RuntimeError, "^build_envelope_single_ordinary_inventory$"):
            self.inputs.prepare(args, self.zip)
        self.assertFalse(args.root.exists())
        self.assertFalse(args.root.with_name(args.root.name + "-payload").exists())

    def test_real_extra_outer_member_refuses_before_namespace(self):
        args, _ = self.transport_case()
        self.rewrap(args, self.payload_from(args), extra=True)
        with self.assertRaisesRegex(RuntimeError, "^build_envelope_single_ordinary_inventory$"):
            self.inputs.prepare(args, self.zip)
        self.assertFalse(args.root.exists())
        self.assertFalse(args.root.with_name(args.root.name + "-payload").exists())

    def test_real_outer_count_lie_is_closed_before_inventory(self):
        args, _ = self.transport_case()
        self.rewrap(args, self.payload_from(args), extra=True)
        raw = bytearray(args.archive.read_bytes())
        end = raw.rfind(b"PK\x05\x06")
        struct.pack_into("<2H", raw, end + 8, 1, 1)
        args.archive.write_bytes(raw)
        args.archive_sha256 = hashlib.sha256(raw).hexdigest()
        with self.assertRaisesRegex(RuntimeError, "^build_envelope_exact_payload_entry$"):
            self.inputs.prepare(args, self.zip)
        self.assertFalse(args.root.with_name(args.root.name + "-payload").exists())

    def test_real_separately_pinned_payload_byte_count_refuses_before_write(self):
        args, _ = self.transport_case()
        args.payload_bytes += 1
        with self.assertRaisesRegex(RuntimeError, "^build_envelope_exact_payload_entry$"):
            self.inputs.prepare(args, self.zip)
        self.assertFalse(args.root.with_name(args.root.name + "-payload").exists())

    def test_real_payload_digest_failure_retains_output_and_cannot_retry(self):
        args, _ = self.transport_case()
        args.payload_sha256 = "0" * 64
        with self.assertRaisesRegex(RuntimeError, "^build_envelope_payload_digest$"):
            self.inputs.prepare(args, self.zip)
        payload_root = args.root.with_name(args.root.name + "-payload")
        retained = payload_root / self.inputs.PAYLOAD_NAME
        self.assertTrue(retained.is_file())
        first = retained.read_bytes()
        self.assertFalse(args.root.exists())
        with self.assertRaisesRegex(RuntimeError, "^fresh_actual_build_payload_namespace$"):
            self.inputs.prepare(args, self.zip)
        self.assertEqual(retained.read_bytes(), first)

    def test_real_partial_crc_failure_retains_partial_original_and_refuses_retry(self):
        args, _ = self.transport_case()
        self.rewrap(args, b"actual bounded transport DATA\n" * 8000)
        raw = bytearray(args.archive.read_bytes())
        name_size, extra_size = struct.unpack_from("<2H", raw, 26)
        last_payload_byte = 30 + name_size + extra_size + args.payload_bytes - 1
        raw[last_payload_byte] ^= 1
        args.archive.write_bytes(raw)
        args.archive_sha256 = hashlib.sha256(raw).hexdigest()
        with self.assertRaises(zipfile.BadZipFile):
            self.inputs.extract_build_payload(args, self.zip)
        retained = args.root.with_name(args.root.name + "-payload") / self.inputs.PAYLOAD_NAME
        self.assertTrue(0 < retained.stat().st_size < args.payload_bytes)
        first = retained.read_bytes()
        self.assertFalse(args.root.exists())
        with self.assertRaisesRegex(RuntimeError, "^fresh_actual_build_payload_namespace$"):
            self.inputs.extract_build_payload(args, self.zip)
        self.assertEqual(retained.read_bytes(), first)

    def test_real_zip64_extra_refuses_before_namespace(self):
        args, _ = self.transport_case()
        payload = self.payload_from(args)
        args.archive.unlink()
        with zipfile.ZipFile(args.archive, "w") as output:
            info = zipfile.ZipInfo(self.inputs.PAYLOAD_NAME)
            info.extra = struct.pack("<2H", 1, 0)
            output.writestr(info, payload)
        args.archive_sha256 = hashlib.sha256(args.archive.read_bytes()).hexdigest()
        with self.assertRaisesRegex(RuntimeError, "^build_envelope_zip64_extra$"):
            self.inputs.prepare(args, self.zip)
        self.assertFalse(args.root.with_name(args.root.name + "-payload").exists())

    def test_inner_generic_member_cap_is_not_widened_by_envelope(self):
        args, _ = self.transport_case()
        inner = bytearray(self.payload_from(args))
        central = inner.find(b"PK\x01\x02")
        struct.pack_into("<L", inner, central + 24, self.zip.MAX_MEMBER + 1)
        self.rewrap(args, inner)
        with self.assertRaisesRegex(RuntimeError, "^input_zip_member_type_size$"):
            self.inputs.prepare(args, self.zip)
        self.assertFalse(args.root.exists())
        self.assertEqual(self.zip.MAX_MEMBER, 512 * 1024**2)

    def bad_provider_case(self):
        root = self.base / "compiler"
        root.mkdir(mode=0o700)
        executable = root / "scratch/executable"
        self.raw(executable, b"real DATA file; not an executable product\n")
        executable.chmod(0o700)
        evidence = self.base / "evidence"
        evidence.mkdir(mode=0o700)
        observed = root.lstat()
        build = dict(inputSourceGraphSealSHA256="a"*64, buildSucceeded=True, primaryFailure=None, cleanupFailures=[],
            compilerRootIdentity=dict(device=observed.st_dev, inode=observed.st_ino, uid=observed.st_uid,
                gid=observed.st_gid, mode=stat.S_IMODE(observed.st_mode)),
            commands=[dict(success=True, leaderReaped=True, groupGone=True)], executable=str(executable),
            executableSHA256="0"*64, actualBuiltSourceSealSHA256="b"*64,
            actualProviderLockRawSHA256="c"*64, workspaceStateSHA256="d"*64)
        (evidence / "BUILD.json").write_text(json.dumps(build))
        args = SimpleNamespace(build_root=root, evidence_root=evidence, output=self.base / "artifact-products",
            graph_seal_sha256="a"*64, kind="provider-history", producer_exit_status=self.base / "producer-exit.status")
        args.producer_exit_status.write_bytes(b"0\n")
        return args, build

    def test_real_mismatched_binary_refuses_before_any_staging(self):
        args, build = self.bad_provider_case()
        with self.assertRaisesRegex(RuntimeError, "^actual_build_output_digest_changed$"):
            self.inputs.stage(args, self.zip)
        self.assertFalse(args.output.exists())

    def test_actual_changed_compiler_identity_refuses_before_staging(self):
        args, build = self.bad_provider_case()
        build["compilerRootIdentity"]["inode"] += 1
        (args.evidence_root / "BUILD.json").write_text(json.dumps(build))
        with self.assertRaisesRegex(RuntimeError, "^actual_compiler_namespace_changed$"):
            self.inputs.stage(args, self.zip)
        self.assertFalse(args.output.exists())

    def test_actual_nonzero_producer_status_cannot_adopt_positive_json(self):
        args, build = self.bad_provider_case()
        args.producer_exit_status.write_bytes(b"1\n")
        with self.assertRaisesRegex(RuntimeError, "^actual_original_producer_exit_required$"):
            self.inputs.stage(args, self.zip)
        self.assertFalse(args.output.exists())


if __name__ == "__main__":
    unittest.main()
