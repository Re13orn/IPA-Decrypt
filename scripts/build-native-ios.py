#!/usr/bin/env python3
"""Rebuild iOS device/simulator libraries from the same locked source snapshots as Mac."""
import argparse,os,shutil,subprocess,sys,tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'apps/ios';SOURCE=ROOT/'apps/macos/ThirdPartySource'
def run(*args,**kw):subprocess.run([str(x) for x in args],check=True,**kw)
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--work',type=Path,required=True);a=p.parse_args();w=a.work.resolve();w.mkdir(parents=True,exist_ok=True)
 run(sys.executable,ROOT/'scripts/verify-dependencies.py')
 mb=w/'mbedtls-3.6.5'
 if not mb.exists():
  with tarfile.open(SOURCE/'mbedtls-3.6.5.tar.bz2') as t:t.extractall(w,filter='data')
 jsonconfig=w/'json-package';jsonconfig.mkdir(exist_ok=True)
 (jsonconfig/'nlohmann_jsonConfig.cmake').write_text('add_library(nlohmann_json::nlohmann_json INTERFACE IMPORTED)\nset_target_properties(nlohmann_json::nlohmann_json PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "'+str(SOURCE/'nlohmann_json/single_include')+'")\n')
 (jsonconfig/'nlohmann_jsonConfigVersion.cmake').write_text('set(PACKAGE_VERSION "3.12.0")\nset(PACKAGE_VERSION_COMPATIBLE TRUE)\n')
 go=w/'ipatool'
 if go.exists():raise SystemExit('Use a fresh work directory; never mutate a previous Go source copy')
 shutil.copytree(SOURCE/'ipatool',go,ignore=shutil.ignore_patterns('.git','*.a','__pycache__'))
 shutil.copyfile(BASE/'Tools/ipatool/main.go',go/'ipalabbridge/main.go')
 with tarfile.open(BASE/'Tools/ipatool/unicorn/unicorn-2.1.4.tgz') as t:t.extractall(w,filter='data')
 unicorn=w/'unicorn-2.1.4';run('patch','-p1','-i',BASE/'Tools/ipatool/unicorn/unicorn-ios.patch',cwd=unicorn)
 auth_options=[];go_options=[]
 for sdk,target in [('iphoneos','arm64-apple-ios16.0'),('iphonesimulator','arm64-apple-ios16.0-simulator')]:
  dest=w/sdk;dest.mkdir(exist_ok=True)
  flags=['-G','Ninja','-DCMAKE_SYSTEM_NAME=iOS',f'-DCMAKE_OSX_SYSROOT={sdk}','-DCMAKE_OSX_ARCHITECTURES=arm64','-DCMAKE_OSX_DEPLOYMENT_TARGET=16.0','-DCMAKE_BUILD_TYPE=Release','-DBUILD_SHARED_LIBS=OFF']
  run('cmake','-S',mb,'-B',dest/'mb',*flags,'-DENABLE_TESTING=OFF','-DENABLE_PROGRAMS=OFF','-DUSE_SHARED_MBEDTLS_LIBRARY=OFF',f'-DCMAKE_INSTALL_PREFIX={dest}/mb-install')
  run('cmake','--build',dest/'mb','--target','install','-j6')
  run('cmake','-S',SOURCE/'libzip','-B',dest/'zip',*flags,'-DENABLE_COMMONCRYPTO=OFF','-DENABLE_GNUTLS=OFF','-DENABLE_MBEDTLS=OFF','-DENABLE_OPENSSL=OFF','-DENABLE_BZIP2=OFF','-DENABLE_LZMA=OFF','-DENABLE_ZSTD=OFF','-DBUILD_TOOLS=OFF','-DBUILD_REGRESS=OFF','-DBUILD_EXAMPLES=OFF','-DBUILD_DOC=OFF',f'-DCMAKE_INSTALL_PREFIX={dest}/zip-install')
  run('cmake','--build',dest/'zip','--target','install','-j6')
  prefix=f'{dest}/mb-install;{dest}/zip-install;{jsonconfig}'
  run('cmake','-S',SOURCE/'AppleAuth','-B',dest/'auth',*flags,'-DAPPLE_AUTH_WITH_CLIENT=ON','-DAPPLE_AUTH_WITH_CURL=OFF','-DAPPLE_AUTH_WITH_TESTFLIGHT=ON','-DAPPLE_AUTH_BUILD_EXAMPLES=OFF',f'-DFETCHCONTENT_SOURCE_DIR_LZFSE={SOURCE}/lzfse',f'-DCMAKE_PREFIX_PATH={prefix}',f'-DCMAKE_FIND_ROOT_PATH={prefix}')
  run('cmake','--build',dest/'auth','-j6')
  archives=[dest/'auth/libapple_auth.a',dest/'auth/libapple_auth_client.a',dest/'auth/_deps/lzfse-build/liblzfse.a',dest/'zip-install/lib/libzip.a']+list((dest/'mb-install/lib').glob('*.a'))
  run('xcrun','libtool','-static','-o',dest/'libapple_auth.a',*archives)
  headers=dest/'headers';shutil.copytree(SOURCE/'AppleAuth/include',headers);shutil.copytree(dest/'auth/include',headers,dirs_exist_ok=True)
  (headers/'module.modulemap').write_text('module apple_auth { header "apple_auth/client_c_api.h" export * }\n')
  auth_options+=['-library',dest/'libapple_auth.a','-headers',headers]
  sdkroot=subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip();cc=subprocess.check_output(['xcrun','--sdk',sdk,'--find','clang'],text=True).strip()
  env=dict(os.environ,SDKROOT=sdkroot,CC=cc,CGO_CFLAGS=f'-target {target} -isysroot {sdkroot}',CGO_LDFLAGS=f'-target {target} -isysroot {sdkroot}',CGO_ENABLED='1',GOOS='ios',GOARCH='arm64')
  run('cmake','-S',unicorn,'-B',dest/'unicorn',*flags,f'-DCMAKE_C_FLAGS=-target {target}','-DUNICORN_ARCH=aarch64','-DUNICORN_BUILD_TESTS=OFF','-DUNICORN_INSTALL=OFF')
  run('cmake','--build',dest/'unicorn','-j6')
  run('go','build','-trimpath','-ldflags=-s -w','-buildmode=c-archive','-o',dest/'libipatool-go.a','./ipalabbridge',cwd=go,env=env)
  run('xcrun','libtool','-static','-o',dest/'libipatool.a',dest/'libipatool-go.a',dest/'unicorn/libunicorn.a')
  go_options+=['-library',dest/'libipatool.a']
 for relative,options in [('Vendor/AppleAuth/Artifacts/apple_auth.xcframework',auth_options),('Vendor/IPAToolCore/IPAToolCore.xcframework',go_options)]:
  artifact=BASE/relative
  if artifact.exists():shutil.rmtree(artifact)
  artifact.parent.mkdir(parents=True,exist_ok=True)
  run('xcodebuild','-create-xcframework',*options,'-output',artifact)
 print('iOS device and simulator native libraries rebuilt from locked snapshots')
if __name__=='__main__':main()
