import FSKit
import NTFSCore

extension NTFSVolume: FSVolume.Operations {
    // MARK: Capabilities

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsPersistentObjectIDs = true
        capabilities.supportsSymbolicLinks = true
        capabilities.supportsHardLinks = false
        capabilities.supportsJournal = true
        capabilities.supportsActiveJournal = false
        capabilities.supportsSparseFiles = true
        capabilities.supportsZeroRuns = true
        capabilities.supportsFastStatFS = true
        capabilities.supports2TBFiles = true
        capabilities.supportsHiddenFiles = true
        capabilities.supports64BitObjectIDs = true
        capabilities.doesNotSupportSettingFilePermissions = true
        capabilities.caseFormat = .insensitiveCasePreserving
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: Identifiers.fileSystemTypeName)
        guard case .success(let statistics) = perform({ () throws(NTFSError) in try handle.statistics() }) else {
            return result
        }
        let clusterSize = UInt64(statistics.clusterSize)
        result.blockSize = Int(clusterSize)
        result.ioSize = 1 << 20
        result.totalBlocks = statistics.totalClusters
        result.freeBlocks = statistics.freeClusters
        result.availableBlocks = statistics.freeClusters
        result.usedBlocks = statistics.totalClusters - statistics.freeClusters
        result.totalBytes = statistics.totalBytes
        result.freeBytes = statistics.freeBytes
        result.availableBytes = statistics.freeBytes
        result.usedBytes = statistics.totalBytes - statistics.freeBytes
        result.totalFiles = statistics.totalFiles
        result.freeFiles = statistics.freeFiles
        return result
    }

    var enableOpenUnlinkEmulation: Bool { true }

    @available(macOS 26.4, *)
    var requestedMountOptions: FSVolume.MountOptions {
        handle.isReadOnly ? .readOnly : []
    }

    // MARK: PathConf

    var maximumLinkCount: Int { 1024 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { UInt64(Int64.max) }
    /// Extended attributes are alternate data streams, which can be as large as files.
    var maximumXattrSize: Int { Int(Int32.max) }

    // MARK: Life cycle

    func activate(options: FSTaskOptions, replyHandler reply: @escaping @Sendable (FSItem?, (any Error)?) -> Void) {
        reply(root, nil)
    }

    func deactivate(options: FSDeactivateOptions = [], replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping @Sendable () -> Void) {
        _ = perform { () throws(NTFSError) in try handle.sync() }
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(perform { () throws(NTFSError) in try handle.sync() }.error)
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        guard let item = item as? NTFSItem else {
            reply(nil)
            return
        }
        _ = perform {
            if #available(macOS 27.0, *) {
                _ = item.tryReclaim { self.forget(item) }
            } else {
                forget(item)
            }
        }
        reply(nil)
    }

    // MARK: Names

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard let directory = directory as? NTFSItem, let string = name.string else {
            reply(nil, nil, posixError(ENOENT))
            return
        }
        let result = perform { () throws(NTFSError) -> NTFSItem in
            switch string {
            case ".": return directory
            case "..": return item(for: directory.parent, parent: directory.parent)
            default:
                let id = try handle.lookup(string, in: directory.id)
                return item(for: id, parent: directory.id)
            }
        }
        switch result {
        case .success(let item): reply(item, name, nil)
        case .failure(let error): reply(nil, nil, error)
        }
    }

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard let directory = directory as? NTFSItem, let string = name.string else {
            reply(nil, nil, posixError(EINVAL))
            return
        }
        let itemType: ItemType
        switch type {
        case .file: itemType = .file
        case .directory: itemType = .directory
        default:
            reply(nil, nil, posixError(ENOTSUP))
            return
        }
        let result = perform { () throws(NTFSError) -> NTFSItem in
            let id = try modify { () throws(NTFSError) in try handle.create(string, in: directory.id, type: itemType) }
            directoryChanged(directory.id)
            let item = item(for: id, parent: directory.id)
            try apply(newAttributes, to: item, type: itemType)
            return item
        }
        switch result {
        case .success(let item): reply(item, name, nil)
        case .failure(let error): reply(nil, nil, error)
        }
    }

    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName,
        replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        reply(nil, nil, posixError(ENOTSUP))
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void
    ) {
        reply(nil, posixError(ENOTSUP))
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem,
        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        guard let directory = directory as? NTFSItem, let string = name.string else {
            reply(posixError(EINVAL))
            return
        }
        let result = perform { () throws(NTFSError) in
            try modify { () throws(NTFSError) in try handle.remove(string, in: directory.id) }
            directoryChanged(directory.id)
            if let directoryItem = item as? NTFSItem {
                directoryChanged(directoryItem.id)
            }
        }
        reply(result.error)
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void
    ) {
        guard let item = item as? NTFSItem,
              let source = sourceDirectory as? NTFSItem,
              let destination = destinationDirectory as? NTFSItem,
              let from = sourceName.string,
              let to = destinationName.string
        else {
            reply(nil, posixError(EINVAL))
            return
        }
        let result = perform { () throws(NTFSError) in
            try modify { () throws(NTFSError) in try handle.rename(from, in: source.id, to: to, in: destination.id) }
            directoryChanged(source.id)
            directoryChanged(destination.id)
            item.parent = destination.id
        }
        switch result {
        case .success: reply(destinationName, nil)
        case .failure(let error): reply(nil, error)
        }
    }

    func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void) {
        guard let item = item as? NTFSItem else {
            reply(nil, posixError(EINVAL))
            return
        }
        switch perform({ () throws(NTFSError) in try handle.readLink(item.id) }) {
        case .success(let target): reply(FSFileName(string: target), nil)
        case .failure(let error): reply(nil, error)
        }
    }

    // MARK: Attributes

    func getAttributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem,
        replyHandler reply: @escaping @Sendable (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        guard let item = item as? NTFSItem else {
            reply(nil, posixError(EINVAL))
            return
        }
        switch perform({ () throws(NTFSError) in try fileSystemAttributes(of: item) }) {
        case .success(let attributes): reply(attributes, nil)
        case .failure(let error): reply(nil, error)
        }
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem,
        replyHandler reply: @escaping @Sendable (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        guard let item = item as? NTFSItem else {
            reply(nil, posixError(EINVAL))
            return
        }
        let result = perform { () throws(NTFSError) -> FSItem.Attributes in
            let current = try handle.attributes(of: item.id)
            try apply(newAttributes, to: item, type: current.type, current: current)
            return try fileSystemAttributes(of: item)
        }
        switch result {
        case .success(let attributes): reply(attributes, nil)
        case .failure(let error): reply(nil, error)
        }
    }

    /// Applies the subset of `request` that NTFS can store and records what
    /// was used in `consumedAttributes`. Call only from inside `perform`.
    private func apply(
        _ request: FSItem.SetAttributesRequest,
        to item: NTFSItem,
        type: ItemType,
        current: ItemAttributes? = nil
    ) throws(NTFSError) {
        var consumed: FSItem.Attribute = []

        if request.isValid(.size) {
            if type == .file {
                try modify { () throws(NTFSError) in try handle.truncate(item.id, to: request.size) }
            }
            consumed.insert(.size)
        }

        let access = request.isValid(.accessTime) ? request.accessTime : nil
        let modify = request.isValid(.modifyTime) ? request.modifyTime : nil
        let birth = request.isValid(.birthTime) ? request.birthTime : nil
        if access != nil || modify != nil || birth != nil {
            try self.modify { () throws(NTFSError) in
                try handle.setTimes(item.id, access: access, modify: modify, birth: birth)
            }
            if access != nil { consumed.insert(.accessTime) }
            if modify != nil { consumed.insert(.modifyTime) }
            if birth != nil { consumed.insert(.birthTime) }
        }

        if request.isValid(.flags) {
            let hidden = request.flags & UInt32(UF_HIDDEN) != 0
            let locked = request.flags & UInt32(UF_IMMUTABLE) != 0
            let flags = current?.flags ?? []
            let shownHidden = !flags.isDisjoint(with: [.hidden, .system])
            if hidden != shownHidden {
                try self.modify { () throws(NTFSError) in try handle.setFlags(.hidden, on: hidden, for: item.id) }
            }
            if type == .file, locked != flags.contains(.readOnly) {
                try self.modify { () throws(NTFSError) in try handle.setFlags(.readOnly, on: locked, for: item.id) }
            }
            consumed.insert(.flags)
        }

        request.consumedAttributes = consumed
    }

    // MARK: Directories

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        replyHandler reply: @escaping @Sendable (FSDirectoryVerifier, (any Error)?) -> Void
    ) {
        guard let directory = directory as? NTFSItem else {
            reply(verifier, posixError(ENOTDIR))
            return
        }
        let includeDots = attributes == nil
        let result = perform { () throws(NTFSError) -> FSDirectoryVerifier in
            let snapshot = try snapshot(
                of: directory.id,
                verifier: verifier.rawValue,
                restart: cookie == .initial
            )
            var position = cookie.rawValue
            while let slot = snapshot.slot(at: position, includeDots: includeDots) {
                let next = FSDirectoryCookie(position + 1)
                let packed: Bool
                switch slot {
                case .current:
                    packed = packer.packEntry(
                        name: FSFileName(string: "."), itemType: .directory,
                        itemID: FSItem.Identifier(directory.id), nextCookie: next, attributes: nil)
                case .parent:
                    packed = packer.packEntry(
                        name: FSFileName(string: ".."), itemType: .directory,
                        itemID: FSItem.Identifier(directory.parent), nextCookie: next, attributes: nil)
                case .entry(let entry):
                    let entryAttributes = attributes == nil
                        ? nil
                        : fileSystemAttributes(try handle.attributes(of: entry.id), parent: directory.id)
                    packed = packer.packEntry(
                        name: FSFileName(string: entry.name), itemType: entry.type.fileSystemType,
                        itemID: FSItem.Identifier(entry.id), nextCookie: next, attributes: entryAttributes)
                }
                guard packed else {
                    return FSDirectoryVerifier(snapshot.verifier)
                }
                position += 1
            }
            finishedEnumerating(directory.id)
            return FSDirectoryVerifier(snapshot.verifier)
        }
        switch result {
        case .success(let newVerifier): reply(newVerifier, nil)
        case .failure(let error): reply(verifier, error)
        }
    }
}

extension NTFSVolume: FSVolume.RenameOperations {
    func setVolumeName(_ name: FSFileName, replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void) {
        guard let label = name.string else {
            reply(nil, posixError(EINVAL))
            return
        }
        let result = perform { () throws(NTFSError) in
            try modify { () throws(NTFSError) in try handle.setLabel(label) }
        }
        switch result {
        case .success:
            self.name = name
            reply(name, nil)
        case .failure(let error):
            reply(nil, error)
        }
    }
}

extension Result {
    var error: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
