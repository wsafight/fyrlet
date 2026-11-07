// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Fyrlet",
    platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15), .watchOS(.v8)],
    products: [.library(name: "Fyrlet", targets: ["Fyrlet"])],
    targets: [
        .target(name: "Fyrlet"),
        .testTarget(name: "FyrletTests", dependencies: ["Fyrlet"]),
    ]
)
