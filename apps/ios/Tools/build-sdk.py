"""Rebuild the pinned AppleAuth dependency for arm64 iOS and iOS Simulator."""
from pathlib import Path
import argparse
import shutil
import subprocess

BASE = Path(__file__).resolve().parents[1]
APPLE = "98c862f7bebc8283a9b87f1578e703f0765dc81d"

def run(*values, cwd=None):
    subprocess.run([str(value) for value in values], cwd=cwd, check=True)

def checkout(directory, repo, revision):
    if not (directory / ".git").is_dir():
        run("git", "init", "-q", directory)
    run("git", "fetch", "--depth", "1", repo, revision, cwd=directory)
    run("git", "checkout", "--detach", "-q", "FETCH_HEAD", cwd=directory)

def build(work):
    source = work / "apple-auth"
    checkout(source, "https://github.com/apple-auth/apple-auth.git", APPLE)
    libzip = work / "libzip"
    checkout(libzip, "https://github.com/nih-at/libzip.git", "refs/tags/v1.11.4")
    # The upstream Apple packager builds MbedTLS and nlohmann JSON per SDK.
    # Its first pass avoids cross-compiling optional download dependencies.
    stage = work / "upstream"
    if not (stage / "iphonesimulator/dependencies/lib/libmbedcrypto.a").is_file():
        run("python3", source / "tools/build_apple.py", "--with-client", "--deployment-target", "16.0",
            "--output", stage)
    shutil.copyfile(BASE / "Tools/download_apple.mm", source / "src/client/download_apple.mm")
    shutil.copyfile(BASE / "Tools/sms_challenge.hpp", source / "src/client/sms_challenge.hpp")
    run("git", "restore", "--source=HEAD", "src/client/apple_plist.cpp",
        "src/client/authentication.cpp", "src/client/client.cpp", "src/client/store.cpp",
        "src/testflight/protocol.cpp",
        "include/apple_auth/client.hpp", "include/apple_auth/client_c_api.h", "src/api/client_api.cpp",
        "swift/AppleAuth/Sources/AppleAuth/Models.swift", "swift/AppleAuth/Sources/AppleAuth/Device.swift", cwd=source)
    run("git", "apply", BASE / "Tools/apple-auth-login.patch", cwd=source)
    makefile = source / "CMakeLists.txt"
    pristine = subprocess.check_output(["git", "show", "HEAD:CMakeLists.txt"], cwd=source, text=True)
    patched = pristine.replace("project(apple_auth VERSION 0.1.3 LANGUAGES C CXX)",
        "project(apple_auth VERSION 0.1.3 LANGUAGES C CXX)\nenable_language(OBJCXX)")
    patched = patched.replace("AND (NOT APPLE_AUTH_WITH_CLIENT OR NOT APPLE_AUTH_WITH_CURL)",
        "AND NOT APPLE_AUTH_WITH_CLIENT")
    patched = patched.replace("if(WIN32)\n        find_package(libzip", "if(APPLE OR WIN32)\n        find_package(libzip")
    patched = patched.replace("src/client/download.cpp", "src/client/download_apple.mm")
    patched = patched.replace("target_include_directories(apple_auth_client PRIVATE ${lzfse_SOURCE_DIR}/src)",
        "set_source_files_properties(src/client/download_apple.mm PROPERTIES COMPILE_OPTIONS -fobjc-arc)\n"
        "    set_target_properties(apple_auth_client PROPERTIES OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED TRUE)\n"
        "    target_include_directories(apple_auth_client PRIVATE ${lzfse_SOURCE_DIR}/src)")
    makefile.write_text(patched)
    options = []
    for sdk in ("iphoneos", "iphonesimulator"):
        folder = work / sdk
        prefix = folder / "libzip-install"
        sdk_flags = ["-G", "Ninja", "-DCMAKE_SYSTEM_NAME=iOS", f"-DCMAKE_OSX_SYSROOT={sdk}",
            "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=16.0",
            "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF"]
        run("cmake", "-S", libzip, "-B", folder / "libzip", *sdk_flags,
            "-DENABLE_COMMONCRYPTO=OFF", "-DENABLE_GNUTLS=OFF", "-DENABLE_MBEDTLS=OFF",
            "-DENABLE_OPENSSL=OFF", "-DENABLE_BZIP2=OFF", "-DENABLE_LZMA=OFF",
            "-DENABLE_ZSTD=OFF", "-DBUILD_TOOLS=OFF", "-DBUILD_REGRESS=OFF",
            "-DBUILD_EXAMPLES=OFF", "-DBUILD_DOC=OFF", f"-DCMAKE_INSTALL_PREFIX={prefix}")
        run("cmake", "--build", folder / "libzip", "--target", "install", "-j6")
        mb = stage / sdk / "dependencies"
        cmake_prefix = f"{prefix};{mb};{stage / 'json-install'}"
        run("cmake", "-S", source, "-B", folder / "auth", *sdk_flags,
            f"-DCMAKE_PREFIX_PATH={cmake_prefix}", f"-DCMAKE_FIND_ROOT_PATH={cmake_prefix}",
            "-DAPPLE_AUTH_WITH_CLIENT=ON", "-DAPPLE_AUTH_WITH_CURL=OFF",
            "-DAPPLE_AUTH_WITH_TESTFLIGHT=ON", "-DAPPLE_AUTH_BUILD_EXAMPLES=OFF")
        run("cmake", "--build", folder / "auth", "-j6")
        install = folder / "auth-install"
        run("cmake", "--install", folder / "auth", "--prefix", install)
        library = folder / "libapple_auth.a"
        archives = sorted((install / "lib").glob("*.a")) + sorted((mb / "lib").rglob("*.a")) + sorted((prefix / "lib").glob("*.a"))
        run("xcrun", "libtool", "-static", "-o", library, *archives)
        headers = install / "include"
        (headers / "module.modulemap").write_text('module apple_auth { header "apple_auth/client_c_api.h" export * }\n')
        options += ["-library", library, "-headers", headers]
    package = BASE / "Vendor/AppleAuth"
    package.mkdir(parents=True, exist_ok=True)
    artifact = package / "Artifacts/apple_auth.xcframework"
    artifact.parent.mkdir(exist_ok=True)
    built = work / "apple_auth.xcframework"
    if built.exists():
        shutil.rmtree(built)
    run("xcodebuild", "-create-xcframework", *options, "-output", built)
    shutil.copytree(source / "swift/AppleAuth", package, dirs_exist_ok=True)
    if artifact.exists():
        shutil.rmtree(artifact)
    shutil.copytree(built, artifact)
    manifest = package / "Package.swift"
    manifest.write_text(manifest.read_text().replace('.linkedLibrary("c++")', '.linkedLibrary("c++"), .linkedLibrary("z")'))
    for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
        shutil.copyfile(source / name, package / name)
    shutil.copytree(source / "LICENSES", package / "Licenses", dirs_exist_ok=True)
    shutil.copyfile(libzip / "LICENSE", package / "Licenses/libzip.txt")
    shutil.copyfile(stage / "mbedtls-3.6.5/LICENSE", package / "Licenses/MbedTLS.txt")
    shutil.copyfile(stage / "json/LICENSE.MIT", package / "Licenses/nlohmann-json.txt")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("work", type=Path)
    args = parser.parse_args()
    args.work.mkdir(parents=True, exist_ok=True)
    build(args.work.resolve())
