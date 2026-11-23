# Building and testing

[English](BUILDING.md) · [简体中文](../BUILDING.md)

## Environment

The current local build environment uses Apple Silicon and an Xcode 26-series toolchain. Deployment targets are macOS 15 and iOS 16. Native build tools include Go, CMake, Ninja, and Python; device helper builds also require the iOS SDK and `ldid`.

Source, generated libraries, and distributable apps are separate. `.build-work/` holds disposable build inputs and caches; `dist/` holds outputs. Neither is committed. Signing identities, provisioning profiles, account state, and real credentials stay outside the repository.

## Required inputs

Read the [dependency inventory](../DEPENDENCIES.md) and the fixed hashes in `dependencies/` before building. Generated native libraries must be rebuilt. Some Apple-derived runtime inputs are excluded from the source export; a source ZIP alone is not a complete login runtime.

The full list and provenance are in `dependencies/external-assets.lock.json`. Local imports must match the recorded hashes. An import for local verification is not a grant of redistribution rights. Details and the cache-isolated reconstruction procedure are in the [full build notes](../BUILDING.md).

## Native libraries

```sh
python3 scripts/verify-dependencies.py
python3 apps/macos/Tools/build-core.py --work "$PWD/.build-work/native-macos"
python3 scripts/build-native-ios.py --work "$PWD/.build-work/native-ios"
```

The Mac builder uses the patched snapshots in `apps/macos/ThirdPartySource`. Go modules are pinned by `go.mod` / `go.sum`; the bootstrap toolchain is pinned to Go 1.26.5. The iOS builder produces device and arm64 simulator slices rather than reusing Mac binaries.

Build extractor device helpers from `apps/macos/Resources/Extractor/credential-retrieval/Makefile` with the iOS SDK and `ldid`, then copy its `build/bundle/` outputs to the runtime bundle. Preserve device-side signatures.

## Swift builds

After preparing native libraries and external assets:

```sh
bash scripts/build.sh macos
bash scripts/build.sh ios
```

Mac executable: `.build-work/swift-macos/release/IPADecryptMac`.

iOS unsigned device app: `.build-work/ios/Build/Products/Release-iphoneos/IPADecrypt.app`.

The Xcode scheme is still named `IPALab`. Configure signing for your own team, Bundle ID, and target device when installing a signed iOS build.

## Standalone Mac package

Prepare fixed-version Python, USB, and proof-engine inputs:

```sh
python3 scripts/bootstrap-python.py --work "$PWD/.build-work/python-runtime"
python3 scripts/bootstrap-usb.py --work "$PWD/.build-work/usb-runtime"
python3 scripts/bootstrap-unicorn.py --work "$PWD/.build-work/store-runtime"
export IPA_PYTHON_HOME="$PWD/.build-work/python-runtime/python"
export IPA_PYTHON_PACKAGES="$PWD/.build-work/python-runtime/packages"
bash scripts/build.sh package-macos
```

Output: `dist/macos/IPA 解密.app`. `IPA_MAC_OUTPUT` can override the destination. The packager relocates libraries, includes license notices, ad-hoc signs the app, and checks its resources and dependencies. It does not perform Developer ID notarization.

The Unicorn archive and dynamic library are hash-pinned. The app installs the verified original library bytes into the user cache without a first-login runtime download.

## Validation

```sh
bash scripts/test.sh
python3 scripts/verify-assets.py
python3 scripts/smoke-macos.py "dist/macos/IPA 解密.app"
bash scripts/build.sh package-ios
python3 scripts/check-release.py \
  --macos-app "dist/macos/IPA 解密.app" \
  --ios-ipa /absolute/path/to/unsigned.ipa
```

The offline suite uses synthetic data. The Mac smoke check launches the packaged app and exercises its helpers. It also executes the ARM64 proof engine in a fresh HOME with networking denied, and rechecks the bundle signature after execution. It does not log into Apple or connect to a real device.

The [macOS compatibility workflow](../../.github/workflows/macos-compatibility.yml) can validate a candidate release on macOS 15 / arm64:

```sh
gh workflow run macos-compatibility.yml -f tag=v1.0.9
```

Use a prepared draft release, review the result, and publish after checks pass. Package and component checks do not replace first-install acceptance on physical hardware. See [validation records](../PORTABILITY.md).
