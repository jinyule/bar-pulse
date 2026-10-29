// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BarPulse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BarPulse", targets: ["BarPulse"]),
        .library(name: "BarPulseCore", targets: ["BarPulseCore"]),
    ],
    targets: [
        .target(
            name: "BarPulseCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(
            name: "BarPulse",
            dependencies: ["BarPulseCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "BarPulseCoreTests",
            dependencies: ["BarPulseCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
