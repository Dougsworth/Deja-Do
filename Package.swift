// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DejaDo",
    platforms: [.macOS(.v13)],
    targets: [
        // The matching engine and data model. No AppKit, so it is fully unit tested.
        .target(
            name: "DejaDoCore",
            path: "Sources/DejaDoCore"
        ),
        // The menu bar app: recording, accessibility, replay and UI.
        .executableTarget(
            name: "DejaDo",
            dependencies: ["DejaDoCore"],
            path: "Sources/DejaDo",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "DejaDoCoreTests",
            dependencies: ["DejaDoCore"],
            path: "Tests/DejaDoCoreTests"
        )
    ]
)
