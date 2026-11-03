import FSKit
import NTFSCore
import NTFSProbe
import notify
import os

let extensionLog = Logger(subsystem: Identifiers.extensionBundleID, category: "fs")

final class NTFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations,
    FSManageableResourceMaintenanceOperations, @unchecked Sendable
{
    private let lock = NSLock()
    private var volume: NTFSVolume?

    func didFinishLoading() {
        NTFSVolumeHandle.setLogHandler { isError, message in
            guard let message else { return }
            let text = String(cString: message)
            if isError != 0 {
                extensionLog.error("ntfs-3g: \(text, privacy: .public)")
            } else {
                extensionLog.debug("ntfs-3g: \(text, privacy: .public)")
            }
        }
    }

    func probeResource(
        resource: FSResource,
        replyHandler reply: @escaping @Sendable (FSProbeResult?, (any Error)?) -> Void
    ) {
        guard let resource = resource as? FSBlockDeviceResource else {
            reply(.notRecognized, nil)
            return
        }
        let device = FSBlockDeviceAdapter(resource)
        guard case .ntfs(let serial) = Self.classifyBootSector(of: device) else {
            reply(.notRecognized, nil)
            return
        }
        // Reading the label means mounting read-only; a volume that won't even
        // do that is still ours to report, just without a name.
        let label = (try? NTFSVolumeHandle(device: device, readOnly: true))?.label ?? ""
        let containerID = FSContainerIdentifier(uuid: UUID(ntfsSerialNumber: serial))
        reply(.usable(name: label, containerID: containerID), nil)
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping @Sendable (FSVolume?, (any Error)?) -> Void
    ) {
        guard let resource = resource as? FSBlockDeviceResource else {
            reply(nil, posixError(ENODEV))
            return
        }
        let readOnly = MountOptions.requestsReadOnly(options.taskOptions)
        let handle: NTFSVolumeHandle
        do throws(NTFSMountError) {
            handle = try NTFSVolumeHandle(device: FSBlockDeviceAdapter(resource), readOnly: readOnly)
        } catch {
            extensionLog.error("Cannot load \(resource.bsdName, privacy: .public): \(String(describing: error), privacy: .public)")
            containerStatus = .notReady(status: fileSystemError(error))
            reply(nil, fileSystemError(error))
            return
        }

        if let reason = handle.readOnlyReason {
            extensionLog.notice("\(resource.bsdName, privacy: .public) mounted read-only: \(reason.rawValue, privacy: .public)")
            if reason != .requested {
                ReadOnlyNotifier.post(reason)
            }
        }

        let volume = NTFSVolume(handle: handle, uuid: UUID(ntfsSerialNumber: handle.serialNumber))
        lock.withLock { self.volume = volume }
        containerStatus = .ready
        reply(volume, nil)
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        let volume = lock.withLock {
            defer { self.volume = nil }
            return self.volume
        }
        volume?.close()
        containerStatus = .notReady(status: posixError(ENOTCONN))
        reply(nil)
    }

    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        // Repairs are left to Windows' chkdsk. Volumes that need one are
        // detected at load time and mounted read-only instead.
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        DispatchQueue.global().async {
            task.didComplete(error: nil)
        }
        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw posixError(ENOTSUP)
    }

    private static func classifyBootSector(of device: FSBlockDeviceAdapter) -> BootSectorKind {
        var sector = [UInt8](repeating: 0, count: max(Int(device.sectorSize), BootSector.size))
        let count = (try? sector.withUnsafeMutableBytes { try device.read(into: $0, at: 0) }) ?? 0
        guard count >= BootSector.size else { return .other }
        return BootSector.classify(sector)
    }
}

enum ReadOnlyNotifier {
    static func post(_ reason: ReadOnlyReason) {
        notify_post(reason.notificationName)
    }
}
