// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Etui",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Etui",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"]),
            ]
        ),
        .systemLibrary(name: "CRime"),
        .executableTarget(name: "Pinyin", dependencies: ["CRime"]),
        .testTarget(name: "EtuiTests", dependencies: ["Etui"]),
    ]
)
