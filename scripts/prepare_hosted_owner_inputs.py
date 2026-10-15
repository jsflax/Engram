"""SOURCE ONLY: bounded extraction of exact future hosted owner input DATA.

No account, provider, trust, compiler or Native action occurs. The caller must
supply an independently accepted real four-role legacy profile/images and actual
provider build receipt; archive/hash correspondence is not that acceptance.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import zipfile

MAX_ARCHIVE = 2 * 1024**3
MAX_EXPANDED = 8 * 1024**3
MAX_FILES = 50000
MAX_MEMBER = 512 * 1024**2


def require(value, code):
    if not value:
        raise RuntimeError(code)


def identity(value):
    return (value.st_dev, value.st_ino, value.st_uid, value.st_gid, value.st_mode,
            value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


@contextmanager
def source_descriptor(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        yield descriptor
    except BaseException as first_failure:
        try:
            os.close(descriptor)
        except BaseException as close_failure:
            raise first_failure from close_failure
        raise
    else:
        os.close(descriptor)


def sha_file(path, maximum):
    with source_descriptor(path) as fd:
        first = os.fstat(fd)
        require(stat.S_ISREG(first.st_mode) and first.st_nlink == 1 and 0 < first.st_size <= maximum,
                "input_file_type_size")
        value, count = hashlib.sha256(), 0
        while count < first.st_size:
            part = os.read(fd, min(65536, first.st_size - count))
            require(part, "input_short_read")
            count += len(part); value.update(part)
        require(not os.read(fd, 1) and identity(first) == identity(os.fstat(fd)) == identity(path.lstat()),
                "input_identity_changed")
        return value.hexdigest()


def unique(items):
    result = {}
    for key, value in items:
        require(key not in result, "input_duplicate_json_key")
        result[key] = value
    return result


def bounded_json(path, maximum):
    require(path.lstat().st_size <= maximum, "input_json_size")
    with source_descriptor(path) as fd:
        first = os.fstat(fd)
        require(stat.S_ISREG(first.st_mode) and first.st_nlink == 1 and first.st_size <= maximum,
                "input_json_type_size")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            raw = stream.read(first.st_size + 1)
        require(len(raw) == first.st_size and identity(first) == identity(os.fstat(fd)) == identity(path.lstat()),
                "input_json_identity_changed")
        return json.loads(raw, object_pairs_hook=unique)


def extract(archive, expected, root):
    # Bound the actual ZIP central-directory bytes/entry count BEFORE ZipFile
    # allocates its inventory. ZIP64 and split archives are deliberately refused.
    with source_descriptor(archive) as descriptor:
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            original = os.fstat(stream.fileno())
            require(stat.S_ISREG(original.st_mode) and original.st_nlink == 1 and 0 < original.st_size <= MAX_ARCHIVE
                and identity(original) == identity(archive.lstat()), "input_archive_open_changed")
            digest, read = hashlib.sha256(), 0
            while read < original.st_size:
                part = stream.read(min(65536, original.st_size - read))
                require(part, "input_archive_short_read")
                read += len(part); digest.update(part)
            require(not stream.read(1) and digest.hexdigest() == expected
                and identity(original) == identity(os.fstat(stream.fileno())) == identity(archive.lstat()), "input_archive_digest")
            size = original.st_size
            stream.seek(max(0, size - 65557)); tail = stream.read(65557)
            offset = tail.rfind(b"PK\x05\x06")
            require(offset >= 0 and len(tail) - offset >= 22, "input_zip_end")
            signature, disk, central_disk, disk_count, count, central_size, central_offset, comment = struct.unpack("<4s4H2LH", tail[offset:offset+22])
            require(disk == central_disk == 0 and disk_count == count and 0 < count <= MAX_FILES
                and count != 65535 and central_size <= 16 * 1024**2
                and central_offset + central_size <= size and offset + 22 + comment == len(tail), "input_zip_inventory_bound")
            end_position = size - len(tail) + offset
            require(end_position >= 20, "input_zip_ordinary_layout")
            stream.seek(end_position - 20)
            locator = stream.read(20)
            require(len(locator) == 20 and locator[:4] != b"PK\x06\x07", "input_zip64_locator_refused")
            require(central_offset + central_size == end_position, "input_zip_ordinary_layout")
            stream.seek(central_offset)
            central = stream.read(central_size)
            require(len(central) == central_size, "input_zip_central_short_read")
            # Count actual headers before ZipFile allocates ZipInfo inventory.
            # Advertised EOCD count is only a final equality check, not a cap.
            cursor, actual_count = 0, 0
            while cursor < len(central):
                actual_count += 1
                require(actual_count <= MAX_FILES, "input_zip_actual_inventory_bound")
                require(cursor + 46 <= len(central) and central[cursor:cursor+4] == b"PK\x01\x02",
                        "input_zip_central_header")
                version, flags, method = struct.unpack_from("<3H", central, cursor + 6)
                compressed, expanded = struct.unpack_from("<2L", central, cursor + 20)
                name_size, extra_size, comment_size, start_disk = struct.unpack_from("<4H", central, cursor + 28)
                local_offset = struct.unpack_from("<L", central, cursor + 42)[0]
                require(version <= 20 and not flags & 1 and method in (0, 8) and start_disk == 0
                    and compressed != 0xffffffff and expanded != 0xffffffff and local_offset != 0xffffffff,
                    "input_zip_ordinary_entry_required")
                stop = cursor + 46 + name_size + extra_size + comment_size
                require(name_size > 0 and stop <= len(central), "input_zip_central_entry_size")
                extra = cursor + 46 + name_size
                extra_end = extra + extra_size
                while extra < extra_end:
                    require(extra + 4 <= extra_end, "input_zip_extra_header")
                    kind, length = struct.unpack_from("<2H", central, extra)
                    require(kind != 1 and extra + 4 + length <= extra_end, "input_zip64_extra_refused")
                    extra += 4 + length
                cursor = stop
            require(cursor == len(central) and actual_count == count, "input_zip_preinventory_count_changed")
            with zipfile.ZipFile(stream) as archive_zip:
                entries = archive_zip.infolist()
                require(len(entries) == count, "input_zip_count_changed")
                plans, seen, expanded = [], set(), 0
                for member in entries:
                    name = member.filename.rstrip("/") if member.is_dir() else member.filename
                    path = PurePosixPath(name)
                    mode = member.external_attr >> 16
                    require(name and name == path.as_posix() and not path.is_absolute()
                        and all(part not in ("", ".", "..") for part in path.parts)
                        and member.orig_filename == member.filename and "\0" not in name
                        and len(name.encode()) <= 1024 and name not in seen, "input_zip_path")
                    require(stat.S_IFMT(mode) in (0, stat.S_IFDIR if member.is_dir() else stat.S_IFREG)
                        and not mode & 0o7000 and 0 <= member.file_size <= MAX_MEMBER, "input_zip_member_type_size")
                    expanded += member.file_size
                    require(expanded <= MAX_EXPANDED, "input_zip_expansion_bound")
                    seen.add(name); plans.append((member, root / path, mode))
                root.mkdir(mode=0o700)  # Fresh, no reuse/overwrite/reset.
                for member, destination, mode in plans:
                    if member.is_dir():
                        destination.mkdir(parents=True, exist_ok=True)
                        continue
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with archive_zip.open(member) as source, destination.open("xb") as output:
                        count = 0
                        while count < member.file_size:
                            part = source.read(min(65536, member.file_size - count))
                            require(part, "input_zip_short_member")
                            count += len(part); output.write(part)
                        require(not source.read(1), "input_zip_member_grew")
                        output.flush(); os.fsync(output.fileno())
                    destination.chmod(mode & 0o777 if mode & 0o777 else 0o600)
            require(identity(original) == identity(os.fstat(stream.fileno())) == identity(archive.lstat()),
                    "input_archive_changed_during_extract")


def main():
    ap = argparse.ArgumentParser(allow_abbrev=False)
    ap.add_argument("--metadata", type=Path, required=True)
    ap.add_argument("--archive", type=Path, required=True)
    ap.add_argument("--archive-sha256", required=True)
    ap.add_argument("--artifact-id", required=True)
    ap.add_argument("--producer-run-id", required=True)
    ap.add_argument("--graph-seal-sha256", required=True)
    ap.add_argument("--required-sha256", required=True)
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--github-env", type=Path, required=True)
    args = ap.parse_args()
    require(os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
        and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch" and os.environ.get("GITHUB_RUN_ATTEMPT") == "1",
        "input_actual_first_hosted_dispatch")
    for pin in [args.archive_sha256, args.graph_seal_sha256, args.required_sha256]:
        require(re.fullmatch(r"[0-9a-f]{64}", pin), "input_exact_digest")
    require(re.fullmatch(r"[1-9][0-9]{0,19}", args.artifact_id)
        and re.fullmatch(r"[1-9][0-9]{0,19}", args.producer_run_id), "input_actual_artifact_id")
    root = args.root.absolute()
    require("localdev" in root.parts and root.parent.resolve(strict=True) == root.parent
        and not os.path.lexists(root), "input_fresh_root")
    metadata = bounded_json(args.metadata, 1024**2)
    require(metadata["id"] == int(args.artifact_id) and metadata["workflow_run"]["id"] == int(args.producer_run_id)
        and metadata["name"] == "lattice-owner-inputs-v1" and metadata["expired"] is False
        and 0 < metadata["size_in_bytes"] <= MAX_ARCHIVE, "input_actual_artifact_correspondence")
    extract(args.archive, args.archive_sha256, root)
    values = bounded_json(root / "INPUTS.json", 1024**2)
    fields = {"schema", "graphSealSHA256", "requiredSHA256", "ownerLockSHA256", "cacheSealSHA256",
              "configSealSHA256", "legacyProfileSHA256", "providerExecutableSHA256"}
    require(set(values) == fields and values["schema"] == "lattice-hosted-owner-inputs/1", "input_manifest_shape")
    for key in fields - {"schema"}:
        require(re.fullmatch(r"[0-9a-f]{64}", values[key]), "input_manifest_digest")
    require(values["graphSealSHA256"] == args.graph_seal_sha256 and values["requiredSHA256"] == args.required_sha256,
            "input_selected_graph_changed")
    for leaf, key, maximum in [("SOURCE-GRAPH-SEAL.json", "graphSealSHA256", 16*1024**2),
            ("OWNER-DEPENDENCIES.json", "requiredSHA256", 16*1024**2), ("OwnerImages.Package.resolved", "ownerLockSHA256", 1024**2),
            ("CACHE-SEAL.json", "cacheSealSHA256", 16*1024**2), ("CONFIG-SEAL.json", "configSealSHA256", 1024**2),
            ("legacy.hpp", "legacyProfileSHA256", 1024**2), ("provider/executable", "providerExecutableSHA256", MAX_MEMBER)]:
        require(sha_file(root / leaf, maximum) == values[key], "input_pinned_member_changed")
    build = bounded_json(root / "provider/BUILD.json", 16*1024**2)
    require(build["inputSourceGraphSealSHA256"] == args.graph_seal_sha256
        and re.fullmatch(r"[0-9a-f]{64}", build["actualBuiltSourceSealSHA256"])
        and build["executableSHA256"] == values["providerExecutableSHA256"], "input_provider_build_correspondence")
    # These exact inputs still need independent genuine producer acceptance.
    # A field named qualified in JSON is never read or treated as authority.
    env = {"OWNER_INPUT_ROOT": str(root), **{"OWNER_" + key.upper(): value for key, value in values.items() if key != "schema"}}
    require(all(re.fullmatch(r"[A-Za-z0-9_./-]+", value) for value in env.values()), "input_env_encoding")
    with args.github_env.open("a") as output:
        for key, value in env.items():
            output.write(key + "=" + value + "\n")


if __name__ == "__main__":
    main()
