"""Live su status bridge. Never transports binary payloads through a terminal."""
import os
import subprocess
import sys
import signal
from ssh_options import su_start


def main():
    def stopped(signum, frame): raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, stopped); signal.signal(signal.SIGINT, stopped)
    process, pending = su_start(sys.argv[1:-1], sys.argv[-1])
    # Observer/trigger commands expose only status on this channel. Credential
    # bytes are written on-device and read by SSHDevice.run over non-PTY SSH.
    if pending: sys.stderr.buffer.write(pending); sys.stderr.buffer.flush()
    try:
        while True:
            block = os.read(process.stdout.fileno(), 8192)
            if not block: break
            sys.stderr.buffer.write(block); sys.stderr.buffer.flush()
        _, diagnostics = process.communicate()
        if diagnostics: sys.stderr.buffer.write(diagnostics)
        return process.returncode
    except BaseException:
        process.kill(); process.communicate(); raise

if __name__ == '__main__':
    try: sys.exit(main())
    except (RuntimeError, OSError, subprocess.TimeoutExpired):
        sys.stderr.write('su 提权或连接失败，请核对 root 密码。\n'); sys.exit(1)
