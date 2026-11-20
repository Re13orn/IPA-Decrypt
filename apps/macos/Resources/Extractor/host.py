"""Desktop JSON adapter. No credentials or captured key bytes in output."""
import argparse
from contextlib import contextmanager
import ipaddress
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT/'credential-retrieval'))
from ssh_options import command as ssh_command
UDID = re.compile(r'(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{8}-[0-9a-fA-F]{16})')


def run(args, timeout=15):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def validate_host(host):
    if not host or len(host) > 253 or not re.fullmatch(r'[A-Za-z0-9.:%_-]+', host):
        raise RuntimeError('请输入有效 IP 或主机名，不要包含 ssh://、路径或端口。')
    try:
        ipaddress.ip_address(host)
        return host
    except ValueError:
        if len(host) <= 253 and all(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label) for label in host.split('.')):
            return host
    raise RuntimeError('请输入有效 IP 或主机名，不要包含 ssh://、路径或端口。')


def failure(result):
    details = (result.stdout + result.stderr).lower()
    if 'permission denied' in details or 'publickey' in details or 'authentication failed' in details:
        reason = 'SSH 认证失败，请核对用户名、密码或私钥。'
    elif 'host key' in details:
        reason = '设备 SSH 身份与记录不符，请先核对设备身份。'
    elif 'timeoutexpired' in details and 'observe_uid_layer' in details:
        reason = '此 App 未在等待时间内完成许可证捕获。可重试，或用同一来源账户的其他 App 提取。'
    elif 'connection refused' in details or 'connection closed' in details or 'timed out' in details or 'no route to host' in details:
        reason = '无法连接设备 SSH，请核对地址、端口、越狱状态和 SSH 服务。'
    elif 'selected installed license changed' in details:
        reason = '所选设备许可证已变化或不再可用，请重新扫描并选择。'
    elif 'supported' in details or 'installed app' in details or 'license' in details:
        reason = '手机未找到目标账户的受支持 App 许可证。请用该账户安装 App 后重试，或检查目标 IPA。'
    elif 'modulenotfounderror' in details:
        reason = '提取组件缺少依赖，请重新安装此 Mac App。'
    else:
        reason = '设备操作未完成，请检查连接、root SSH 和许可证后重试。'
    classes = re.findall(r'(?m)^([A-Za-z_][A-Za-z0-9_]*(?:Error|Exception)):', result.stderr)
    phases = re.findall(r'in (run|__init__|trigger_app|observe_uid_layer|main|fairplayd_image)\n', result.stderr)
    remote = re.findall(r'device command failed \((\d+)\)', details)
    code = '/'.join((phases[-1:] or ['ssh']) + (classes[-1:] or ['process'])) + ' exit=' + str(result.returncode)
    if remote: code += ' remote=' + remote[-1]
    return reason + '\n诊断：' + code


