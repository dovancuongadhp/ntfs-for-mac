// swift-tools-version: 6.2
import PackageDescription

// Separate dynamic library so dyld will interpose open() inside ntfs-mkfs.
// An interpose tuple does not apply to the image that contains it.
let package = Package(
    name: "NTFSDiskOpen",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NTFSDiskOpen", type: .dynamic, targets: ["NTFSDiskOpen"]),
    ],
    targets: [
        .target(
            name: "NTFSDiskOpen",
            path: "Sources",
            publicHeadersPath: ".",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-install_name", "-Xlinker", "@executable_path/libNTFSDiskOpen.dylib",
                ])
            ]
        ),
    ]
)
