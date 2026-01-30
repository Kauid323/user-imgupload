// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "ImgUtilSwift",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "img-util-swift", targets: ["ImgUtilSwift"])
    ],
    targets: [
        .executableTarget(
            name: "ImgUtilSwift",
            dependencies: []
        )
    ]
)
