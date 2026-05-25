// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "uZora",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "uZora", targets: ["uZora"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "uZora",
            path: "Sources/uZora",
            exclude: ["Support/Info.plist"],
            linkerSettings: [
                // Embed Info.plist directly into the Mach-O __TEXT,__info_plist
                // section so the executable is treated as an LSUIElement
                // (menubar-only) bundle even when launched as a bare binary
                // from `.build/`. When packaged into a proper .app later, the
                // bundle's Info.plist will take over.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/uZora/Support/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "uZoraTests",
            dependencies: ["uZora"],
            path: "Tests/uZoraTests"
        ),
    ]
)
