// swift-tools-version: 6.0
import PackageDescription

var targets: [Target] = []
var bridgeDependencies: [Target.Dependency] = []
#if os(Linux)
targets += [
    .systemLibrary(name: "CQt6", pkgConfig: "Qt6Widgets", providers: [.apt(["qt6-base-dev"])]),
    .systemLibrary(name: "CGStreamer", pkgConfig: "gstreamer-app-1.0", providers: [.apt(["libgstreamer-plugins-base1.0-dev"])]),
    .systemLibrary(name: "CGStreamerVideo", pkgConfig: "gstreamer-video-1.0")
]
bridgeDependencies = ["CQt6", "CGStreamer", "CGStreamerVideo"]
#endif
targets += [
    .target(name: "CLinuxBridge", dependencies: bridgeDependencies,
            cxxSettings: [.define("QT_NO_KEYWORDS")],
            linkerSettings: [.linkedLibrary("m")]),
    .executableTarget(name: "ParrotLabLinux", dependencies: ["CLinuxBridge"],
                      swiftSettings: [.swiftLanguageMode(.v5)],
                      linkerSettings: [
                        // Ubuntu's Swift/binutils defaults otherwise produce an RWX LOAD segment.
                        .unsafeFlags(["-Xlinker", "-z", "-Xlinker", "separate-code",
                                      "-Xlinker", "-z", "-Xlinker", "relro",
                                      "-Xlinker", "-z", "-Xlinker", "now"], .when(platforms: [.linux]))
                      ]),
    .testTarget(name: "ParrotLabLinuxTests", dependencies: ["ParrotLabLinux"])
]
let package = Package(name: "ParrotLabLinux", platforms: [.macOS(.v13)],
    products: [.executable(name: "parrot-lab", targets: ["ParrotLabLinux"])], targets: targets,
    cxxLanguageStandard: .cxx17)
