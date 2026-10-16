// swift-tools-version:5.10
import PackageDescription
import Foundation

/// A prefix that was named explicitly must exist, or the build stops here.
///
/// `-L/some/missing/dir` is not an error to the linker. It searches the default paths
/// instead, finds whatever Homebrew happens to be carrying, links it, and prints
/// "Build complete!". That is the worst possible failure direction: the build looks
/// clean and the binary is wrong.
///
/// Found 2026-09-12. A build typed with `libraw-0.21.4` instead of the real
/// `libraw-0.21.4-x86` linked Homebrew's LibRaw 0.22.2, and every one of 114 real
/// frames died with "LibRaw returned an unexpected image: bits 8 colors 3". Nothing
/// about the build said so. An unset prefix still falls back on purpose, because that
/// is a default rather than a typo.
/// Note what this checks and why it is the LIBRARY and not the directory. The first
/// version of this guard tested that `<prefix>/lib` existed, injected the real typo,
/// and printed "Build complete!" anyway. `~/build/deps/libraw-0.21.4/lib` is a real
/// directory left behind by an aborted build, holding one Makefile and no dylib. A
/// guard that cannot tell that apart from a working install is not a guard.
func requirePrefix(_ variable: String, default fallback: String, mustHold library: String) -> String {
    guard let named = Context.environment[variable] else { return fallback }
    let path = named + "/lib/" + library
    guard FileManager.default.fileExists(atPath: path) else {
        fatalError("\(variable) is set to \(named) but \(path) is not there. "
                   + "Left alone the linker would silently fall back to the system library. "
                   + "Check the path: the pinned trees carry an architecture suffix, "
                   + "libraw-0.21.4-x86 and libjxl-0.12.0-x86_64, not the bare version.")
    }
    return named
}

// LibRaw is the one external. It is linked in-process, never spawned. Set
// FP_LIBRAW_PREFIX to the pinned self-built tree under ~/build/deps, which carries an
// ARCHITECTURE SUFFIX (`-x86` or `-arm64`). The Homebrew default below is a convenience
// for a machine that has nothing pinned, and is NOT what ships: Homebrew tracks a moving
// version and went to 0.22.2 on 2026-09-11, which this decode path rejects.
let librawPrefix = requirePrefix("FP_LIBRAW_PREFIX", default: "/usr/local/opt/libraw", mustHold: "libraw_r.dylib")
let librawInclude: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I\(librawPrefix)/include"])]
let librawLink: [LinkerSetting] = [
    .unsafeFlags(["-L\(librawPrefix)/lib", "-Xlinker", "-rpath", "-Xlinker", "\(librawPrefix)/lib"]),
    .linkedLibrary("raw_r"),
]

// libjxl is the second external, static, built from source at a pinned release under
// ~/build/deps (FP_LIBJXL_PREFIX names the install for the architecture being built).
// Static so the app bundle carries no extra dylibs; it is C++ inside, hence libc++.
let libjxlPrefix = requirePrefix("FP_LIBJXL_PREFIX", default: "/usr/local/opt/jpeg-xl", mustHold: "libjxl.a")
let externalInclude: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I\(librawPrefix)/include", "-Xcc", "-I\(libjxlPrefix)/include"])]
let externalLink: [LinkerSetting] = librawLink + [
    .unsafeFlags(["-L\(libjxlPrefix)/lib"]),
    .linkedLibrary("jxl"), .linkedLibrary("jxl_cms"), .linkedLibrary("jxl_threads"),
    .linkedLibrary("hwy"), .linkedLibrary("brotlienc"), .linkedLibrary("brotlidec"), .linkedLibrary("brotlicommon"),
    .linkedLibrary("c++"),
]

let package = Package(
    name: "FilmPositive",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FilmPositiveCore", targets: ["FilmPositiveCore"]),
        .executable(name: "FilmPositive", targets: ["FilmPositive"]),
    ],
    dependencies: [
        .package(path: "Vendor/film-sidecar"),
        // Sparkle checks for and installs updates, the one way every app of
        // ours does it. The only dependency from outside the project.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .systemLibrary(name: "CLibRaw", path: "Sources/CLibRaw"),
        .systemLibrary(name: "CLibJXL", path: "Sources/CLibJXL"),
        .target(
            name: "FilmPositiveCore",
            dependencies: ["CLibRaw", "CLibJXL", .product(name: "FilmSidecar", package: "film-sidecar")],
            path: "Sources/FilmPositiveCore",
            resources: [.copy("Resources/profiles")],
            swiftSettings: externalInclude,
            linkerSettings: externalLink
        ),
        .executableTarget(
            name: "FilmPositive",
            dependencies: ["FilmPositiveCore", .product(name: "FilmSidecar", package: "film-sidecar"),
                           .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/FilmPositive",
            swiftSettings: externalInclude,
            linkerSettings: externalLink
        ),
        .testTarget(
            name: "FilmPositiveAppTests",
            dependencies: ["FilmPositive", "FilmPositiveCore", .product(name: "FilmSidecar", package: "film-sidecar")],
            path: "Tests/FilmPositiveAppTests",
            swiftSettings: externalInclude,
            linkerSettings: externalLink
        ),
        .testTarget(
            name: "FilmPositiveCoreTests",
            dependencies: ["FilmPositiveCore", .product(name: "FilmSidecar", package: "film-sidecar")],
            path: "Tests/FilmPositiveCoreTests",
            swiftSettings: externalInclude,
            linkerSettings: externalLink
        ),
    ]
)
