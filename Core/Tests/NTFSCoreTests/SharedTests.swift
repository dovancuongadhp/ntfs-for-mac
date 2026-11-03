import Foundation
import NTFSShared
import Testing

struct MountOptionsTests {
    @Test(arguments: [
        ["-r"], ["--rdonly"], ["-o", "rdonly"], ["-o", "nobrowse,ro"], ["-ordonly"],
        ["-f", "-o", "nodev,rdonly,noowners"],
    ])
    func readOnlyArguments(_ arguments: [String]) {
        #expect(MountOptions.requestsReadOnly(arguments))
    }

    @Test(arguments: [
        [], ["-f"], ["-o", "nobrowse"], ["-o", "rdonly,rw"], ["-o", "rw"], ["-o", "noowners"],
    ])
    func writableArguments(_ arguments: [String]) {
        #expect(!MountOptions.requestsReadOnly(arguments))
    }
}

struct JournalResetRequestTests {
    @Test func visibleOnlyWhileHeld() {
        let bsdName = "test\(UInt32.random(in: 0...UInt32.max))"
        #expect(!JournalResetRequest.isRequested(for: bsdName))
        do {
            let request = JournalResetRequest(bsdName: bsdName)
            #expect(JournalResetRequest.isRequested(for: bsdName))
            #expect(!JournalResetRequest.isRequested(for: bsdName + "x"))
            request.cancel()
        }
        #expect(!JournalResetRequest.isRequested(for: bsdName))
    }
}

struct VolumeUUIDTests {
    @Test func stableAndDistinct() {
        let a = UUID(ntfsSerialNumber: 0x1234_5678_9ABC_DEF0)
        #expect(a == UUID(ntfsSerialNumber: 0x1234_5678_9ABC_DEF0))
        #expect(a != UUID(ntfsSerialNumber: 0x1234_5678_9ABC_DEF1))
        #expect(a.uuidString.hasPrefix("F0DEBC9A-7856-8412-"))
    }
}

struct ReadOnlyReasonTests {
    @Test func notificationNamesRoundTrip() {
        for reason in ReadOnlyReason.allCases {
            #expect(reason.notificationName.hasPrefix("com.docuong.ntfsformac.readonly."))
            #expect(ReadOnlyReason(notificationName: reason.notificationName) == reason)
        }
        #expect(ReadOnlyReason(notificationName: "com.apple.something") == nil)
    }
}
