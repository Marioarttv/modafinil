// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Modafinil",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Modafinil", targets: ["Modafinil"]),
        .executable(name: "ModafinilHelper", targets: ["ModafinilHelper"])
    ],
    targets: [
        .target(
            name: "ModafinilShared"
        ),
        .target(
            name: "ModafinilRemoteProtocol",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "Modafinil",
            dependencies: ["ModafinilShared", "ModafinilRemoteProtocol"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "ModafinilHelper",
            dependencies: ["ModafinilShared"],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "ModafinilRemoteProtocolTests",
            dependencies: ["ModafinilRemoteProtocol"]
        )
    ]
)
