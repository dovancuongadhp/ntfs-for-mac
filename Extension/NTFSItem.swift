import FSKit
import NTFSCore

/// The FSKit node for one MFT record. `NTFSVolume` keeps exactly one instance
/// per record alive until FSKit reclaims it.
final class NTFSItem: FSItem, @unchecked Sendable {
    let id: ItemID
    /// Directory the item was last looked up in; used for `..` and `parentID`.
    var parent: ItemID
    var isOpenForWriting = false

    init(id: ItemID, parent: ItemID) {
        self.id = id
        self.parent = parent
        super.init()
    }
}
