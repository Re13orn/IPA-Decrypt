# Data and privacy

[English](PRIVACY.md) · [简体中文](../PRIVACY.md)

## Local storage

| Platform | Default location |
| --- | --- |
| iOS | Application sandbox |
| macOS | `~/Library/Application Support/IPADecryptMac` |

Local data can include account sessions, passwords the user chooses to save, FairPlay credentials, processing records, downloaded files, and extraction material. Exports are written to the location the user selects.

Saving passwords is optional. Session recovery uses the corresponding account's saved password. SSH passwords are used for the current operation and are not written to disk. Viewing or copying credentials is initiated by the user.

Private files use atomic writes and platform file-protection options. Mac private directories use `0700` and private files use `0600`. Saved passwords use local JSON storage **without application-level encryption**; other programs running as the same user may be able to access those files.

Account labels organize records. License verification determines whether credentials match.

## Local-network sharing

When web sharing is enabled, anyone who has the URL and can reach the service over the network can download the selected IPA. Stop the service when finished. Access controls and link expiration need further work.

## Reports

Provide app and OS versions, diagnostic stage codes, and redacted reproduction steps. Do not publish passwords, verification codes, cookies, session tokens, real credentials, signing material, or device dumps.
