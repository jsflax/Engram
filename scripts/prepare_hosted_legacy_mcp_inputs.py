"""Bind one actual graph030 image artifact as DATA for a future hosted MCP case."""
import sys
if not (sys.flags.isolated and sys.flags.no_site and sys.flags.dont_write_bytecode
        and sys.implementation.name == 'cpython' and sys.version_info >= (3, 11)):
    raise RuntimeError('mcp_input_isolated_no_site_no_bytecode_cpython_required')
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import re
import stat
import types

GRAPH_SHA256 = '862bcb67152c37d2f68559019e27b50b96f32c4384075794d75d371dfb2e6041'
REQUIRED_SHA256 = 'bc3d03cba8e3e07f0b77c605db2b2e2ca22497614dbfcbfb624b47fbba280726'
SCANNER_SHA256 = '898584cde6aff6764c089899e77dc51a59a57872d2d1f3933782bf88647d91a6'
ARTIFACT_ID = 11954047235
PRODUCER_RUN_ID = 38693144742
PRODUCER_HEAD = 'caa6573d8d70f76c8973cc27445e0d9ebf28239a'
ARCHIVE_BYTES = 167333147
ARCHIVE_SHA256 = '34d36f0cad321c2d85206a2a7649cb09ad4a4acc1765f91b0bec064df19f286d'
BUILD_SHA256 = '74fc996f376cd86c857220fc4d7e9274090db2be1d2a0f1c471886fa11dacb62'
BUILD_ONLY_SHA256 = '3d2f5184b3d1d0c91b78c1c02c7dbf76ab74a75ba4148f5ff01a88b74cbe3dd5'
TAR_BYTES = 270611968
TAR_SHA256 = '2a6bc06be31b0a4a0cdc4f8774fa8fcb3ced4c6dc60a3c8b7bf2d8e1b389c9a0'
LEGACY_GRAPH_SHA256 = 'fbe38ccfb66ea8f0ec6e0d18aa736777287e9c5aa3fddae49a75a6c5749cf4e4'
FACTS = [('artifact-products/BUILD.json',236290,BUILD_SHA256),
    ('artifact-products/BUILD-ONLY.json',2037,BUILD_ONLY_SHA256),
    ('producer-exit.status',2,'9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa'),
    ('artifact-products/Engram.app.tar',TAR_BYTES,TAR_SHA256),
    ('evidence/BUILD.json',236290,BUILD_SHA256)]


def require(value, code):
    if not value:
        raise RuntimeError(code)


def identity(item):
    return (item.st_dev,item.st_ino,item.st_uid,item.st_gid,item.st_mode,
        item.st_nlink,item.st_size,item.st_mtime_ns,item.st_ctime_ns)


def bounded_bytes(path, maximum):
    first = path.lstat()
    require(path.resolve(strict=True) == path and stat.S_ISREG(first.st_mode)
        and first.st_nlink == 1 and 0 <= first.st_size <= maximum,'mcp_input_source_type_size')
    descriptor = os.open(path,os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW|os.O_CLOEXEC)
    try:
        require(identity(first) == identity(os.fstat(descriptor)),'mcp_input_source_open_changed')
        body = bytearray()
        while len(body) < first.st_size:
            part = os.read(descriptor,min(65536,first.st_size-len(body)))
            require(part,'mcp_input_source_short_read');body.extend(part)
        require(not os.read(descriptor,1) and identity(first) == identity(os.fstat(descriptor))
            == identity(path.lstat()),'mcp_input_source_changed')
    except BaseException as failure:
        try:os.close(descriptor)
        except BaseException as close:raise failure from close
        raise
    else:os.close(descriptor)
    require(identity(first) == identity(path.lstat()),'mcp_input_source_close_changed')
    return bytes(body)


def unique(items):
    result = {}
    for key,value in items:
        require(key not in result,'mcp_input_duplicate_json');result[key]=value
    return result