@contextmanager
def connection(args):
    if not 1 <= args.remote_port <= 65535:
        raise RuntimeError('SSH 端口必须为 1–65535。')
    if not args.known_hosts:
        raise RuntimeError('缺少本机 SSH 主机记录位置。')
    env = dict(os.environ, IPA_KNOWN_HOSTS=str(Path(args.known_hosts).resolve()), SSH_ASKPASS=str(ROOT/'askpass'),
               SSH_ASKPASS_REQUIRE='force', DISPLAY='ipa-desktop:0', PYTHONDONTWRITEBYTECODE='1')
    tunnel = None
    if args.host:
        host = validate_host(args.host.strip())
        port = args.remote_port
        alias = 'lan-' + host.replace(':', '-') + '-port-' + str(args.remote_port)
        env.update(IPA_DIRECT_SSH='1', IPA_SSH_HOST=host, IPA_SSH_ALIAS=alias)
    else:
        if not UDID.fullmatch(args.device): raise RuntimeError('请选择已连接的 USB 设备。')
        host = '127.0.0.1'; alias = args.device + '-port-' + str(args.remote_port)
        with socket.socket() as listener:
            listener.bind((host, 0)); port = listener.getsockname()[1]
        env.pop('IPA_DIRECT_SSH', None)
        env.update(IPA_SSH_HOST=host, IPA_SSH_ALIAS=alias)
        tunnel = subprocess.Popen(['iproxy','-u',args.device,f'{port}:{args.remote_port}'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        if tunnel:
            for _ in range(50):
                if tunnel.poll() is not None: raise RuntimeError('USB SSH 转发失败。')
                try:
                    with socket.create_connection((host,port),timeout=.2): break
                except OSError: time.sleep(.1)
            else: raise RuntimeError('USB SSH 端口未能打开，请检查设备连接。')
        yield host,port,alias,env
    finally:
        if tunnel:
            tunnel.terminate()
            try: tunnel.wait(timeout=3)
            except subprocess.TimeoutExpired: tunnel.kill(); tunnel.wait()


def probe_access(host, port, alias, env):
    command = ssh_command(host, port, alias, env=env)
    result = subprocess.run(command + ['id -u; uname -s; (sw_vers -productVersion 2>/dev/null || true)'], capture_output=True, text=True, env=env, timeout=30)
    if result.returncode: raise RuntimeError(failure(result))
    lines = result.stdout.strip().splitlines()
    if len(lines) < 2 or not lines[0].isdigit() or lines[1] != 'Darwin':
        raise RuntimeError('SSH 已连接，但不是受支持的 iOS 会话。')
    env['IPA_SUDO_MODE'] = 'none'
    if lines[0] != '0':
        check = subprocess.run(command + ["sudo -n -- /bin/sh -c 'id -u'"], capture_output=True, text=True, env=env, timeout=15)
        if check.returncode == 0 and check.stdout.strip() == '0':
            env['IPA_SUDO_MODE'] = 'nopasswd'
        elif env.get('IPA_SSH_PASSWORD'):
            check = subprocess.run(command + ["sudo -k -S -p '' -- /bin/sh -c 'id -u'"], input=env['IPA_SSH_PASSWORD'] + '\n', capture_output=True, text=True, env=env, timeout=15)
            if check.returncode != 0 or check.stdout.strip() != '0':
                raise RuntimeError('SSH 登录成功，但当前账户不能通过 sudo 取得提取权限。请使用有权限的账户。')
            env['IPA_SUDO_MODE'] = 'password'
        else:
            raise RuntimeError('SSH 登录成功，提取还需要 sudo 权限，请填写该账户的 sudo 密码。')
    version = next((line for line in lines[2:] if re.fullmatch(r'\d+(?:\.\d+){1,2}', line)), None)
    return 'SSH 连接成功 · ' + env['IPA_SSH_USER'] + (' · sudo 已验证' if env['IPA_SUDO_MODE'] != 'none' else ' · root 权限已确认') + (' · 系统 ' + version if version else '')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation',choices=['devices','test','extract','auto','inspect','scan','scan-auto','test-auto'])
    parser.add_argument('--device',default='')
    parser.add_argument('--user',default='root')
    parser.add_argument('--host',default='')
    parser.add_argument('--remote-port',type=int,default=22)
    parser.add_argument('--output')
    parser.add_argument('--known-hosts')
    parser.add_argument('--ipa')
    parser.add_argument('--credential-cache')
    parser.add_argument('--license-cache')
    parser.add_argument('--sinf-member')
    parser.add_argument('--installed-sinf')
    parser.add_argument('--expected-sinf-hash')
    args = parser.parse_args()
    if args.operation == 'inspect':
        from license_plan import inspect_ipa
        try: choices = inspect_ipa(args.ipa)
        except (ValueError, OSError, KeyError): raise RuntimeError('目标 IPA 缺少可用许可证，请选择原始加密 IPA。')
        print(json.dumps(dict(licenses=choices), ensure_ascii=False)); return
    if args.operation=='devices':
        result=run(['idevice_id','-l'])
        if result.returncode: raise RuntimeError('无法读取 USB 设备，请确认连接、解锁并信任这台 Mac。')
        devices=[]
        for udid in result.stdout.splitlines():
            if not UDID.fullmatch(udid): continue
            def info(key):
                result=run(['ideviceinfo','-u',udid,'-k',key],8)
                return result.stdout.strip() if result.returncode==0 else ''
            devices.append(dict(id=udid,name=info('DeviceName') or 'iPhone / iPad',version=info('ProductVersion')))
        print(json.dumps(dict(devices=devices),ensure_ascii=False));return
    requested = None
    target = None
    if args.operation in ('extract','auto'):
        from device_catalog import validate_path
        try:
            validate_path(args.installed_sinf or '')
            if not re.fullmatch('[0-9a-f]{64}', args.expected_sinf_hash or ''): raise ValueError('missing fingerprint')
        except ValueError: raise RuntimeError('请先扫描手机并明确选择一条设备许可证。')
        if args.ipa:
            from license_plan import target_license
            try: target, requested = target_license(args.ipa, args.sinf_member)
            except (ValueError, OSError, KeyError): raise RuntimeError('目标许可证无效或存在多个许可证，请明确选择一项。')
        if not args.output or Path(args.output).exists(): raise RuntimeError('提取输出目录必须是新目录。')
    if args.operation not in ('auto','scan-auto','test-auto') and not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_-]{0,31}', args.user):
        raise RuntimeError('请输入有效 SSH 用户名。')
    with connection(args) as (host,port,alias,env):
        env['IPA_SSH_USER'] = args.user
        env.pop('IPA_SUDO_MODE', None)
        if args.operation in ('auto','scan-auto','test-auto'):
            # Only the two pairs explicitly requested by the device owner.
            matched = False
            for user, password in [('root', 'alpine'), ('mobile', '123456')]:
                attempt = dict(env, IPA_SSH_USER=user, IPA_SSH_PASSWORD=password)
                attempt.pop('IPA_SSH_KEY', None)
                try:
                    message = probe_access(host, port, alias, attempt)
                except RuntimeError as error:
                    if 'SSH 认证失败' in str(error):
                        continue
                    # Host identity errors and insufficient sudo are not password
                    # failures; stop rather than cycling through more logins.
                    raise
                env = attempt; matched = True; break
            if not matched:
                raise RuntimeError('两组常见组合均未通过 SSH 认证，请填写自定义用户名和密码后测试。')
        else:
            message = probe_access(host, port, alias, env)
        if args.operation in ('test','test-auto'):
            print(json.dumps(dict(message=message), ensure_ascii=False)); return
        if args.operation in ('scan','scan-auto'):
            scan_command=[sys.executable,str(ROOT/'device_catalog.py'),str(port)]
            if args.credential_cache or args.license_cache: scan_command.append(args.credential_cache or '')
            if args.license_cache: scan_command.append(args.license_cache)
            result=subprocess.run(scan_command,capture_output=True,text=True,env=env,timeout=600)
            if result.returncode: raise RuntimeError('读取设备许可证失败，请检查 SSH 权限并重试。')
            reply=json.loads(result.stdout)
            print(json.dumps(reply,ensure_ascii=False)); return
        command=[sys.executable,str(ROOT/'credential-retrieval/retrieve.py'),'--bundle',str(ROOT/'bundle'),'--ssh-port',str(port),'--output-dir',args.output]
        if not args.host: command+=['--device-udid',args.device]
        command+=['--installed-sinf',args.installed_sinf,'--expected-sinf-hash',args.expected_sinf_hash]
        if args.ipa: command+=['--ipa',args.ipa]
        if args.sinf_member: command+=['--sinf-member',args.sinf_member]
        result=subprocess.run(command,capture_output=True,text=True,env=env,timeout=600)
        if result.returncode: raise RuntimeError(failure(result))
        output=Path(args.output);credential=output/'credential.bin'
        if not credential.is_file() or credential.stat().st_size!=16: raise RuntimeError('设备返回的凭据长度无效，未导入。')
        from core import derive_work16
        try:
            if target is None:
                target=(output/'selected.sinf').read_bytes()
                if hashlib.sha256(target).hexdigest() != args.expected_sinf_hash: raise ValueError('selection changed')
                from retrieve import sinf_field
                requested={'user':sinf_field(target,b'user').hex(),'key':sinf_field(target,b'key ').hex()}
            derive_work16(credential.read_bytes(), target)
            selection = json.loads((output/'selection.json').read_text())
            if selection.get('user') != requested['user'] or selection.get('key') != requested['key'] or selection.get('triggerUser') != requested['user'] or selection.get('installedPath') != args.installed_sinf or selection.get('installedDigest') != args.expected_sinf_hash:
                raise ValueError('target mismatch')
        except (ValueError, KeyError, OSError):
            raise RuntimeError('返回凭据未通过目标许可证校验，未保存到账户。')
        os.chmod(output,0o700);os.chmod(credential,0o600)
        print(json.dumps(dict(path=str(credential), selection=selection, message='已通过 ' + env['IPA_SSH_USER'] + (' + sudo' if env.get('IPA_SUDO_MODE') != 'none' else '') + ' 提取凭据。'), ensure_ascii=False))

if __name__=='__main__':
    try: main()
    except (RuntimeError,subprocess.TimeoutExpired,OSError) as error:
        print(json.dumps(dict(error=str(error) if isinstance(error,RuntimeError) else '设备连接或操作超时，请检查设备后重试。'),ensure_ascii=False));sys.exit(1)
