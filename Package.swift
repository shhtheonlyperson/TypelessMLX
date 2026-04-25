// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypelessMLX",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "TypelessMLXCore",
            path: "TypelessMLXCore/Sources",
            linkerSettings: [
                .linkedFramework("CoreAudio")
            ]
        ),
        .executableTarget(
            name: "TypelessMLX",
            dependencies: ["TypelessMLXCore"],
            path: "TypelessMLX/Sources",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])
            ]
        ),
        .executableTarget(
            name: "TypelessMLXRegressionTests",
            dependencies: ["TypelessMLXCore"],
            path: "Tests/TypelessMLXRegressionTests"
        )
    ]
)
