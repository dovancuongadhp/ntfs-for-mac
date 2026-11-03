import FSKit

@main
struct NTFSExtensionMain: UnaryFileSystemExtension {
    let fileSystem = NTFSFileSystem()
}
