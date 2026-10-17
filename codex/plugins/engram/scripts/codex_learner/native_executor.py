"""Bounded native-only adapter. No provider or legacy tool fallback.

Reuses production transport/fence validation, strict scope decoder and owned-child
cleanup. A supplied transport must exactly match the manifest's sealed route.
No installed process is selected implicitly. Test callers use disposable children.
"""
import copy
import os
import selectors
import signal
import threading
import subprocess
import time
from . import operation_probe as P, execution_manifest as J


def executor(driver, transport, *, limits=None):
    frozen=copy.deepcopy(transport)
    limits=limits or P.ProbeLimits()
    sealed=J._json(J._unseal(driver.manifest['inputs']['backend_route']))
    if J.encode(sealed.get('transport')) != J.encode(frozen):
        raise ValueError('residual_transport_changed')
    def execute(raw, writer, check):
        request=J._json(raw,J.MAX_INPUT)
        operation=request['operationID']
        J._request(raw,driver.manifest,operation)
        check('before_native_launch')
        argv,env,cwd,pass_fds=P.bridge._fenced_transport(frozen,writer)
        selector=selectors.DefaultSelector(); child=None; buffer=bytearray(); total=0
        deadline=time.monotonic()+limits.deadline_seconds
        interrupted=False; old_signals={}
        def interrupt(_signal,_frame):
            nonlocal interrupted
            interrupted=True
        def remaining():
            if interrupted: raise P.ProbeError("residual_native_interrupted")
            value=deadline-time.monotonic()
            if value<=0: raise P.ProbeError('residual_native_deadline')
            return value
        def send(value):
            payload=J.encode(value)+b'\n'
            if len(payload)>limits.max_frame_bytes: raise P.ProbeError('residual_frame_limit')
            while payload:
                remaining()
                try: n=os.write(child.stdin.fileno(),payload)
                except BlockingIOError:
                    write_selector=selectors.DefaultSelector()
                    try:
                        write_selector.register(child.stdin,selectors.EVENT_WRITE)
                        if not write_selector.select(remaining()): remaining()
                    finally: write_selector.close()
                    continue
                if n<=0: raise P.ProbeError('residual_short_write')
                payload=payload[n:]
        def receive(identifier):
            nonlocal total
            while b'\n' not in buffer:
                if not selector.select(remaining()): remaining()
                chunk=os.read(child.stdout.fileno(),min(65536,limits.max_frame_bytes+1))
                if not chunk: raise P.ProbeError('residual_native_eof')
                total+=len(chunk);buffer.extend(chunk)
                if total>limits.max_output_bytes or len(buffer)>limits.max_frame_bytes:
                    raise P.ProbeError('residual_output_limit')
            line,_,tail=buffer.partition(b'\n');buffer[:]=tail
            if buffer: raise P.ProbeError('residual_unsolicited_frame')
            value=J._json(bytes(line),limits.max_frame_bytes)
            if type(value) is not dict or set(value)!={'jsonrpc','id','result'} or value['jsonrpc']!='2.0' or type(value['id']) is not type(identifier) or value['id']!=identifier:
                raise P.ProbeError('residual_invalid_response')
            return value
        try:
            if threading.current_thread() is threading.main_thread():
                for sig in (signal.SIGTERM,signal.SIGINT): old_signals[sig]=signal.signal(sig,interrupt)
            remaining()
            child=subprocess.Popen(argv,stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,env=env,cwd=cwd,pass_fds=pass_fds,start_new_session=True,bufsize=0)
            os.set_blocking(child.stdin.fileno(),False);os.set_blocking(child.stdout.fileno(),False)
            selector.register(child.stdout,selectors.EVENT_READ)
            send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':P.PROTOCOL_VERSION,
                'capabilities':{},'clientInfo':{'name':'engram-reviewed-residual','version':'1'}}})
            P._initialize(receive(1)['result'])
            send({'jsonrpc':'2.0','method':'notifications/initialized'})
            send({'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'operation_scope','arguments':{}}})
            scope=P._scope_result(receive(2)['result'])
            if J._scope(scope)!=J._scope(request['expectedScope']): raise P.ProbeError('residual_scope_changed')
            check('before_native_forward')
            # Parsing the canonical retained raw preserves exact key/byte order.
            if J.encode(request)!=raw: raise P.ProbeError('residual_request_changed')
            send({'jsonrpc':'2.0','id':operation,'method':'tools/call','params':{
                'name':'operation_apply','arguments':request}})
            message=receive(operation)
            # Driver retains the authenticated commit before rechecking mutable
            # dispatch context; a post-commit policy change cannot erase IDs.
        finally:
            try:
                selector.close()
                if child is not None:
                    cleanup=P.bridge._cleanup(child,limits.terminate_timeout_seconds)
                    if not cleanup['child_reaped'] or cleanup['cleanup_failed'] or cleanup['cleanup_overrun']:
                        raise P.ProbeError('residual_cleanup_failed')
            finally:
                for sig,handler in old_signals.items(): signal.signal(sig,handler)
        if interrupted: raise P.ProbeError('residual_native_interrupted')
        writer.verify(writer.binding())
        return message
    return execute


def status_probe(driver, transport, *, limits=None):
    frozen=copy.deepcopy(transport)
    sealed=J._json(J._unseal(driver.manifest['inputs']['backend_route']))
    if J.encode(sealed.get('transport'))!=J.encode(frozen): raise ValueError('residual_transport_changed')
    def probe(requests,original_recovery,check):
        check('before_native_status')
        return P.probe_statuses(frozen,recovery_fence=original_recovery,
            expected_binding=driver.manifest['fencing'],expected_scope=driver.manifest['expected_scope'],
            requests=requests,validate_inputs=check,limits=limits)
    return probe
