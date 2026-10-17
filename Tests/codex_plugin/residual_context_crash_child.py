"""Fresh interpreter for real SIGKILL of isolated residual publication."""
import contextlib
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
from unittest import mock
from residual_context_fixture import ResidualContextFixture, F, SID
from residual_test_support import runtime
RP=runtime('residual_publication')


def main():
    fixture=ResidualContextFixture.from_child_spec(Path(sys.argv[1]))
    action,boundary=sys.argv[2:4]
    def crash(label):
        if label==boundary:os.kill(os.getpid(),signal.SIGKILL)
    RP.boundary=RP.Q._boundary=RP.PJ._boundary=crash
    with contextlib.ExitStack() as guards:
        for module,name in ((subprocess,'Popen'),(subprocess,'run'),(subprocess,'call'),(os,'system'),(socket,'socket')):
            guards.enter_context(mock.patch.object(module,name,side_effect=AssertionError('provider/native/network forbidden')))
        guards.enter_context(fixture.synthetic_probe())
        with fixture.locks() as verify:
            if action=='begin':
                fixture.writer=F.acquire_shared(fixture.run_dir,fixture.binding)
                guards.callback(fixture.writer.close)
                fixture.begin(verify)
            elif action=='recover':
                RP.recover_locked(fixture.paths,session_id=SID,verify_locks=verify)
            else:raise AssertionError('unknown child action')
    raise RuntimeError('requested crash boundary was not reached')


if __name__=='__main__':
    sys.dont_write_bytecode=True
    main()
