#!/bin/bash
# Local synthetic tests only; never authenticates or connects to a device.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/.build-work/tests"
mkdir -p "$out"
mac="$root/apps/macos"
swiftc -parse-as-library "$mac/App/AppCatalog.swift" "$mac/App/MacQueueModels.swift" "$mac/Tools/Tests/MacQueueTests.swift" -o "$out/mac-queue"
"$out/mac-queue"
swiftc -parse-as-library "$mac/App/LatestViewRequest.swift" "$mac/App/IPAFileExporter.swift" "$mac/Tools/Tests/MacInteractionTests.swift" -o "$out/mac-interactions"
"$out/mac-interactions"
swiftc -parse-as-library "$mac/App/BetaCatalogFailure.swift" "$mac/Tools/Tests/BetaCatalogFailureTests.swift" -o "$out/beta-catalog-failure"
"$out/beta-catalog-failure"
swiftc -parse-as-library "$mac/App/InstalledAppDiscovery.swift" "$mac/Tools/Tests/InstalledAppDiscoveryTests.swift" -o "$out/installed-app-discovery"
"$out/installed-app-discovery"
python3 "$root/scripts/check-source.py"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$mac/Tools/Tests" -p test_extractor.py
swiftc "$mac/App/StoreSessionRecovery.swift" "$mac/Tools/Tests/StoreSessionRecoveryTests.swift" -o "$out/store-recovery"
"$out/store-recovery"
swiftc -parse-as-library "$mac/App/CredentialRecord.swift" "$mac/Tools/Tests/CredentialRecordTests.swift" -o "$out/mac-credentials"
"$out/mac-credentials"
swiftc -parse-as-library "$mac/App/DeviceCredentialModels.swift" "$mac/Tools/Tests/BatchPlanTests.swift" -o "$out/batch-plan"
"$out/batch-plan"
swiftc -parse-as-library "$root/apps/ios/App/FileImportSafety.swift" "$root/apps/ios/Tools/Tests/FileImportSafetyTests.swift" -o "$out/file-import"
"$out/file-import"
cmp "$root/apps/ios/App/JobRecord.swift" "$mac/App/JobRecord.swift"
cmp "$root/apps/ios/App/StoreSessionRecovery.swift" "$mac/App/StoreSessionRecovery.swift"
for platform in ios macos; do
 swiftc -parse-as-library "$root/apps/$platform/App/AppCatalog.swift" "$root/apps/$platform/App/JobRecord.swift" "$mac/Tools/Tests/JobRecoveryTests.swift" -o "$out/job-recovery-$platform"
 "$out/job-recovery-$platform"
done
cmp "$root/apps/ios/App/AppCatalog.swift" "$mac/App/AppCatalog.swift"
cmp "$root/apps/ios/App/AppDetailView.swift" "$mac/App/AppDetailView.swift"
swiftc "$mac/App/AppCatalog.swift" "$root/tests/AppCatalogTests.swift" -o "$out/app-catalog"
"$out/app-catalog"
swiftc -parse-as-library "$mac/App/EnrollmentModelFormat.swift" "$mac/App/CredentialRecord.swift" "$mac/Tools/Tests/EnrollmentModelTests.swift" -o "$out/enrollment-models"
"$out/enrollment-models"
echo 'PASS: offline synthetic suite (no real account/device authentication)'
