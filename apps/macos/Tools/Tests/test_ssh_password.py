"""Real local SSH handshake with a synthetic password; no user device contacted."""
from pathlib import Path
import importlib.util
import os
import socket
import subprocess
import tempfile
import threading
import paramiko

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('ssh_options',ROOT/'Resources/Extractor/credential-retrieval/ssh_options.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class Server(paramiko.ServerInterface):
    def __init__(self): self.executed=threading.Event();self.authenticated=False
    def get_allowed_auths(self,user): return 'password'
    def check_auth_password(self,user,password):
        self.authenticated=user=='root' and password=='synthetic-ssh-fixture'
        return paramiko.AUTH_SUCCESSFUL if self.authenticated else paramiko.AUTH_FAILED
    def check_channel_request(self,kind,chanid): return paramiko.OPEN_SUCCEEDED
    def check_channel_exec_request(self,channel,command): self.executed.set();return True
server=Server();key=paramiko.RSAKey.generate(2048)
with socket.socket() as listener, tempfile.TemporaryDirectory(prefix='ipa ssh test ') as temp:
    listener.bind(('127.0.0.1',0));listener.listen();port=listener.getsockname()[1]
    def serve():
        peer,_=listener.accept();transport=paramiko.Transport(peer);transport.add_server_key(key);transport.start_server(server=server)
        channel=transport.accept(15)
        if channel and server.executed.wait(15):
            channel.sendall(b'0\nDarwin\n16.7.11\n');channel.send_exit_status(0);channel.close()
        transport.close()
    worker=threading.Thread(target=serve,daemon=True);worker.start()
    env=dict(os.environ,IPA_SSH_PASSWORD='synthetic-ssh-fixture',IPA_KNOWN_HOSTS=str(Path(temp)/'known hosts'),SSH_ASKPASS=str((ROOT/'Resources/Extractor/askpass').resolve()),SSH_ASKPASS_REQUIRE='force',DISPLAY='ipa-test:0')
    command=module.command('127.0.0.1',port,'synthetic-test',env=env)
    result=subprocess.run(command+['id -u; uname -s'],env=env,capture_output=True,text=True,timeout=25)
    worker.join(5)
    assert result.returncode==0 and result.stdout.startswith('0\nDarwin\n') and server.authenticated, 'Synthetic SSH password flow failed'
print('PASS real OpenSSH handshake: forced askpass, password-only auth and known-host path with spaces')
