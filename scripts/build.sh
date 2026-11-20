#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
 macos)
  swift build -c release --package-path "$root/apps/macos" --scratch-path "$root/.build-work/swift-macos"
  ;;
 ios)
  xcodebuild -project "$root/apps/ios/IPALab.xcodeproj" -scheme IPALab -sdk iphoneos -configuration Release -derivedDataPath "$root/.build-work/ios" CODE_SIGNING_ALLOWED=NO build
  ;;
 package-ios)
  bash "$0" ios
  python3 "$root/scripts/package-ios.py" --app "$root/.build-work/ios/Build/Products/Release-iphoneos/IPADecrypt.app"
  ;;
 package-macos)
  bash "$0" macos
  IPA_MAC_EXECUTABLE="$root/.build-work/swift-macos/release/IPADecryptMac" python3 "$root/apps/macos/Tools/package.py"
  ;;
 *) echo 'Usage: scripts/build.sh {macos|ios|package-macos|package-ios}' >&2; exit 2;;
esac
