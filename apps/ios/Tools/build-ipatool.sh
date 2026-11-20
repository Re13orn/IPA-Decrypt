#!/bin/bash
set -euo pipefail
[[ $# -eq 1 ]] || { echo "Usage: $0 /path/to/work-directory" >&2; exit 2; }
base="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$1"
work="$(cd "$1" && pwd)"
source="$work/ipatool"
commit=3e84853e2e5d60540a5022b64895d496910144eb
if [[ ! -d "$source/.git" ]]; then git init -q "$source"; fi
git -C "$source" fetch --depth 1 https://github.com/majd/ipatool.git "$commit"
git -C "$source" checkout --detach -q "$commit"
mkdir -p "$source/ipalabbridge"
cp "$base/Tools/ipatool/main.go" "$source/ipalabbridge/main.go"
cp "$base/Tools/ipatool/appstore/transfer.go" "$source/pkg/appstore/ipalab_transfer.go"
git -C "$source" restore --source=HEAD pkg/appstore/appstore_download.go pkg/appstore/appstore_download_parallel.go pkg/appstore/appstore_download_product.go pkg/appstore/appstore_purchase.go pkg/appstore/appstore_get_version_metadata.go pkg/appstore/appstore_list_versions.go pkg/appstore/appstore_delisted_download_test.go pkg/appstore/appstore_purchase_test.go
git -C "$source" apply "$base/Tools/ipatool/transfer.patch"
unicorn="$work/unicorn-2.1.4"
if [[ ! -f "$work/unicorn-2.1.4.tgz" ]]; then
    if [[ -f "$base/Tools/ipatool/unicorn/unicorn-2.1.4.tgz" ]]; then
        cp "$base/Tools/ipatool/unicorn/unicorn-2.1.4.tgz" "$work/unicorn-2.1.4.tgz"
    else
        curl -fLSs --retry 3 https://github.com/unicorn-engine/unicorn/archive/refs/tags/2.1.4.tar.gz -o "$work/unicorn-2.1.4.tgz"
    fi
fi
printf '%s  %s\n' ea8863f095a0136388694e5a6063afd9bb7650e30243dd6251af59c5ce5601f4 "$work/unicorn-2.1.4.tgz" | shasum -a 256 -c
if [[ ! -f "$unicorn/.ipalab-ios-patched" ]]; then
    tar -xzf "$work/unicorn-2.1.4.tgz" -C "$work"
    patch -d "$unicorn" -p1 < "$base/Tools/ipatool/unicorn/unicorn-ios.patch"
    touch "$unicorn/.ipalab-ios-patched"
fi

build() (
    cd "$source"
    sdk="$1"
    target="$2"
    dest="$work/$sdk"
    mkdir -p "$dest"
    sdkroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    export SDKROOT="$sdkroot" CC="$(xcrun --sdk "$sdk" --find clang)"
    export CGO_CFLAGS="-target $target -isysroot $sdkroot"
    export CGO_LDFLAGS="$CGO_CFLAGS" CGO_ENABLED=1 GOOS=ios GOARCH=arm64
    ARCHFLAGS="-arch arm64" cmake -S "$unicorn" -B "$dest/unicorn" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdkroot" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
        -DCMAKE_C_FLAGS="-target $target" -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF -DUNICORN_ARCH=aarch64 -DUNICORN_BUILD_TESTS=OFF -DUNICORN_INSTALL=OFF
    cmake --build "$dest/unicorn" --parallel 6
    go build -trimpath -ldflags="-s -w" -buildmode=c-archive -o "$dest/libipatool-go.a" ./ipalabbridge
    xcrun libtool -static -o "$dest/libipatool.a" "$dest/libipatool-go.a" "$dest/unicorn/libunicorn.a"
)
build iphoneos arm64-apple-ios16.0 &
device=$!
build iphonesimulator arm64-apple-ios16.0-simulator &
simulator=$!
wait "$device"
wait "$simulator"
output="$work/IPAToolCore.xcframework"
if [[ -d "$output" ]]; then
    mv "$output" "$output.$(date +%s).previous"
fi
xcodebuild -create-xcframework \
    -library "$work/iphoneos/libipatool.a" \
    -library "$work/iphonesimulator/libipatool.a" -output "$output"
mkdir -p "$base/Vendor/IPAToolCore"
target="$base/Vendor/IPAToolCore/IPAToolCore.xcframework"
if [[ -d "$target" ]]; then mv "$target" "$work/vendor.$(date +%s).previous"; fi
ditto "$output" "$target"
