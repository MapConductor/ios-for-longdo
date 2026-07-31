// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Longdo Map is a WebView (Longdo Map JS API3 / internal MapLibre GL) based provider, so this
// package has no vendor binary dependency - it only needs MapConductorCore. The map itself is
// loaded inside a WKWebView from https://api.longdo.com/map3/, mirroring android-for-longdo which
// wraps the Longdo Map API3 WebView SDK.
let frameworkLibraryType: Product.Library.LibraryType? =
    ProcessInfo.processInfo.environment["MAPCONDUCTOR_BUILD_XCFRAMEWORK"] == "1" ? .dynamic : nil
let usingLocalCore = FileManager.default.fileExists(atPath: "../ios-sdk-core/Package.swift")
let coreDependency: Package.Dependency = usingLocalCore
    ? .package(path: "../ios-sdk-core")
    : .package(url: "https://github.com/MapConductor/ios-sdk-core", from: "1.0.0")

let package = Package(
    name: "ios-for-longdo",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "MapConductorForLongdo",
            type: frameworkLibraryType,
            targets: ["MapConductorForLongdo"]
        ),
    ],
    dependencies: [
        coreDependency,
        // Official Longdo Map iOS SDK (Framework 4.x). Distributed as a binary XCFramework via SPM.
        .package(url: "https://github.com/MetamediaTechnology/longdo-map-ios-framework", from: "4.1.0"),
    ],
    targets: [
        .target(
            name: "MapConductorForLongdo",
            dependencies: [
                .product(name: "MapConductorCore", package: "ios-sdk-core"),
                .product(name: "LongdoMapFramework", package: "longdo-map-ios-framework"),
            ]
        ),
    ]
)
