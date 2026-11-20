#!/bin/bash
set -euo pipefail
[[ $# -ge 1 ]] || { echo 'Usage: test-credentials.sh /path/to/derived-data [booted-simulator-id]'; exit 2; }
base="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$1"
testwork="$(cd "$1" && pwd)"
simulator="${2:-booted}"
xcodebuild -project "$base/IPALab.xcodeproj" -scheme IPALab -sdk iphonesimulator -configuration Debug -derivedDataPath "$testwork" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build > "$testwork/credential-build.log" 2>&1
products="$testwork/Build/Products/Debug-iphonesimulator"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios16.0-simulator -sdk "$sdk" -parse-as-library "$base/App/CredentialRecord.swift" "$base/Tools/Tests/CredentialRecordTests.swift" -o "$testwork/credential-record-tests"
xcrun simctl spawn "$simulator" "$testwork/credential-record-tests"
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios16.0-simulator -sdk "$sdk" -parse-as-library -I "$products" "$base/App/CredentialRecord.swift" "$base/App/FairPlay.swift" "$base/Tools/Tests/CredentialVerificationTests.swift" "$products/ZIPFoundation.o" -o "$testwork/credential-verification-tests"
xcrun simctl spawn "$simulator" "$testwork/credential-verification-tests" "$base/Tools/Tests/Fixtures"
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios16.0-simulator -sdk "$sdk" -parse-as-library "$base/App/FileImportSafety.swift" "$base/Tools/Tests/FileImportSafetyTests.swift" -o "$testwork/file-import-tests"
xcrun simctl spawn "$simulator" "$testwork/file-import-tests"
