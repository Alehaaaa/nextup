// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NextupKit",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17)],
    products: [
        .library(name: "NextupKit", targets: ["NextupKit"]),
    ],
    targets: [
        .target(name: "NextupKit"),
        .testTarget(name: "NextupKitTests", dependencies: ["NextupKit"]),
    ]
)
