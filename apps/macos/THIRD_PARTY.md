# Third-party components

- ipatool: https://github.com/majd/ipatool — revision `3e84853e2e5d60540a5022b64895d496910144eb`, MIT. Included source snapshot contains the iOS project's transfer/progress bridge patches, compiled for macOS here.
- AppleAuth: https://github.com/apple-auth/apple-auth — base revision `98c862f7bebc8283a9b87f1578e703f0765dc81d`, with the existing project's login/catalog/transfer patches. Patched source and its licenses are in ThirdPartySource/AppleAuth and Vendor/AppleAuth/Licenses.
- ScriptingApp Community-Scripts: revision `cb67401c795775a10b7623a6d51b7b7479e45f22`. Original provenance hashes are preserved in Resources/NativeStoreRuntime. Six unreviewed inputs are LOCAL ONLY and excluded from Git/source export; no redistribution grant was located in the fixed tree or scripting archive. See dependencies/external-assets.lock.json.
- fairplay-decrypt: https://github.com/EthanArbuckle/fairplay-decrypt — user-provided source based on revision `d81d98b13656c9dbb340f04dd0838137278f44a5`. Native extraction sources and source license are included; signed device helpers are generated locally and excluded from source export. Desktop SSH/IP and JSON adapters are new. The Swift decryption core follows this project's algorithm (GPL-3.0-only).
- ZIPFoundation: https://github.com/weichsel/ZIPFoundation — 0.9.20, revision `22787ffb59de99e5dc1fbfe80b19c97a904ad48d`; source/license included in Vendor/ZIPFoundation.
- libzip: https://github.com/nih-at/libzip — 1.11.4 source/license included in ThirdPartySource/libzip.
- MbedTLS 3.6.5: source archive included in ThirdPartySource; Apache-2.0/GPL alternatives documented by its upstream.
- LZFSE: https://github.com/lzfse/lzfse — fixed revision `e634ca58b4821d9f3d560cdc6df5dec02ffc93fd` in the native source CMake configuration.
- CPython standalone 3.12.14: obtained with Astral uv from https://github.com/astral-sh/python-build-standalone; CPython licenses are in the shipped runtime's standard library.
- cryptography 50.0.2, cffi 2.1.1, pycparser 3.12: license files included with packaged Python distributions.
- libimobiledevice 1.4.0, libusbmuxd, libimobiledevice-glue, libplist and OpenSSL: copied from the local Homebrew installation with their linked libraries relocated into the app. Projects and source: https://github.com/libimobiledevice / https://github.com/openssl/openssl. This first local test bundle contains their macOS 26 Apple Silicon builds.

The application uses the system OpenSSH client; it does not bundle or modify system SSH.

The central, current evidence and release blockers are in [DEPENDENCIES](../../docs/DEPENDENCIES.md) and [RELEASE_AUDIT](../../docs/RELEASE_AUDIT.md). Exact source trees, runtime URLs and byte hashes are recorded in `dependencies/` at repository root; collected original notices are in `licenses/upstream/`. A generated Go profile containing compressed Apple framework/plugin images is excluded separately; the surrounding project license is not evidence of redistribution rights for those images. Public binary release is not approved by this inventory.
