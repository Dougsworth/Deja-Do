// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DejaDo",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Auto update for copies sent outside the App Store.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
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
            dependencies: ["DejaDoCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/DejaDo",
            linkerSettings: [
                // Sparkle.framework is copied into the app's Frameworks folder by build.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
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
