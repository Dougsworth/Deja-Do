// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DejaDo",
    platforms: [.macOS(.v13)],
    targets: [
        // The matching engines, step checking and data model. No AppKit, so it is
        // fully unit tested, and the tests also run on Linux.
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
                .linkedFramework("Security"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "DejaDoCoreTests",
            dependencies: ["DejaDoCore"],
            path: "Tests/DejaDoCoreTests"
        )
    ]
)
