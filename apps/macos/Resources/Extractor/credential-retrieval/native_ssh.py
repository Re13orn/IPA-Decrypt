"""Transfer and run the device credential retriever over USB SSH."""

from __future__ import annotations

from ssh_options import command as ssh_command, elevate, su_run

import atexit
import os
import re
import secrets
import shlex
import socket
import subprocess
import time
import sys
from pathlib import Path


class SSHDevice:
    def __init__(self, port: int, udid: str):
        if not 1 <= port <= 65535:
            raise ValueError("SSH port is out of range")
        self.tunnel = None
        try:
            if not os.environ.get("IPA_DIRECT_SSH"):
                with socket.create_connection(("127.0.0.1", port), timeout=1):
                    pass
        except OSError:
            self.tunnel = subprocess.Popen(
                ["iproxy", "-u", udid, f"{port}:22"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            atexit.register(self.close)
            for _ in range(30):
                if self.tunnel.poll() is not None:
                    raise RuntimeError("USB SSH tunnel exited before opening")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=1):
                        break
                except OSError:
                    time.sleep(0.1)
            else:
                raise RuntimeError("USB SSH tunnel did not open")
        self.command = ssh_command(os.environ.get("IPA_SSH_HOST", "127.0.0.1"), port,
                                   os.environ.get("IPA_SSH_ALIAS", udid))
        temporary = (
            self.run("if command -v jbroot >/dev/null 2>&1; then jbroot /var/tmp; fi")
            .decode("utf-8")
            .strip()
        )
        self.ps = "/rootfs/bin/ps" if temporary else "ps"
        if temporary and not temporary.startswith("/"):
            self.close()
            raise RuntimeError("jbroot returned a non-absolute temporary directory")
        # Native programs do not use the bootstrap shell's virtual filesystem.
        temporary = temporary or "/var/tmp"
        self.directory = temporary + "/fp-retrieve-" + secrets.token_hex(8)
        self.trigger_directory = temporary + "/fp-trigger-" + secrets.token_hex(8)
        self.run("umask 077; mkdir " + shlex.quote(self.directory))
        self.run("mkdir -m 755 " + shlex.quote(self.trigger_directory))

    def run(self, command: str, data: bytes | None = None) -> bytes:
        if os.environ.get('IPA_SUDO_MODE') == 'su':
            result = su_run(self.command, command, data)
        else:
            command, data = elevate(command, data)
            result = subprocess.run(
                self.command + [command], input=data, capture_output=True,
                timeout=120, check=False,
            )
        if result.returncode:
            message = (result.stdout + result.stderr).decode("utf-8", "replace")
            raise RuntimeError(
                f"device command failed ({result.returncode}): {message}"
            )
        return result.stdout

    def popen(self, command, **kwargs):
        if os.environ.get('IPA_SUDO_MODE') == 'su':
            return subprocess.Popen([sys.executable, str(Path(__file__).with_name('su_stream.py'))] + self.command + [command], **kwargs)
        command, payload = elevate(command)
        if payload is not None:
            kwargs['stdin'] = subprocess.PIPE
        process = subprocess.Popen(self.command + [command], **kwargs)
        if payload is not None:
            process.stdin.write(payload); process.stdin.flush(); process.stdin.close(); process.stdin = None
        return process

    def processes(self) -> bytes:
        return self.run(shlex.quote(self.ps) + " -e -o pid,comm")

    def path(self, name: str) -> str:
        if not re.fullmatch(r"[a-zA-Z0-9_.-]+", name):
            raise ValueError("invalid remote filename")
        return self.directory + "/" + name

    def write(self, name: str, source: bytes | Path, executable: bool = False) -> str:
        path = self.path(name)
        data = source.read_bytes() if isinstance(source, Path) else source
        self.run("umask 077; cat > " + shlex.quote(path), data)
        if executable:
            self.run("chmod 700 " + shlex.quote(path))
        return path

    def read(self, path: str) -> bytes:
        return self.run("cat " + shlex.quote(path))

    def cleanup(self) -> None:
        try:
            self.run(
                "rm -r -- "
                + shlex.quote(self.directory)
                + " "
                + shlex.quote(self.trigger_directory)
            )
        finally:
            self.close()

    def close(self) -> None:
        if self.tunnel is not None and self.tunnel.poll() is None:
            self.tunnel.terminate()
            self.tunnel.wait(timeout=3)
