"""Stage original provider build DATA and fresh loopback TLS inputs, never a profile."""
import sys
if not (sys.flags.isolated and sys.flags.no_site and sys.flags.dont_write_bytecode
        and sys.implementation.name == 'cpython' and sys.version_info >= (3,11)):
    raise RuntimeError('daemon_input_isolated_no_site_no_bytecode_cpython_required')
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import re
import stat
import threading
import time
import types

GRAPH_SHA256='ff72d7b011016d175cb2271fb9e32c7475a95f3e9855ca8bf584a84b366d6b4f'
REQUIRED_SHA256='2a6a672849d3c9c8680e14427cc3120035ff0997ae99ced3eacedaa96486449a'
SCANNER_SHA256='898584cde6aff6764c089899e77dc51a59a57872d2d1f3933782bf88647d91a6'
COMMAND_SHA256='aab985543261f94b181a367bce56275c3203048bc2d2030b6e2708ecfca95f1b'
GATE_SHA256='b69a4a80b6b2c18653b52f26915ec9e21a0c8c90d41402915d5ec06559a8d8b8'
ARTIFACT_ID=11970489149
PRODUCER_RUN_ID=38731936118
PRODUCER_HEAD='caa6573d8d70f76c8973cc27445e0d9ebf28239a'
ARCHIVE_BYTES=44913234
ARCHIVE_SHA256='fae2e7a2f82e99e7b296997b032ffad5c165a15b3eca7bcd44c65d4922810b8c'
ORIGINAL_GRAPH='75544d5e726ecff3e52a92fe9823aa561dbd3111ce024e0a72700af05c17683c'
BUILD_SHA256='ef66b176b949c11b329cdf6d634fdf6341ad13711b7d65b2ee37da025a1cab76'
BUILD_ONLY_SHA256='52c65cae28bb588aa6ff35148a04dae4f2c6499ac94287372c26a3bbf9757628'
EXECUTABLE_BYTES=179003008
EXECUTABLE_SHA256='70593ae8831ed38b41eac84e2f764e4bd478496fa16942ce73989c3ab8c09a76'
FACTS=[('artifact-products/BUILD.json',44230,BUILD_SHA256),
    ('artifact-products/BUILD-ONLY.json',1614,BUILD_ONLY_SHA256),
    ('artifact-products/executable',EXECUTABLE_BYTES,EXECUTABLE_SHA256),
    ('producer-exit.status',2,'9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa'),
    ('evidence/BUILD.json',44230,BUILD_SHA256)]
_HELD=None


def require(value,code):
    if not value:raise RuntimeError(code)


def identity(item):
    return (item.st_dev,item.st_ino,item.st_uid,item.st_gid,item.st_mode,
        item.st_nlink,item.st_size,item.st_mtime_ns,item.st_ctime_ns)


def bounded_bytes(path,maximum):
    first=path.lstat()
    require(path.resolve(strict=True)==path and stat.S_ISREG(first.st_mode)
        and first.st_nlink==1 and 0<=first.st_size<=maximum,'daemon_input_source_type_size')
    descriptor=os.open(path,os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW|os.O_CLOEXEC)
    try:
        require(identity(first)==identity(os.fstat(descriptor)),'daemon_input_source_open_changed')
        body=bytearray()
        while len(body)<first.st_size:
            part=os.read(descriptor,min(65536,first.st_size-len(body)))
            require(part,'daemon_input_source_short_read');body.extend(part)
        require(not os.read(descriptor,1) and identity(first)==identity(os.fstat(descriptor))
            ==identity(path.lstat()),'daemon_input_source_changed')
    except BaseException as failure:
        try:os.close(descriptor)
        except BaseException as close:raise failure from close
        raise
    else:os.close(descriptor)
    require(identity(first)==identity(path.lstat()),'daemon_input_source_close_changed')
    return bytes(body)


def unique(items):
    value={}
    for key,item in items:
        require(key not in value,'daemon_input_duplicate_json');value[key]=item
    return value


