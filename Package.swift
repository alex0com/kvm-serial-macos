// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KVMSerial",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KVMSerial", targets: ["KVMSerial"])
    ],
    targets: [
        .target(name: "KVMCore"),
        .executableTarget(
            name: "KVMSerial",
            dependencies: ["KVMCore"]
        ),
        .testTarget(name: "KVMCoreTests", dependencies: ["KVMCore"]),
    ]
)
