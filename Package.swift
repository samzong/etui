// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Launcher",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Launcher",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"]),
            ]
        ),
        .systemLibrary(name: "CRime"),
        .executableTarget(name: "Pinyin", dependencies: ["CRime"]),
        .testTarget(name: "LauncherTests", dependencies: ["Launcher"]),
    ]
)