def validate_metadata(metadata):
    require(type(metadata) is dict and type(metadata.get('id')) is int and metadata['id'] == ARTIFACT_ID
        and metadata.get('name') == 'owner-image-build-fixed-legacy4-38693144742-1'
        and metadata.get('expired') is False and type(metadata.get('size_in_bytes')) is int
        and metadata['size_in_bytes'] == ARCHIVE_BYTES and metadata.get('digest') == 'sha256:'+ARCHIVE_SHA256,
        'mcp_original_image_artifact_correspondence')
    run = metadata.get('workflow_run')
    require(type(run) is dict and type(run.get('id')) is int and run['id'] == PRODUCER_RUN_ID
        and run.get('head_sha') == PRODUCER_HEAD and type(run.get('repository_id')) is int
        and run['repository_id'] == 1157371341 and type(run.get('head_repository_id')) is int
        and run['head_repository_id'] == 1157371341
        and run.get('head_branch') == 'codex/owner-image-builds-20261015-001',
        'mcp_original_image_producer_correspondence')


def exclusive_receipt(path,value):
    body=(json.dumps(value,indent=2,sort_keys=True)+'\n').encode()
    require(len(body) <= 1024**2,'mcp_input_receipt_bound')
    descriptor=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
    try:
        at=0
        while at<len(body):
            count=os.write(descriptor,body[at:]);require(count>0,'mcp_input_receipt_short_write');at+=count
        os.fsync(descriptor)
    except BaseException as failure:
        try:os.close(descriptor)
        except BaseException as close:raise failure from close
        raise
    else:os.close(descriptor)
    return dict(path=str(path),bytes=len(body),sha256=hashlib.sha256(body).hexdigest())


