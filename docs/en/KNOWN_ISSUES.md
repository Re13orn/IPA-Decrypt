# Compatibility and known issues

[English](KNOWN_ISSUES.md) · [简体中文](../KNOWN_ISSUES.md)

- **Platforms:** Apple Silicon / macOS 15+ and iOS 16+. Mac package startup and offline components have been checked; iOS has device-build and resource checks. These do not establish complete first-install acceptance on new physical hardware. See [validation records](../PORTABILITY.md).
- **Mac models:** compatibility depends on local Store registration state and the IPA's license. A model validated with one app may not match another IPA or an IPA obtained using another login route. Account labels cannot override this check.
- **Accounts:** TestFlight uses a non-public client protocol that may change. Provide a diagnostic stage code when reporting failures. Automatic App Store session recovery requires a valid saved password and switches to interactive verification when Apple requests it.
- **File selection:** individual iOS 18.1.1 devices have shown a blank or stalled system Files picker. The credential importer also accepts hex text. If the system Files service is affected, restarting the device may restore it; the trigger remains under investigation.
- **Transfers:** retry restarts processing. Byte-range resume, background execution, and recovery after process interruption need further work; behavior differs by platform.
- **Mac installation:** builds are ad-hoc signed and not notarized. See the [installation guide](INSTALLATION.md). An earlier Finder launch-registration failure remains under investigation.
- **Data:** saved passwords use local JSON without application-level encryption. See [privacy and storage](PRIVACY.md).
- **Building:** generated native libraries and external runtime assets need separate preparation. See the [build guide](BUILDING.md).
