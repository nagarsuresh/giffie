// swift-tools-version:5.9
import PackageDescription

// GiffieCore is plain Swift + Foundation so the encoder can be built and
// tested anywhere (including Linux CI). The Giffie app target needs AppKit,
// SwiftUI and ScreenCaptureKit, so it only exists when building on macOS.
var products: [Product] = [
    .library(name: "GiffieCore", targets: ["GiffieCore"]),
]

var targets: [Target] = [
    .target(
        name: "GiffieCore",
        path: "Sources/GiffieCore"
    ),
    .testTarget(
        name: "GiffieCoreTests",
        dependencies: ["GiffieCore"],
        path: "Tests/GiffieCoreTests"
    ),
]

#if os(macOS)
products.append(.executable(name: "Giffie", targets: ["Giffie"]))
targets.append(
    .executableTarget(
        name: "Giffie",
        dependencies: ["GiffieCore"],
        path: "Sources/Giffie",
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("SwiftUI"),
            .linkedFramework("ScreenCaptureKit"),
            .linkedFramework("Carbon"),
            .linkedFramework("ServiceManagement"),
        ]
    )
)
#endif

let package = Package(
    name: "Giffie",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
