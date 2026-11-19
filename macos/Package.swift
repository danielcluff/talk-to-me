// swift-tools-version:5.10
// The macOS menu bar app. Build it with `zig build app` (see build-app.sh),
// which first builds libtalk.a and the engine archive into ../zig-out/lib.
import PackageDescription

let zigOut = Context.packageDirectory + "/../zig-out/lib"

let package = Package(
    name: "TalkToMe",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CTalk", path: "Sources/CTalk"),
        .executableTarget(
            name: "TalkToMe",
            dependencies: ["CTalk"],
            path: "Sources/TalkToMe",
            linkerSettings: [
                .unsafeFlags(["-L", zigOut]),
                .linkedLibrary("talk"),
                .linkedLibrary("talk_engine_all"),
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
