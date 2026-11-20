// swift-tools-version: 5.9
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(name: "IPADecryptMac", platforms: [.macOS("15.0")], dependencies: [
    .package(path: "Vendor/AppleAuth"), .package(path: "Vendor/ZIPFoundation")
], targets: [
    .target(name: "MacBridge", path: "MacBridge", publicHeadersPath: "include", linkerSettings: [
        .unsafeFlags(["-L", root + "/Vendor", "-lipatool"]), .linkedFramework("Security"), .linkedFramework("CoreFoundation")
    ]),
    .executableTarget(name: "IPADecryptMac", dependencies: ["AppleAuth", "ZIPFoundation", "MacBridge"], path: "App", exclude: ["IPALab-Bridging-Header.h"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")])
])
