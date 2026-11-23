# Installation

[English](INSTALLATION.md) · [简体中文](../INSTALLATION.md)

## Choose your platform

| Platform | Version | Download | Requirements |
| --- | --- | --- | --- |
| macOS | 1.0.9 | [Apple Silicon DMG](https://github.com/Re13orn/IPA-Decrypt/releases/download/v1.0.9/IPA-Decrypt-macOS-1.0.9-arm64.dmg) | Apple Silicon · macOS 15+ |
| iOS | 1.0.3 | [Unsigned IPA](https://github.com/Re13orn/IPA-Decrypt/releases/download/v1.0.7/IPA-Decrypt-iOS-1.0.3-unsigned.ipa) | iOS 16+ · valid signing required |

The two apps have independent version numbers. The iOS asset is retained in release `v1.0.7`; the Mac-only `v1.0.9` release links to it.

## Verify downloads

Download the asset and its release's `SHA256SUMS`. To verify a single file from a release that contains several assets:

```sh
# Run in the download directory, with the checksum file for this release.
grep 'IPA-Decrypt-macOS-1.0.9-arm64.dmg$' SHA256SUMS | shasum -a 256 -c -
```

For iOS, use the checksum file from `v1.0.7` and select `IPA-Decrypt-iOS-1.0.3-unsigned.ipa` instead.

## macOS

1. Open the DMG and drag **IPA 解密.app** to **Applications**.
2. When updating, quit the app before replacing it.
3. Launch it from Applications. Add an App Store or TestFlight account when needed; searching the App Store does not require login.

The app is ad-hoc signed and **not notarized**. Follow [Apple's instructions for opening apps from identified and unidentified developers](https://support.apple.com/en-us/102445) after verifying the download and its source. Signing verification and Gatekeeper approval are separate checks.

The package includes Python, USB helpers, and the pinned Store proof engine. Apple authentication, device registration, and downloads require network access.

## iOS

The release IPA is an unsigned device build. Sign it with a certificate and provisioning method valid for your device, then install it using your signing tool. A download link alone is not an App Store or TestFlight invitation for IPA Decrypt.

## First use

- Choose an App Store or TestFlight account for downloads. Each service retains its own selection.
- Prepare matching credentials using the [credential guide](CREDENTIALS.md).
- Download or import an IPA, then open its processing record to view the result and export files.
- If iOS file selection is unavailable, the credential importer also accepts a 32-character hex value.

## Store proof runtime diagnostics

Mac 1.0.9 includes Unicorn 2.1.4 and verifies both its archive and library hashes. Its first initialization does not need to download the engine.

| Diagnostic | Next step |
| --- | --- |
| `login/runtime-bundle-missing` / `login/runtime-bundle-invalid` | Download and verify the package again; replace the complete app after quitting it. |
| `login/runtime-cache-write` | Check available storage and your user cache directory's write permissions. |
| `login/unicorn-link`, `login/unicorn-execution`, or `login/unicorn-executable-memory` | Report the full diagnostic, app version, chip, and macOS version for loading/execution investigation. |

See [known issues](KNOWN_ISSUES.md) for session failures and other limitations. Keep passwords, verification codes, session files, and real credentials out of reports.
