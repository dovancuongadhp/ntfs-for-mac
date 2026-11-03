import NTFSCore
import Testing

struct DirectorySnapshotTests {
    let snapshot = DirectorySnapshot(
        entries: [
            DirectoryEntry(name: "a", id: 64, type: .file),
            DirectoryEntry(name: "b", id: 65, type: .directory),
        ],
        verifier: 7
    )

    @Test func dotsComeFirstWhenRequested() {
        #expect(snapshot.slot(at: 0, includeDots: true) == .current)
        #expect(snapshot.slot(at: 1, includeDots: true) == .parent)
        #expect(snapshot.slot(at: 2, includeDots: true) == .entry(snapshot.entries[0]))
        #expect(snapshot.slot(at: 3, includeDots: true) == .entry(snapshot.entries[1]))
        #expect(snapshot.slot(at: 4, includeDots: true) == nil)
    }

    @Test func entriesStartAtZeroWithoutDots() {
        #expect(snapshot.slot(at: 0, includeDots: false) == .entry(snapshot.entries[0]))
        #expect(snapshot.slot(at: 1, includeDots: false) == .entry(snapshot.entries[1]))
        #expect(snapshot.slot(at: 2, includeDots: false) == nil)
        #expect(snapshot.slot(at: .max, includeDots: false) == nil)
    }
}
