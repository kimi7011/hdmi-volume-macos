// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HDMIVolumeDriver",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HDMIVolume", type: .dynamic, targets: ["HDMIVolume"])],
    dependencies: [.package(url: "https://github.com/apple/swift-atomics.git", exact: "1.3.1")],
    targets: [
        .target(name: "HDMIVolume", dependencies: [.product(name: "Atomics", package: "swift-atomics")])
    ]
)
