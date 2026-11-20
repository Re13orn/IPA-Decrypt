"""One SSH configuration shared by connection tests and extraction."""
import os
import shlex


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
        remote_command = "sudo -k -S -p '' -- /bin/sh -c " + shlex.quote(remote_command)
        data = (env.get('IPA_SSH_PASSWORD', '') + '\n').encode() + (data or b'')
    elif mode == 'nopasswd':
        remote_command = "sudo -n -- /bin/sh -c " + shlex.quote(remote_command)
    return remote_command, data
