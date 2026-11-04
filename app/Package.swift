// swift-tools-version: 6.0
import PackageDescription

/// Run ../scripts/build-core.sh first; it produces Generated/.
let package = Package(
    name: "NIMQO",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "nimqo_ffiFFI", path: "Generated/NimqoFFI.xcframework"),
        .target(
            name: "NimqoCore",
            dependencies: ["nimqo_ffiFFI"],
            path: "Generated/Swift",
            // Generated code; it predates Swift 6 strict concurrency checks.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("SystemConfiguration")]
        ),
        .executableTarget(name: "NIMQO", dependencies: ["NimqoCore"]),
    ]
)
