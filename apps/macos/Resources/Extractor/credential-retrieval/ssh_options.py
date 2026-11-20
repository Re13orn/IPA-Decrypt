"""One SSH configuration shared by connection tests and extraction."""
import os
import shlex

BOOTSTRAP_PATH = 'export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin; '


def command(host, port, alias, env=None):
    env = os.environ if env is None else env
    known = env['IPA_KNOWN_HOSTS'].replace('\\', '\\\\').replace('"', '\\"')
    args = ['/usr/bin/ssh', '-T', '-o', 'BatchMode=no' if env.get('IPA_SSH_PASSWORD') else 'BatchMode=yes',
            '-o', 'StrictHostKeyChecking=accept-new', '-o', f'UserKnownHostsFile="{known}"',
            '-o', 'HostKeyAlias=ipa-device-' + alias, '-o', 'ConnectTimeout=8',
            '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2', '-p', str(port)]
    if env.get('IPA_SSH_PASSWORD') and not env.get('IPA_SSH_KEY'):
        args += ['-o', 'PreferredAuthentications=password,keyboard-interactive', '-o', 'PubkeyAuthentication=no', '-o', 'NumberOfPasswordPrompts=1']
    if env.get('IPA_SSH_KEY'):
        args += ['-i', env['IPA_SSH_KEY'], '-o', 'IdentitiesOnly=yes']
    return args + [env.get('IPA_SSH_USER', 'root') + '@' + host]


def elevate(remote_command, data=None, env=None):
    env = os.environ if env is None else env
    mode = env.get('IPA_SUDO_MODE', 'none')
    if mode == 'password':
        # -k forces sudo to consume the password even if a timestamp exists;
        # otherwise that password line could become part of a binary upload.
        remote_command = "sudo -k -S -p '' -- sh -c " + shlex.quote(remote_command)
        data = (env.get('IPA_SSH_PASSWORD', '') + '\n').encode() + (data or b'')
    elif mode == 'nopasswd':
        remote_command = "sudo -n -- sh -c " + shlex.quote(remote_command)
    return BOOTSTRAP_PATH + remote_command, data


# su authenticates through a remote terminal. Binary transfers stay on ordinary
# SSH channels; only su authentication and observer status use the PTY.
def su_start(ssh, remote_command, env=None, timeout=15):
    import secrets
    import re
    import select
    import subprocess
    import time
    env = os.environ if env is None else env
    password = env.get('IPA_ROOT_PASSWORD') or env.get('IPA_SSH_PASSWORD', '')
    if any(ord(c) < 32 or ord(c) == 127 for c in password):
        raise RuntimeError('su 提权密码不能包含控制字符。')
    marker = ('IPA_SU_READY_' + secrets.token_hex(16)).encode()
    root = "export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin; [ \"$(id -u)\" = 0 ] || exit 77; stty -echo -onlcr || exit 78; printf '\\n%s\\n' " + shlex.quote(marker.decode()) + '; exec sh -c ' + shlex.quote(remote_command)
    wrapper = "export LC_ALL=C PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin; stty -echo || exit 78; exec su -s \"$(command -v sh)\" root -c " + shlex.quote(root)
    args = list(ssh)
    if '-T' in args: args[args.index('-T')] = '-tt'
    else: args.insert(1, '-tt')
    process = subprocess.Popen(args + [wrapper], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    pending = b''; sent = False; deadline = time.monotonic() + timeout
    streams = [process.stdout, process.stderr]
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select(streams, [], [], .1)
            for stream in ready:
                chunk = os.read(stream.fileno(), 8192)
                if not chunk:
                    streams.remove(stream); continue
                if stream is process.stderr: continue  # SSH diagnostics never contain model data.
                pending += chunk
                if len(pending) > 65536: raise RuntimeError('su 返回的数据过大。')
                if marker + b'\n' in pending:
                    remainder = pending.split(marker + b'\n', 1)[1]
                    process.stdin.close(); process.stdin = None
                    return process, remainder
                if not sent and re.search(rb'password[^\r\n]{0,80}:', pending, re.I):
                    if not password: raise RuntimeError('su 需要 root 密码，请填写提权密码。')
                    process.stdin.write((password + '\n').encode()); process.stdin.flush(); sent = True
            if process.poll() is not None and not streams:
                break
        raise RuntimeError('su 未能取得 root 权限，请核对 root 密码及设备是否支持 su。')
    except BaseException:
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=2)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        for stream in [process.stdin, process.stdout, process.stderr]:
            if stream: stream.close()
        raise


def su_run(ssh, remote_command, data=None, env=None, timeout=120):
    import secrets
    import subprocess
    env = os.environ if env is None else env
    directory = '/var/tmp/ipa-su-' + secrets.token_hex(16)
    q = shlex.quote
    def plain(command, payload=None):
        return subprocess.run(ssh + [command], input=payload, capture_output=True, env=env, timeout=timeout)
    created = False
    try:
        made = plain('umask 077; mkdir ' + q(directory))
        if made.returncode: raise RuntimeError('无法建立 su 的私有传输目录。')
        created = True
        setup = plain('umask 077; { cat > ' + q(directory+'/input') + '; : > ' + q(directory+'/stdout') + '; : > ' + q(directory+'/stderr') + '; }', data or b'')
        if setup.returncode: raise RuntimeError('无法建立 su 的私有传输目录。')
        created = True
        command = 'sh -c ' + q(remote_command) + ' < ' + q(directory+'/input') + ' > ' + q(directory+'/stdout') + ' 2> ' + q(directory+'/stderr')
        process, _ = su_start(ssh, command, env=env)
        try:
            process.communicate(timeout=timeout)
        except BaseException:
            process.kill(); process.communicate(); raise
        output, errors = plain('cat ' + q(directory+'/stdout')), plain('cat ' + q(directory+'/stderr'))
        if output.returncode or errors.returncode: raise RuntimeError('无法读取 su 命令结果。')
        return subprocess.CompletedProcess(ssh, process.returncode, output.stdout, errors.stdout)
    finally:
        if created:
            plain('rm -rf -- ' + q(directory))