def main():
    parser=argparse.ArgumentParser(allow_abbrev=False)
    for name in ['graph','graph-pins','required','metadata','archive','root','github-env']:
        parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    require(sys.flags.isolated and sys.flags.no_site and sys.flags.dont_write_bytecode
        and sys.implementation.name=='cpython' and sys.version_info >= (3,11)
        and sys.platform=='darwin' and platform.machine()=='arm64' and os.getuid()==os.geteuid()>0
        and int(platform.mac_ver()[0].split('.')[0])>=26
        and os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
        and os.environ.get('GITHUB_EVENT_NAME')=='workflow_dispatch' and os.environ.get('GITHUB_RUN_ATTEMPT')=='1'
        and os.environ.get('GITHUB_REPOSITORY')=='jsflax/Engram','mcp_input_actual_first_hosted_dispatch')
    args.graph=args.graph.absolute();args.root=args.root.absolute()
    base=Path(pwd.getpwuid(os.geteuid()).pw_dir)/'localdev'
    require(base.resolve(strict=True)==base and args.graph.resolve(strict=True)==args.graph
        and args.graph.is_relative_to(base) and args.root.parent.resolve(strict=True)==args.root.parent
        and args.root.parent.is_relative_to(base) and not os.path.lexists(args.root), 'mcp_input_fresh_localdev_root')
    parent=args.root.parent.lstat()
    require(stat.S_ISDIR(parent.st_mode) and parent.st_uid==os.geteuid()
        and stat.S_IMODE(parent.st_mode)==0o700,'mcp_input_private_parent')
    seal_raw=bounded_bytes(args.graph_pins,16*1024**2)
    require(hashlib.sha256(seal_raw).hexdigest()==GRAPH_SHA256
        and hashlib.sha256(bounded_bytes(args.required,16*1024**2)).hexdigest()==REQUIRED_SHA256,
        'mcp_input_exact031_source_required')
    seal=json.loads(seal_raw,object_pairs_hook=unique)
    source=args.graph/'Engram/scripts/prepare_hosted_owner_inputs.py'
    raw=bounded_bytes(source,1024**2)
    require(hashlib.sha256(raw).hexdigest()==SCANNER_SHA256
        and any(row.get('path')=='Engram/scripts/prepare_hosted_owner_inputs.py'
            and row.get('bytes')==len(raw) and row.get('sha256')==SCANNER_SHA256 for row in seal['files']),
        'mcp_input_exact_bounded_scanner')
    namespace={'__name__':'owned_mcp_image_data_scanner','__file__':str(source)}
    exec(compile(raw,str(source),'exec'),namespace);scanner=types.SimpleNamespace(**namespace)
    metadata_raw=bounded_bytes(args.metadata,1024**2)
    metadata=json.loads(metadata_raw,object_pairs_hook=unique);validate_metadata(metadata)
    archive=args.archive.absolute();initial=archive.lstat()
    require(archive.resolve(strict=True)==archive and archive.is_relative_to(base)
        and stat.S_ISREG(initial.st_mode) and initial.st_nlink==1 and initial.st_size==ARCHIVE_BYTES,
        'mcp_original_image_archive_bytes')
    scanner.extract(archive,ARCHIVE_SHA256,args.root)  # Direct image ZIP, not single-inner build-input envelope.
    facts=[]
    for relative,count,sha in FACTS:
        path=args.root/relative
        require(path.resolve(strict=True)==path and path.lstat().st_size==count
            and scanner.sha_file(path,count)==sha,'mcp_original_stage_receipt_changed')
        facts.append(dict(path=relative,bytes=count,sha256=sha))
    scope=scanner.bounded_json(args.root/'artifact-products/BUILD-ONLY.json',16*1024**2)
    build=scanner.bounded_json(args.root/'artifact-products/BUILD.json',16*1024**2)
    require(scope['graphSealSHA256']==LEGACY_GRAPH_SHA256 and scope['buildOnly'] is True
        and scope['kind']=='fixed-legacy4' and build['inputSourceGraphSealSHA256']==LEGACY_GRAPH_SHA256
        and build['buildSucceeded'] is True and build['primaryFailure'] is None
        and build['cleanupFailures']==[],'mcp_original_build_only031_role_input')
    require(identity(initial)==identity(archive.lstat())
        and bounded_bytes(args.metadata,1024**2)==metadata_raw,'mcp_original_transport_changed')
    root_stat=args.root.lstat()
    require(args.root.resolve(strict=True)==args.root and stat.S_ISDIR(root_stat.st_mode)
        and root_stat.st_uid==os.geteuid() and stat.S_IMODE(root_stat.st_mode)==0o700,'mcp_image_input_created_namespace')
    receipt=exclusive_receipt(args.root/'IMAGE-INPUT.json',dict(schema='lattice-hosted-legacy-mcp-image-input/1',
        artifactID=ARTIFACT_ID,producerRunID=PRODUCER_RUN_ID,originalProducerHead=PRODUCER_HEAD,
        archive=dict(bytes=ARCHIVE_BYTES,sha256=ARCHIVE_SHA256),metadataSHA256=hashlib.sha256(metadata_raw).hexdigest(),
        graph031SHA256=GRAPH_SHA256,required031SHA256=REQUIRED_SHA256,
        extractionRootIdentity=dict(device=root_stat.st_dev,inode=root_stat.st_ino,uid=root_stat.st_uid,
            gid=root_stat.st_gid,mode=stat.S_IMODE(root_stat.st_mode)),facts=facts,
        originalCompilerRootIdentity=build['compilerRootIdentity'],originalApplicationPath=build['actualGUIApplication'],
        transportedBytesOnly=True,roleSpawnQualified=False,legacySemanticProfileQualified=False,nativeAuthority=False))
    env=dict(MCP_LEGACY_BUILD=str(args.root/'artifact-products/BUILD.json'),
        MCP_LEGACY_BUILD_ONLY=str(args.root/'artifact-products/BUILD-ONLY.json'),
        MCP_LEGACY_APP_ARCHIVE=str(args.root/'artifact-products/Engram.app.tar'),
        MCP_LEGACY_PRODUCER_EXIT=str(args.root/'producer-exit.status'),
        MCP_LEGACY_BUILD_SHA=BUILD_SHA256,MCP_LEGACY_BUILD_ONLY_SHA=BUILD_ONLY_SHA256,
        MCP_LEGACY_APP_ARCHIVE_SHA=TAR_SHA256,MCP_LEGACY_APP_ARCHIVE_BYTES=str(TAR_BYTES))
    require(all(re.fullmatch(r'[A-Za-z0-9_./-]+',value) for value in env.values()),'mcp_input_env_encoding')
    with args.github_env.open('a') as output:
        for key,value in env.items():output.write(key+'='+value+'\n')
    print(json.dumps(dict(inputReceipt=receipt,roleSpawnQualified=False,nativeAuthority=False),sort_keys=True))


if __name__=='__main__':
    main()
