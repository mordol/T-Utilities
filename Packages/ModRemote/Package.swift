// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ModRemote",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ModRemote", targets: ["ModRemote"]),
    ],
    dependencies: [
        .package(path: "../TUCore"),
        .package(path: "../TUUI"),
    ],
    targets: [
        .target(name: "ModRemote", dependencies: ["TUCore", "TUUI"]),
        .testTarget(name: "ModRemoteTests", dependencies: ["ModRemote"]),
    ]
)