def validate_metadata(value):
    require(type(value) is dict and type(value.get('id')) is int and value['id']==ARTIFACT_ID
        and value.get('name')=='owner-image-build-provider-history-38731936118-1'
        and value.get('expired') is False and type(value.get('size_in_bytes')) is int
        and value['size_in_bytes']==ARCHIVE_BYTES and value.get('digest')=='sha256:'+ARCHIVE_SHA256,
        'daemon_original_provider_artifact_correspondence')
    run=value.get('workflow_run')
    require(type(run) is dict and type(run.get('id')) is int and run['id']==PRODUCER_RUN_ID
        and run.get('head_sha')==PRODUCER_HEAD and type(run.get('repository_id')) is int
        and run['repository_id']==1157371341 and type(run.get('head_repository_id')) is int
        and run['head_repository_id']==1157371341
        and run.get('head_branch')=='codex/terminal-collection-provider-20261015-001',
        'daemon_original_provider_producer_correspondence')


def exclusive_receipt(path,value):
    raw=(json.dumps(value,indent=2,sort_keys=True)+'\n').encode()
    require(len(raw)<=1024**2,'daemon_input_receipt_bound')
    descriptor=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
    try:
        at=0
        while at<len(raw):
            count=os.write(descriptor,raw[at:]);require(count>0,'daemon_input_receipt_short_write');at+=count
        os.fsync(descriptor)
    except BaseException as failure:
        try:os.close(descriptor)
        except BaseException as close:raise failure from close
        raise
    else:os.close(descriptor)
    return dict(path=str(path),bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())


def load_source(path,pin,name):
    raw=bounded_bytes(path,1024**2)
    require(hashlib.sha256(raw).hexdigest()==pin,'daemon_input_exact_source_supplier')
    namespace={'__name__':name,'__file__':str(path)}
    exec(compile(raw,str(path),'exec'),namespace)
    return types.SimpleNamespace(**namespace)


