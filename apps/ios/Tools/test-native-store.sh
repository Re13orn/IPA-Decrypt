#!/bin/bash
set -euo pipefail
[[ $# -ge 1 ]] || { echo "Usage: $0 /path/to/derived-data [booted-simulator-id]" >&2; exit 2; }
base="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$1"
testwork="$(cd "$1" && pwd)"
simulator="${2:-booted}"
python3 "$base/Tools/verify-native-runtime.py"
xcodebuild -project "$base/IPALab.xcodeproj" -scheme IPALab -sdk iphonesimulator \
  -configuration Debug -derivedDataPath "$testwork" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER=local.ipalab.layoutcheck build > "$testwork/native-store-build.log" 2>&1
products="$testwork/Build/Products/Debug-iphonesimulator"
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios16.0-simulator \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -parse-as-library \
  -I "$products" -I "$products/include" \
  "$base/App/NativeStoreLogin.swift" "$base/App/TestFlightCatalog.swift" "$base/Tools/Tests/NativeStoreLoginTests.swift" \
  "$products/AppleAuth.o" \
  "$base/Vendor/AppleAuth/Artifacts/apple_auth.xcframework/ios-arm64_x86_64-simulator/libapple_auth.a" \
  -lc++ -lz -framework Security -o "$testwork/native-store-tests"
xcrun simctl spawn "$simulator" "$testwork/native-store-tests"
