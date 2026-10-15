"""SOURCE ONLY: transport/stage actual image-build DATA, never qualify a profile."""
import sys
if not (sys.flags.isolated and sys.flags.no_site and sys.flags.dont_write_bytecode
        and sys.implementation.name == "cpython" and sys.version_info >= (3, 11)):
    raise RuntimeError("isolated_no_site_no_bytecode_cpython_required")
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import zipfile
import types

ZIP_HELPER_SHA256 = "898584cde6aff6764c089899e77dc51a59a57872d2d1f3933782bf88647d91a6"


def require(value, code):
    if not value:
        raise RuntimeError(code)


def identity(value):
    return (value.st_dev, value.st_ino, value.st_uid, value.st_gid, value.st_mode,
            value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def bounded(path, maximum):
    require(path.is_absolute() and path.resolve(strict=True) == path, "build_data_canonical_file")
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        first = os.fstat(descriptor)
        require(stat.S_ISREG(first.st_mode) and first.st_nlink == 1 and 0 < first.st_size <= maximum
            and identity(first) == identity(path.lstat()), "build_data_file_bound")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            raw = stream.read(first.st_size + 1)
        require(len(raw) == first.st_size and identity(first) == identity(os.fstat(descriptor))
            == identity(path.lstat()), "build_data_file_changed")
    except BaseException as first_failure:
        try:
            os.close(descriptor)
        except BaseException as close_failure:
            raise first_failure from close_failure
        raise
    else:
        os.close(descriptor)
    return raw


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def zip_helper():
    path = Path(__file__).absolute().with_name("prepare_hosted_owner_inputs.py")
    raw = bounded(path, 65536)
    require(digest(raw) == ZIP_HELPER_SHA256, "actual_bounded_zip_supplier_changed")
    namespace = {"__name__": "owned_build_zip_data", "__file__": str(path)}
    exec(compile(raw, str(path), "exec"), namespace)
    return types.SimpleNamespace(**namespace)


def first_copy(source, target, expected=None, maximum=512 * 1024**2):
    raw = bounded(source, maximum)
    require(expected is None or digest(raw) == expected, "actual_build_output_digest_changed")
    first_bytes(target, raw)
    target.chmod(stat.S_IMODE(source.lstat().st_mode) & 0o777)
    return dict(name=target.name, bytes=len(raw), sha256=digest(raw))


def first_bytes(target, raw):
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        at = 0
        while at < len(raw):
            count = os.write(descriptor, raw[at:])
            require(count > 0, "actual_build_output_short_write")
            at += count
        os.fsync(descriptor)
    except BaseException as first_failure:
        try:
            os.close(descriptor)
        except BaseException as close_failure:
            raise first_failure from close_failure
        raise
    else:
        os.close(descriptor)



PAYLOAD_NAME = "lattice-owner-build-inputs-v1.zip"


def extract_build_payload(args, helper):
    """Unwrap ONLY the Actions single-file envelope, never a general source member.

    The outer archive remains independently hashed. Its actual central directory
    must contain exactly one ordinary entry BEFORE ZipFile allocates inventory.
    The separately pinned inner ZIP streams to one fresh owned namespace; its
    generic source members are subsequently checked by the unchanged extractor.
    """
    require(re.fullmatch(r"[0-9a-f]{64}", args.payload_sha256)
        and type(args.payload_bytes) is int and 0 < args.payload_bytes <= helper.MAX_ARCHIVE,
        "actual_build_payload_pin_or_size")
    namespace = args.root.with_name(args.root.name + "-payload")
    require(namespace.parent.resolve(strict=True) == namespace.parent
        and not os.path.lexists(namespace), "fresh_actual_build_payload_namespace")
    payload = namespace / PAYLOAD_NAME
    with helper.source_descriptor(args.archive) as descriptor:
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            first = os.fstat(descriptor)
            require(stat.S_ISREG(first.st_mode) and first.st_nlink == 1
                and 0 < first.st_size <= helper.MAX_ARCHIVE
                and identity(first) == identity(args.archive.lstat()), "build_envelope_open_changed")
            observed, count = hashlib.sha256(), 0
            while count < first.st_size:
                part = stream.read(min(65536, first.st_size - count))
                require(part, "build_envelope_short_read")
                observed.update(part); count += len(part)
            require(not stream.read(1) and observed.hexdigest() == args.archive_sha256
                and identity(first) == identity(os.fstat(descriptor)) == identity(args.archive.lstat()),
                "build_envelope_digest")
            stream.seek(max(0, first.st_size - 65557)); tail = stream.read(65557)
            end = tail.rfind(b"PK\x05\x06")
            require(end >= 0 and len(tail) - end >= 22, "build_envelope_end")
            _, disk, central_disk, disk_count, entry_count, central_size, central_offset, comment = struct.unpack(
                "<4s4H2LH", tail[end:end + 22])
            end_position = first.st_size - len(tail) + end
            require(disk == central_disk == 0 and disk_count == entry_count == 1
                and 46 <= central_size <= 65536 and end + 22 + comment == len(tail)
                and end_position >= 20 and central_offset + central_size == end_position,
                "build_envelope_single_ordinary_inventory")
            stream.seek(end_position - 20)
            require(stream.read(4) != b"PK\x06\x07", "build_envelope_zip64_locator")
            stream.seek(central_offset); central = stream.read(central_size)
            require(len(central) == central_size and central[:4] == b"PK\x01\x02", "build_envelope_central_header")
            version, flags, method = struct.unpack_from("<3H", central, 6)
            compressed, expanded = struct.unpack_from("<2L", central, 20)
            name_size, extra_size, comment_size, start_disk = struct.unpack_from("<4H", central, 28)
            local_offset = struct.unpack_from("<L", central, 42)[0]
            require(version <= 20 and not flags & ~0x808 and method in (0, 8) and start_disk == 0
                and compressed != 0xffffffff and expanded == args.payload_bytes and local_offset == 0
                and 46 + name_size + extra_size + comment_size == len(central)
                and central[46:46 + name_size] == PAYLOAD_NAME.encode(), "build_envelope_exact_payload_entry")
            at, stop = 46 + name_size, 46 + name_size + extra_size
            while at < stop:
                require(at + 4 <= stop, "build_envelope_extra_header")
                kind, length = struct.unpack_from("<2H", central, at)
                require(kind != 1 and at + 4 + length <= stop, "build_envelope_zip64_extra")
                at += 4 + length
            # Exactly one complete central record was consumed above. No claimed
            # EOCD count can hide a larger inventory from this narrow preflight.
            with zipfile.ZipFile(stream) as archive_zip:
                entries = archive_zip.infolist()
                require(len(entries) == 1, "build_envelope_inventory_changed")
                member = entries[0]
                mode = member.external_attr >> 16
                require(member.filename == member.orig_filename == PAYLOAD_NAME and not member.is_dir()
                    and member.header_offset == 0 and member.file_size == args.payload_bytes
                    and member.compress_size == compressed and member.compress_type == method
                    and member.flag_bits == flags and stat.S_IFMT(mode) in (0, stat.S_IFREG)
                    and not mode & 0o7000, "build_envelope_payload_changed")
                namespace.mkdir(mode=0o700)  # Exclusive; retained partial output is never reset/retried.
                created = namespace.lstat()
                output = os.open(payload, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
                try:
                    written, value = 0, hashlib.sha256()
                    with archive_zip.open(member) as source:
                        while written < args.payload_bytes:
                            part = source.read(min(65536, args.payload_bytes - written))
                            require(part, "build_envelope_payload_truncated")
                            value.update(part)
                            at = 0
                            while at < len(part):
                                count = os.write(output, part[at:])
                                require(count > 0, "build_envelope_payload_short_write")
                                at += count
                            written += len(part)
                        require(not source.read(1), "build_envelope_payload_grew")
                    require(written == args.payload_bytes and value.hexdigest() == args.payload_sha256,
                        "build_envelope_payload_digest")
                    os.fsync(output)
                    opened, named = os.fstat(output), payload.lstat()
                    require(identity(opened) == identity(named) and opened.st_size == args.payload_bytes
                        and opened.st_nlink == 1 and stat.S_ISREG(opened.st_mode)
                        and stat.S_IMODE(opened.st_mode) == 0o600 and opened.st_uid == os.geteuid(),
                        "build_envelope_output_changed")
                except BaseException as first_failure:
                    try:
                        os.close(output)
                    except BaseException as close_failure:
                        raise first_failure from close_failure
                    raise
                else:
                    os.close(output)  # Never retry an ambiguous close.
                current = namespace.lstat()
                require((created.st_dev, created.st_ino, created.st_uid, created.st_gid, created.st_mode)
                    == (current.st_dev, current.st_ino, current.st_uid, current.st_gid, current.st_mode),
                    "build_envelope_namespace_changed")
            require(identity(first) == identity(os.fstat(descriptor)) == identity(args.archive.lstat()),
                "build_envelope_changed_during_extract")
    return payload


def prepare(args, helper):
    for pin in [args.archive_sha256, args.payload_sha256, args.graph_seal_sha256, args.required_sha256]:
        require(re.fullmatch(r"[0-9a-f]{64}", pin), "actual_build_input_digest")
    require(re.fullmatch(r"[1-9][0-9]{0,19}", args.artifact_id)
        and re.fullmatch(r"[1-9][0-9]{0,19}", args.producer_run_id), "actual_build_input_artifact_id")
    root = args.root.absolute()
    require("localdev" in root.parts and root.parent.resolve(strict=True) == root.parent
        and not os.path.lexists(root), "fresh_actual_build_input_root")
    metadata = helper.bounded_json(args.metadata, 1024**2)
    require(metadata["id"] == int(args.artifact_id) and metadata["workflow_run"]["id"] == int(args.producer_run_id)
        and metadata["name"] == "lattice-owner-build-inputs-v1" and metadata["expired"] is False
        and 0 < metadata["size_in_bytes"] <= helper.MAX_ARCHIVE, "actual_build_artifact_correspondence")
    payload = extract_build_payload(args, helper)
    helper.extract(payload, args.payload_sha256, root)
    values = helper.bounded_json(root / "BUILD-INPUTS.json", 1024**2)
    fields = {"schema", "graphSealSHA256", "requiredSHA256", "ownerLockSHA256", "cacheSealSHA256",
              "configSealSHA256", "legacyBundleSHA256"}
    require(set(values) == fields and values["schema"] == "lattice-owner-build-inputs/1", "actual_build_input_shape")
    for key in fields - {"schema"}:
        require(re.fullmatch(r"[0-9a-f]{64}", values[key]), "actual_build_manifest_digest")
    require(values["graphSealSHA256"] == args.graph_seal_sha256 and values["requiredSHA256"] == args.required_sha256,
            "actual_build_selected_source_changed")
    for leaf, key, maximum in [("SOURCE-GRAPH-SEAL.json", "graphSealSHA256", 16*1024**2),
        ("OWNER-DEPENDENCIES.json", "requiredSHA256", 16*1024**2), ("OwnerImages.Package.resolved", "ownerLockSHA256", 1024**2),
        ("CACHE-SEAL.json", "cacheSealSHA256", 16*1024**2), ("CONFIG-SEAL.json", "configSealSHA256", 1024**2),
        ("legacy.bundle", "legacyBundleSHA256", 512*1024**2)]:
        require(helper.sha_file(root / leaf, maximum) == values[key], "actual_build_input_member_changed")
    # Complete graph/cache/config census checks remain in each actual producer.
    # Neither this transport manifest nor a build output authorizes a profile.
    env = {"OWNER_BUILD_INPUT_ROOT": str(root), **{"OWNER_BUILD_" + key.upper(): value
        for key, value in values.items() if key != "schema"}}
    require(all(re.fullmatch(r"[A-Za-z0-9_./-]+", value) for value in env.values()), "actual_build_env_encoding")
    with args.github_env.open("a") as output:
        for key, value in env.items():
            output.write(key + "=" + value + "\n")


def stage(args, helper):
    root = args.build_root.absolute()
    require(root.resolve(strict=True) == root and "localdev" in root.parts, "actual_build_root")
    evidence = args.evidence_root.absolute()
    require(evidence.resolve(strict=True) == evidence and "localdev" in evidence.parts
        and evidence.lstat().st_uid == os.geteuid() and stat.S_IMODE(evidence.lstat().st_mode) == 0o700,
        "actual_owned_build_evidence_namespace")
    output = args.output.absolute()
    require(output.parent == evidence.parent and not os.path.lexists(output), "first_actual_build_output_namespace")
    status = args.producer_exit_status.absolute()
    require(status.parent == evidence.parent and bounded(status, 4) == b"0\n", "actual_original_producer_exit_required")
    build = helper.bounded_json(evidence / "BUILD.json", 16*1024**2)
    observed = root.lstat()
    require(build["compilerRootIdentity"] == dict(device=observed.st_dev, inode=observed.st_ino,
        uid=observed.st_uid, gid=observed.st_gid, mode=stat.S_IMODE(observed.st_mode)), "actual_compiler_namespace_changed")
    require(build["inputSourceGraphSealSHA256"] == args.graph_seal_sha256 and build["buildSucceeded"] is True
        and build["primaryFailure"] is None and build["cleanupFailures"] == [], "actual_build_outcome_required")
    rows = build["commands"]
    require(type(rows) is list and 0 < len(rows) <= 192 and all(row["success"] is True
        and row["leaderReaped"] is True and row["groupGone"] is True for row in rows), "actual_build_command_custody_required")
    # Validate every product and digest before creating the staging namespace.
    products = []
    if args.kind == "provider-history":
        source = Path(build["executable"])
        require(source.is_relative_to(root / "scratch") and source.lstat().st_mode & 0o111
            and re.fullmatch(r"[0-9a-f]{64}", build["actualBuiltSourceSealSHA256"]), "actual_provider_output_path")
        products.append((source, "executable", build["executableSHA256"]))
        facts = [("ACTUAL-BUILT-SOURCE-SEAL.json", build["actualBuiltSourceSealSHA256"]),
                 ("ACTUAL-PROVIDER-Package.resolved", build["actualProviderLockRawSHA256"]),
                 ("BEFORE-RESOLUTION-SOURCE.json", None), ("ACTUAL-WORKSPACE-STATE.json", build["workspaceStateSHA256"]),
                 ("ACTUAL-RESOLVED-CACHE-SEAL.json", None)]
    else:
        require(build["qualificationImagesOnly"] is True and build["legacySemanticProfileQualified"] is False
            and build["fixedLegacyRoleSpawnQualified"] is False and build["developerIDReleaseEvidence"] is False,
            "legacy_build_only_scope_required")
        images = {row["role"]: row for row in build["images"]}
        require(set(images) == {"memory", "memory-hooks", "memory-sync", "Engram"}, "actual_four_legacy_images_required")
        for role, row in images.items():
            source = Path(row["path"])
            require(source == root / "images" / role and source.lstat().st_mode & 0o111, "actual_legacy_image_path")
            products.append((source, role, row["sha256"]))
        tar = build["actualGUIApplicationTar"]
        require(tar["path"] == str(root / "Engram.app.tar") and tar["extractedCodeValidityOrRoleAcceptance"] is False,
                "actual_unqualified_gui_archive_required")
        products.append((root / "Engram.app.tar", "Engram.app.tar", tar["sha256"]))
        facts = [("ACTUAL-GUI-CLI-PAYLOAD.json", None), ("ACTUAL-LEGACY-BEFORE-SOURCE.json", None),
                 ("ACTUAL-LEGACY-WORKSPACE.json", None), ("ACTUAL-LEGACY-CACHE-SEAL.json", None)]
    for source, name, pin in products:
        require(re.fullmatch(r"[0-9a-f]{64}", pin) and digest(bounded(source, 512*1024**2)) == pin,
                "actual_build_output_digest_changed")
    for leaf, pin in facts:
        raw = bounded(evidence / leaf, 16*1024**2)
        require(pin is None or digest(raw) == pin, "actual_build_fact_changed")
    output.mkdir(mode=0o700)
    records = [first_copy(evidence / "BUILD.json", output / "BUILD.json", maximum=16*1024**2)]
    for source, name, pin in products:
        records.append(first_copy(source, output / name, pin))
    for leaf, pin in facts:
        records.append(first_copy(evidence / leaf, output / leaf, pin, 16*1024**2))
    # A first-write DATA scope receipt, never an available/qualified profile.
    scope = dict(schema="lattice-owner-image-build-only/1", kind=args.kind, graphSealSHA256=args.graph_seal_sha256,
        buildOnly=True, legacySemanticProfileQualified=False, roleSpawnQualified=False,
        providerTLSQualified=False, ownerRuntimeQualified=False, sourceAcceptedByReceipt=False,
        producerExitStatusFileSHA256=digest(bounded(status, 4)), files=records)
    target = output / "BUILD-ONLY.json"
    first_bytes(target, (json.dumps(scope, indent=2, sort_keys=True) + "\n").encode())


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    sub = parser.add_subparsers(dest="operation", required=True)
    prepare_parser = sub.add_parser("prepare", allow_abbrev=False)
    for name in ["metadata", "archive", "root", "github-env"]:
        prepare_parser.add_argument("--" + name, type=Path, required=True)
    for name in ["archive-sha256", "payload-sha256", "artifact-id", "producer-run-id", "graph-seal-sha256", "required-sha256"]:
        prepare_parser.add_argument("--" + name, required=True)
    prepare_parser.add_argument("--payload-bytes", type=int, required=True)
    stage_parser = sub.add_parser("stage", allow_abbrev=False)
    stage_parser.add_argument("--kind", choices=["provider-history", "fixed-legacy4"], required=True)
    for name in ["build-root", "evidence-root", "producer-exit-status", "output"]:
        stage_parser.add_argument("--" + name, type=Path, required=True)
    stage_parser.add_argument("--graph-seal-sha256", required=True)
    args = parser.parse_args()
    require(sys.platform == "darwin" and os.geteuid() > 0
        and os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
        and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch" and os.environ.get("GITHUB_RUN_ATTEMPT") == "1"
        and os.environ.get("GITHUB_REPOSITORY", "").lower() == "jsflax/engram"
        and os.environ.get("ENGRAM_WORKFLOW_SHA") == os.environ.get("GITHUB_SHA")
        and re.fullmatch(r"[0-9a-f]{40}", os.environ.get("GITHUB_SHA", "")), "actual_first_hosted_build_transport")
    helper = zip_helper()
    if args.operation == "prepare":
        prepare(args, helper)
    else:
        stage(args, helper)


if __name__ == "__main__":
    main()
