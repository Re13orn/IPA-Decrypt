# Frequently asked questions

[English](FAQ.md) · [简体中文](../FAQ.md)

## Do I need a jailbroken device?

The Mac local-model route does not require a jailbroken iPhone. It requires a supported Apple Silicon Mac and a compatible App Store iPhone or iPad app installed on that Mac. The resulting model is used by the Mac app and must match the IPA's license.

Extracting 16-byte credentials from an iPhone or iPad requires a jailbroken device with SSH. An existing credential can also be imported. See the [credential guide](CREDENTIALS.md).

## Why does local extraction list only a few apps?

The list includes apps with detected iOS FairPlay license files, not every installed Mac app. It scans `/Applications`, `~/Applications`, and their subfolders; other locations can be selected manually. There is no fixed two- or three-app limit.

Detected apps are validation sources. Multiple apps may lead to the same credential; detection alone does not prove extraction will succeed.

## Can I copy a Mac model as 32-character hex for iOS?

No. The iOS hex importer expects exactly 16 bytes represented as 32 hex characters. Mac models have a different structure and are used by the Mac app. A displayed fingerprint identifies a record; it is not the credential itself.

## Why does TestFlight return HTTP 401?

The service rejected the saved session. Reauthenticate through the TestFlight account settings, then reload the list. An App Store account selection does not change the independently selected TestFlight account. A 401 response is not evidence that the account has no joined tests.

## Why is iOS 1.0.3 linked to release tag v1.0.7?

Mac and iOS versions advance independently. The iOS 1.0.3 asset was included in `v1.0.7` and has not changed in subsequent Mac-only releases. The README links directly to each platform's named asset.

## Why is the Mac app not notarized?

Current releases use ad-hoc signing rather than Developer ID notarization. This is stated beside the downloads. Check the source and file checksum, then follow [Apple's installation guidance](https://support.apple.com/en-us/102445). No notarization date is announced.

## Is a fresh device's complete workflow verified?

Published records distinguish package checks, offline component tests, simulator checks, and actual account/device acceptance. A complete first-install workflow on a new physical iPhone or Mac has not been accepted. See the [validation records](../PORTABILITY.md).
