// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GymTracker",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "GymTracker", targets: ["GymTracker"]),
    ],
    targets: [
        .target(
            name: "GymTracker",
            path: "Sources"
        ),
    ]
)
