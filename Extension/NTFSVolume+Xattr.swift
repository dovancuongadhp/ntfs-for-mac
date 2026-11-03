import FSKit
import NTFSCore

extension NTFSVolume: FSVolume.XattrOperations {
    func getXattr(named name: FSFileName, of item: FSItem, replyHandler reply: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        guard let item = item as? NTFSItem, let name = name.string else {
            reply(nil, posixError(EINVAL))
            return
        }
        switch perform({ () throws(NTFSError) in try handle.extendedAttribute(name, of: item.id) }) {
        case .success(let value): reply(value, nil)
        case .failure(let error): reply(nil, error)
        }
    }

    func setXattr(
        named name: FSFileName,
        to value: Data?,
        on item: FSItem,
        policy: FSVolume.SetXattrPolicy,
        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        guard let item = item as? NTFSItem, let name = name.string else {
            reply(posixError(EINVAL))
            return
        }
        let result = perform { () throws(NTFSError) in
            try modify { () throws(NTFSError) in
                switch policy {
                case .delete:
                    try handle.removeExtendedAttribute(name, of: item.id)
                case .mustCreate:
                    try handle.setExtendedAttribute(name, to: value ?? Data(), of: item.id, mode: .create)
                case .mustReplace:
                    try handle.setExtendedAttribute(name, to: value ?? Data(), of: item.id, mode: .replace)
                default:
                    try handle.setExtendedAttribute(name, to: value ?? Data(), of: item.id)
                }
            }
        }
        reply(result.error)
    }

    func listXattrs(of item: FSItem, replyHandler reply: @escaping @Sendable ([FSFileName]?, (any Error)?) -> Void) {
        guard let item = item as? NTFSItem else {
            reply(nil, posixError(EINVAL))
            return
        }
        switch perform({ () throws(NTFSError) in try handle.extendedAttributeNames(of: item.id) }) {
        case .success(let names): reply(names.map { FSFileName(string: $0) }, nil)
        case .failure(let error): reply(nil, error)
        }
    }
}