class TLSInputs:
    """Only fixed actual openssl inputs under the existing retained command owner."""
    def __init__(self,args,command,began):
        self.args,self.command=args,command
        self.process,self.thread,self.uid=os.getpid(),threading.get_ident(),os.geteuid()
        self.stop=command.StopFlag()
        self.end=began+180  # This input preparation's original total end, never reset.
        self.root=args.root
        self.root_identity=identity(self.root.lstat())
        self.owner=self.negative=None
        self.old_umask=None
        self.results=dict(schema='lattice-daemon-loopback-tls-input/1',preparationSucceeded=False,
            nativeAuthority=False,providerTLSRuntimeQualified=False,legacySemanticProfileQualified=False,
            originalBudgetSeconds=180,primaryFailure=None,primaryException=None,commands=[],negativeCommands=[])

    def current(self):
        require(os.getpid()==self.process and threading.get_ident()==self.thread
            and os.getuid()==os.geteuid()==self.uid and self.uid>0,'daemon_input_creator_changed')
        actual=self.root.lstat()
        require(self.root.resolve(strict=True)==self.root and stat.S_ISDIR(actual.st_mode)
            and (actual.st_dev,actual.st_ino,actual.st_uid,actual.st_gid,actual.st_mode)==self.root_identity[:5]
            and not self.stop.requested and time.monotonic()<self.end,'daemon_input_canceled_late_or_root_changed')

    def run(self):
        self.current();error=None
        try:
            self.stop.install();self.old_umask=os.umask(0o077)
            for name in ['tls-receipts','tls-private','tls-negative-receipts','tls-negative-private','tls-tmp']:
                (self.root/name).mkdir(mode=0o700)
            self.owner=self.command.CommandOwner(self.stop,self.root/'tls-receipts',self.root/'tls-private')
            self.negative=self.command.CommandOwner(self.stop,self.root/'tls-negative-receipts',self.root/'tls-negative-private')
            account=pwd.getpwuid(self.uid)
            env=dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin',HOME=account.pw_dir,USER=account.pw_name,
                LOGNAME=account.pw_name,TMPDIR=str(self.root/'tls-tmp'),PYTHONDONTWRITEBYTECODE='1')
            self.results['positivePreflight']=self.command.qualify_owner(self.owner,cwd=self.root,env=env)
            self.results['negativePreflight']=self.command.qualify_nonzero_owner(self.negative,cwd=self.root,env=env)
            def run(label,argv):
                self.current();require(time.monotonic()+31<self.end,'daemon_tls_original_budget')
                return self.owner.run(label,[str(x) for x in argv],cwd=self.root,env=env,
                    seconds=min(60,self.end-time.monotonic()-30),stderr_separate=True)
            version=run('tls-openssl-version',[self.args.openssl,'version'])
            raw=bounded_bytes(Path(version['stdout']),1024).decode().strip()
            require(re.fullmatch(r'OpenSSL 3\.[^\n]{1,160}',raw),'daemon_tls_supported_actual_openssl_required')
            self.results['actualOpenSSLVersion']=raw
            target=self.root/'artifact-products'
            cert,key=target/'certificate.pem',target/'private-key.pem'
            require(not os.path.lexists(cert) and not os.path.lexists(key),'daemon_tls_fresh_outputs_required')
            run('tls-create-loopback',[self.args.openssl,'req','-x509','-newkey','rsa:3072','-noenc','-sha256',
                '-days','1','-subj','/CN=lattice-disposable-daemon-loopback','-keyout',key,'-out',cert,
                '-addext','basicConstraints=critical,CA:TRUE,pathlen:0',
                '-addext','keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign,cRLSign',
                '-addext','extendedKeyUsage=serverAuth',
                '-addext','subjectAltName=DNS:localhost,IP:127.0.0.1'])
            first=key.lstat()
            require(key.resolve(strict=True)==key and stat.S_ISREG(first.st_mode) and first.st_nlink==1
                and first.st_uid==self.uid and stat.S_IMODE(first.st_mode)==0o600
                and 0<first.st_size<=65536,'daemon_tls_private_key_custody')
            cert_public=run('tls-certificate-public',[self.args.openssl,'x509','-in',cert,'-pubkey','-noout'])
            key_public=run('tls-key-public',[self.args.openssl,'pkey','-in',key,'-pubout'])
            require(bounded_bytes(Path(cert_public['stdout']),16384)==bounded_bytes(Path(key_public['stdout']),16384)
                and identity(first)==identity(key.lstat()),'daemon_tls_actual_key_pair_required')
            run('tls-validity',[self.args.openssl,'x509','-in',cert,'-checkend','12600','-noout'])
            run('tls-loopback-verify',[self.args.openssl,'verify','-CAfile',cert,'-purpose','sslserver',
                '-verify_ip','127.0.0.1',cert])
            require(identity(first)==identity(key.lstat()),'daemon_tls_key_changed')
            self.results['certificate']=self.command.file_fact(cert,65536)
            # No private key bytes/hash are exported. The provider reads this actual0600 input later.
            self.results['privateKey']=dict(path=str(key),bytes=first.st_size,mode=stat.S_IMODE(first.st_mode),
                device=first.st_dev,inode=first.st_ino,uid=first.st_uid,nlink=first.st_nlink)
            self.current();self.results['preparationSucceeded']=True
        except BaseException as failure:
            error=failure;self.results['primaryFailure']='daemon_tls_input_failed'
            self.results['primaryException']=self.command.exception_fact(failure)
        finally:
            self.results['commands']=[] if self.owner is None else [x.row for x in self.owner.owners]
            self.results['negativeCommands']=[] if self.negative is None else [x.row for x in self.negative.owners]
            try:self.stop.restore()
            except BaseException as failure:
                if error is None:
                    error=failure;self.results['primaryFailure']='daemon_tls_restore_failed'
                    self.results['primaryException']=self.command.exception_fact(failure)
                self.results['preparationSucceeded']=False
            if self.old_umask is not None:os.umask(self.old_umask)
        try:receipt=exclusive_receipt(self.root/'TLS-INPUT.json',self.results)
        except BaseException as receipt_failure:
            if error is not None:raise error from receipt_failure
            raise
        if error is not None:raise error
        self.current()
        require(self.results['preparationSucceeded'],'daemon_tls_input_unqualified')
        return receipt


