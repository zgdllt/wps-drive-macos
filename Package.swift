// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WPSDrive",
    platforms: [.macOS(.v13)],
    products: [.library(name: "DriveCore", targets: ["DriveCore"])],
    targets: [
        .target(name: "DriveCore"),
        .executableTarget(name: "WPSDriveVerification", dependencies: ["DriveCore"], path: "Tests/Verification")
    ]
)
