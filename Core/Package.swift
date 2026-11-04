// swift-tools-version: 6.2
import PackageDescription

// Vendored ntfs-3g sources are compiled as-is; their warnings are not ours.
let vendorCSettings: [CSetting] = [
    .define("HAVE_CONFIG_H"),
    .headerSearchPath("config"),
    .headerSearchPath("ntfs-3g"),
    .unsafeFlags(["-w", "-UDEBUG"]),
]

let package = Package(
    name: "NTFSCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NTFSCore", targets: ["NTFSCore"]),
        .library(name: "NTFSProbe", targets: ["NTFSProbe"]),
        .library(name: "NTFSShared", targets: ["NTFSShared"]),
        .library(name: "NTFSFormat", targets: ["NTFSFormat"]),
        .library(name: "NTFSTransfer", targets: ["NTFSTransfer"]),
        .executable(name: "ntfs-mkfs", targets: ["ntfs-mkfs"]),
        .executable(name: "ntfs-format", targets: ["ntfs-format"]),
    ],
    dependencies: [
        .package(path: "Packages/NTFSDiskOpen"),
    ],
    targets: [
        .target(
            name: "CNTFS",
            path: "Sources/CNTFS",
            exclude: [
                "libntfs-3g/win32_io.c",
                "libntfs-3g/Makefile.am",
                "libntfs-3g/libntfs-3g.pc.in",
                "libntfs-3g/libntfs-3g.script.so.in",
                "ntfs-3g",
                "config",
            ],
            sources: ["libntfs-3g", "bridge"],
            publicHeadersPath: "include",
            cSettings: vendorCSettings
        ),
        .executableTarget(
            name: "ntfs-mkfs",
            dependencies: [
                "CNTFS",
                .product(name: "NTFSDiskOpen", package: "NTFSDiskOpen"),
            ],
            path: "Sources/ntfs-mkfs",
            exclude: ["ntfs-3g", "config"],
            cSettings: vendorCSettings,
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        ),
        .target(name: "NTFSProbe"),
        .target(name: "NTFSShared"),
        .target(name: "NTFSCore", dependencies: ["CNTFS", "NTFSProbe", "NTFSShared"]),
        .target(name: "NTFSFormat"),
        .target(name: "NTFSTransfer"),
        .testTarget(name: "NTFSTransferTests", dependencies: ["NTFSTransfer"]),
        .target(
            name: "NTFSAuthOpen",
            path: "Sources/NTFSAuthOpen",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(name: "ntfs-format", dependencies: ["NTFSFormat", "NTFSAuthOpen"]),
        .testTarget(
            name: "NTFSCoreTests",
            dependencies: ["NTFSCore", "NTFSProbe", "NTFSShared", "NTFSFormat", "ntfs-mkfs"]
        ),
    ]
)