def main():
    global _HELD
    began=time.monotonic()
    parser=argparse.ArgumentParser(allow_abbrev=False)
    for name in ['graph','graph-pins','required','metadata','archive','root','github-env','openssl']:
        parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    require(sys.platform=='darwin' and platform.machine()=='arm64' and os.getuid()==os.geteuid()>0
        and int(platform.mac_ver()[0].split('.')[0])>=26
        and os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
        and os.environ.get('GITHUB_EVENT_NAME')=='workflow_dispatch' and os.environ.get('GITHUB_RUN_ATTEMPT')=='1'
        and os.environ.get('GITHUB_REPOSITORY')=='jsflax/Engram'
        and os.environ.get('GITHUB_SHA')==os.environ.get('ENGRAM_WORKFLOW_SHA')
        and re.fullmatch('[0-9a-f]{40}',os.environ.get('GITHUB_SHA','')),'daemon_input_actual_first_hosted_dispatch')
    args.graph=args.graph.absolute();args.root=args.root.absolute()
    base=Path(pwd.getpwuid(os.geteuid()).pw_dir)/'localdev'
    require(base.resolve(strict=True)==base and args.graph.resolve(strict=True)==args.graph
        and args.graph.is_relative_to(base) and args.root.parent.resolve(strict=True)==args.root.parent
        and args.root.parent.is_relative_to(base) and not os.path.lexists(args.root),'daemon_input_fresh_localdev_root')
    parent=args.root.parent.lstat()
    require(stat.S_ISDIR(parent.st_mode) and parent.st_uid==os.geteuid()
        and stat.S_IMODE(parent.st_mode)==0o700,'daemon_input_private_parent')
    args.openssl=args.openssl.absolute()
    require(args.openssl.resolve(strict=True)==args.openssl and stat.S_ISREG(args.openssl.lstat().st_mode)
        and args.openssl.lstat().st_mode&0o111 and not args.openssl.lstat().st_mode&0o022,'daemon_tls_actual_openssl')
    seal_raw=bounded_bytes(args.graph_pins,16*1024**2)
    require(hashlib.sha256(seal_raw).hexdigest()==GRAPH_SHA256
        and hashlib.sha256(bounded_bytes(args.required,16*1024**2)).hexdigest()==REQUIRED_SHA256,'daemon_input_exact_source_required')
    seal=json.loads(seal_raw,object_pairs_hook=unique);rows={r['path']:r for r in seal['files']}
    suppliers=[('Engram/scripts/prepare_hosted_owner_inputs.py',SCANNER_SHA256),
        ('Core/Tools/LatticeManagedTargetReclamationFixture/HostedCustody/scripts/managed_startup_command_owner.py',COMMAND_SHA256),
        ('Core/Tools/LatticeManagedTargetReclamationFixture/HostedCustody/scripts/managed_startup_exec_gate.py',GATE_SHA256)]
    for name,pin in suppliers:
        raw=bounded_bytes(args.graph/name,1024**2)
        require(rows[name]['sha256']==pin and rows[name]['bytes']==len(raw)
            and hashlib.sha256(raw).hexdigest()==pin,'daemon_input_supplier_changed')
    scanner=load_source(args.graph/suppliers[0][0],SCANNER_SHA256,'owned_daemon_input_scanner')
    metadata_raw=bounded_bytes(args.metadata,1024**2)
    validate_metadata(json.loads(metadata_raw,object_pairs_hook=unique))
    archive=args.archive.absolute();first=archive.lstat()
    require(archive.resolve(strict=True)==archive and archive.is_relative_to(base) and stat.S_ISREG(first.st_mode)
        and first.st_nlink==1 and first.st_size==ARCHIVE_BYTES,'daemon_original_provider_archive')
    scanner.extract(archive,ARCHIVE_SHA256,args.root)
    facts=[]
    for name,count,digest in FACTS:
        f=args.root/name
        require(f.resolve(strict=True)==f and f.lstat().st_size==count and scanner.sha_file(f,count)==digest,
            'daemon_original_provider_stage_changed')
        facts.append(dict(path=name,bytes=count,sha256=digest))
    build=scanner.bounded_json(args.root/'artifact-products/BUILD.json',16*1024**2)
    scope=scanner.bounded_json(args.root/'artifact-products/BUILD-ONLY.json',16*1024**2)
    require(scope['graphSealSHA256']==build['inputSourceGraphSealSHA256']==ORIGINAL_GRAPH
        and scope['buildOnly'] is True and scope['kind']=='provider-history'
        and scope['providerTLSQualified'] is False and scope['ownerRuntimeQualified'] is False
        and scope['legacySemanticProfileQualified'] is False
        and build['buildSucceeded'] is True and build['primaryFailure'] is None and build['cleanupFailures']==[]
        and build['executableSHA256']==EXECUTABLE_SHA256 and build['executableBytes']==EXECUTABLE_BYTES,
        'daemon_original_build_only_provider')
    image=args.root/'artifact-products/executable';actual=image.lstat()
    require(stat.S_ISREG(actual.st_mode) and actual.st_nlink==1 and actual.st_mode&0o111
        and not actual.st_mode&0o022,'daemon_original_provider_image_mode')
    require(identity(first)==identity(archive.lstat()) and bounded_bytes(args.metadata,1024**2)==metadata_raw,
        'daemon_original_provider_transport_changed')
    root_stat=args.root.lstat()
    require(stat.S_ISDIR(root_stat.st_mode) and root_stat.st_uid==os.geteuid()
        and stat.S_IMODE(root_stat.st_mode)==0o700,'daemon_input_actual_created_root')
    exclusive_receipt(args.root/'PROVIDER-INPUT.json',dict(schema='lattice-original-daemon-provider-input/1',
        artifactID=ARTIFACT_ID,producerRunID=PRODUCER_RUN_ID,originalProducerHead=PRODUCER_HEAD,
        archive=dict(bytes=ARCHIVE_BYTES,sha256=ARCHIVE_SHA256),originalBuildGraph=ORIGINAL_GRAPH,
        selectedSourceGraph=GRAPH_SHA256,selectedRequired=REQUIRED_SHA256,facts=facts,
        rootIdentity=dict(device=root_stat.st_dev,inode=root_stat.st_ino,uid=root_stat.st_uid,
            gid=root_stat.st_gid,mode=stat.S_IMODE(root_stat.st_mode)),transportedBytesOnly=True,
        providerTLSRuntimeQualified=False,nativeAuthority=False,legacySemanticProfileQualified=False))
    command=load_source(args.graph/suppliers[1][0],COMMAND_SHA256,'owned_daemon_tls_command_owner')
    require(_HELD is None,'daemon_input_first_owner')
    held=TLSInputs(args,command,began);_HELD=held  # Retain BEFORE signal/command/key-generation effects.
    tls=held.run()
    held.current()
    value=str(args.root/'artifact-products')
    require(re.fullmatch(r'[A-Za-z0-9_./-]+',value),'daemon_input_env_encoding')
    with args.github_env.open('a') as env:env.write('OWNER_DAEMON_PROVIDER_INPUT='+value+'\n')
    held.current()
    print(json.dumps(dict(providerInput=value,tlsReceipt=tls,nativeAuthority=False,
        providerTLSRuntimeQualified=False,legacySemanticProfileQualified=False),sort_keys=True))


if __name__=='__main__':main()
