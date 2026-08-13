// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Intempt",
    platforms: [
        .iOS(.v15),
        .tvOS(.v15),
        .macOS(.v12),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "Intempt", targets: ["Intempt"])
    ],
    targets: [
        .target(
            name: "Intempt",
            path: "Sources/Intempt",
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "IntemptTests",
            dependencies: ["Intempt"],
            path: "Tests/IntemptTests"
        ),
    ]
)
