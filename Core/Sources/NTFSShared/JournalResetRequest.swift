import Foundation
import notify

/// The app's consent, while it mounts one disk, for the extension to discard
/// that volume's unclean journal. FSKit doesn't forward custom mount options,
/// so the request travels as Darwin notification state keyed by BSD name.
public final class JournalResetRequest: @unchecked Sendable {
    private var token: Int32 = NOTIFY_TOKEN_INVALID

    /// notifyd keeps the state only while a client is registered, so the
    /// request lasts until `cancel()` or deinit.
    public init(bsdName: String) {
        guard notify_register_check(Self.name(bsdName), &token) == NOTIFY_STATUS_OK else {
            token = NOTIFY_TOKEN_INVALID
            return
        }
        notify_set_state(token, 1)
    }

    deinit {
        cancel()
    }

    public func cancel() {
        guard token != NOTIFY_TOKEN_INVALID else { return }
        notify_set_state(token, 0)
        notify_cancel(token)
        token = NOTIFY_TOKEN_INVALID
    }

    public static func isRequested(for bsdName: String) -> Bool {
        var token: Int32 = 0
        guard notify_register_check(name(bsdName), &token) == NOTIFY_STATUS_OK else { return false }
        defer { notify_cancel(token) }
        var state: UInt64 = 0
        return notify_get_state(token, &state) == NOTIFY_STATUS_OK && state == 1
    }

    private static func name(_ bsdName: String) -> String {
        Identifiers.resetJournalNotificationPrefix + bsdName
    }
}
