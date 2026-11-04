import Foundation
import Testing
@testable import NTFSTransfer

@Suite struct TransferFailureTests {
    @Test func outOfSpaceStopsTheWholeTransfer() {
        let failure = TransferFailure.classify(POSIXError(.ENOSPC), reading: false)
        #expect(failure.reason == .noSpace)
        #expect(failure.reason.stopsTransfer)
    }

    @Test func ioErrorWhileReadingMeansADamagedFile() {
        let failure = TransferFailure.classify(POSIXError(.EIO), reading: true)
        #expect(failure.reason == .unreadable)
        #expect(!failure.reason.stopsTransfer)
    }

    @Test func ioErrorWhileWritingIsAWriteFailure() {
        #expect(TransferFailure.classify(POSIXError(.EIO), reading: false).reason == .writeFailed)
    }

    @Test func aMissingDeviceMeansTheDriveWasRemoved() {
        let failure = TransferFailure.classify(POSIXError(.ENXIO), reading: true)
        #expect(failure.reason == .driveRemoved)
        #expect(failure.reason.stopsTransfer)
    }

    @Test func permissionErrors() {
        #expect(TransferFailure.classify(POSIXError(.EACCES), reading: true).reason == .permissionDenied)
        #expect(TransferFailure.classify(POSIXError(.EROFS), reading: false).reason == .permissionDenied)
    }

    @Test func badNamesAreInvalidNames() {
        #expect(TransferFailure.classify(POSIXError(.EILSEQ), reading: false).reason == .invalidName)
        #expect(TransferFailure.classify(POSIXError(.ENAMETOOLONG), reading: false).reason == .invalidName)
    }

    @Test func aMissingSourceFile() {
        #expect(TransferFailure.classify(POSIXError(.ENOENT), reading: true).reason == .sourceMissing)
    }

    @Test func foundationErrorsWrappingPOSIXAreRecognised() {
        let plain = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(TransferFailure.classify(plain, reading: false).reason == .noSpace)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: plain])
        #expect(TransferFailure.classify(wrapped, reading: false).reason == .noSpace)
    }

    @Test func unknownErrorsFallBackByDirection() {
        struct Odd: Error {}
        #expect(TransferFailure.classify(Odd(), reading: true).reason == .unreadable)
        #expect(TransferFailure.classify(Odd(), reading: false).reason == .writeFailed)
    }
}
