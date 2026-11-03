/// Names shared by the app and the file system extension.
public enum Identifiers {
    public static let appBundleID = "com.docuong.ntfsformac"
    public static let extensionBundleID = "com.docuong.ntfsformac.fsmodule"
    /// `FSShortName` of the extension, as used by `mount -F -t`.
    public static let fileSystemShortName = "ntfsrw"
    /// File system type reported by `statfs` for volumes this extension
    /// mounts. Differs from Apple's read-only driver, which reports "ntfs".
    public static let fileSystemTypeName = "ntfsrw"
    /// `statfs` type of volumes mounted by Apple's built-in read-only driver.
    public static let systemDriverTypeName = "ntfs"
    public static let readOnlyNotificationPrefix = "com.docuong.ntfsformac.readonly."
}
