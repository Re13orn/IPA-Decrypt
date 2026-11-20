"""Rebuild Apple Silicon native libraries from the included patched source."""
from pathlib import Path
import argparse
import shutil
import subprocess
import tarfile
import os

BASE=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--work',type=Path,required=True);a=p.parse_args();w=a.work.resolve();w.mkdir(parents=True,exist_ok=True)
source=BASE/'ThirdPartySource'
def run(*args,**kwargs): subprocess.run([str(x) for x in args],check=True,**kwargs)
jsonconfig=w/'json-package';jsonconfig.mkdir(exist_ok=True)
(jsonconfig/'nlohmann_jsonConfig.cmake').write_text('add_library(nlohmann_json::nlohmann_json INTERFACE IMPORTED)\nset_target_properties(nlohmann_json::nlohmann_json PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "'+str(source/'nlohmann_json/single_include')+'")\n')
(jsonconfig/'nlohmann_jsonConfigVersion.cmake').write_text('set(PACKAGE_VERSION "3.12.0")\nset(PACKAGE_VERSION_COMPATIBLE TRUE)\n')
flags=['-G' ,'Ninja','-DCMAKE_BUILD_TYPE=Release','-DBUILD_SHARED_LIBS=OFF','-DCMAKE_OSX_ARCHITECTURES=arm64','-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0']
mb=w/'mbedtls-3.6.5'
if not mb.exists():
    with tarfile.open(source/'mbedtls-3.6.5.tar.bz2') as t: t.extractall(w,filter='data')
run('cmake','-S',mb,'-B',w/'mbedtls',*flags,'-DENABLE_TESTING=OFF','-DENABLE_PROGRAMS=OFF','-DUSE_SHARED_MBEDTLS_LIBRARY=OFF',f'-DCMAKE_INSTALL_PREFIX={w}/mb-install')
run('cmake','--build',w/'mbedtls','--target','install','-j6')
run('cmake','-S',source/'libzip','-B',w/'libzip',*flags,'-DENABLE_COMMONCRYPTO=OFF','-DENABLE_GNUTLS=OFF','-DENABLE_MBEDTLS=OFF','-DENABLE_OPENSSL=OFF','-DENABLE_BZIP2=OFF','-DENABLE_LZMA=OFF','-DENABLE_ZSTD=OFF','-DBUILD_TOOLS=OFF','-DBUILD_REGRESS=OFF','-DBUILD_EXAMPLES=OFF','-DBUILD_DOC=OFF',f'-DCMAKE_INSTALL_PREFIX={w}/zip-install')
run('cmake','--build',w/'libzip','--target','install','-j6')
run('cmake','-S',source/'AppleAuth','-B',w/'auth',*flags,'-DAPPLE_AUTH_WITH_CLIENT=ON','-DAPPLE_AUTH_WITH_CURL=OFF','-DAPPLE_AUTH_WITH_TESTFLIGHT=ON','-DAPPLE_AUTH_BUILD_EXAMPLES=OFF',f'-DFETCHCONTENT_SOURCE_DIR_LZFSE={source}/lzfse',f'-DCMAKE_PREFIX_PATH={w}/mb-install;{w}/zip-install;{jsonconfig}')
run('cmake','--build',w/'auth','-j6')
archives=[w/'auth/libapple_auth.a',w/'auth/libapple_auth_client.a',w/'auth/_deps/lzfse-build/liblzfse.a',w/'zip-install/lib/libzip.a']+list((w/'mb-install/lib').glob('*.a'))
run('xcrun','libtool','-static','-o',w/'libapple_auth.a',*archives)
headers=w/'headers';shutil.copytree(source/'AppleAuth/include',headers,dirs_exist_ok=True);shutil.copytree(w/'auth/include',headers,dirs_exist_ok=True)
(headers/'module.modulemap').write_text('module apple_auth { header "apple_auth/client_c_api.h" export * }\n')
artifact=w/'apple_auth.xcframework'
if artifact.exists(): shutil.rmtree(artifact)
run('xcodebuild','-create-xcframework','-library',w/'libapple_auth.a','-headers',headers,'-output',artifact)
target=BASE/'Vendor/AppleAuth/Artifacts/apple_auth.xcframework'
if target.exists(): shutil.rmtree(target)
shutil.copytree(artifact,target)
env=dict(os.environ,MACOSX_DEPLOYMENT_TARGET='26.0',CGO_CFLAGS='-mmacosx-version-min=26.0',CGO_LDFLAGS='-mmacosx-version-min=26.0',CGO_ENABLED='1',GOOS='darwin',GOARCH='arm64')
run('go','build','-trimpath','-ldflags=-s -w','-buildmode=c-archive','-o',BASE/'Vendor/libipatool.a','./ipalabbridge',cwd=source/'ipatool',env=env)
print('Native libraries rebuilt')
