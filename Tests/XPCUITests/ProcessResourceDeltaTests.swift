import XCTest
@testable import XPC_UI

final class ProcessResourceDeltaTests: XCTestCase {
    func testMachPortRightsDescribeKnownBitsWithoutInventingNames() {
        let port = ProcessSnapshot.MachPort(
            name: 0x103,
            typeBits: (1 << 16) | (1 << 17) | (1 << 31),
            userReferences: 2
        )

        XCTAssertEqual(port.rightsText, "send, receive, dead-name request")
    }

    func testDeltaReportsAddedAndRemovedResources() {
        let delta = ProcessResourceDelta.delta(
            previousFileIDs: ["old", "stable"],
            currentFileIDs: ["stable", "new"],
            previousSocketIDs: ["socket-old"],
            currentSocketIDs: ["socket-new"],
            previousMachPortNames: [0x101, 0x202],
            currentMachPortNames: [0x202, 0x303]
        )

        XCTAssertEqual(delta.addedFileIDs, ["new"])
        XCTAssertEqual(delta.removedFileIDs, ["old"])
        XCTAssertEqual(delta.addedSocketIDs, ["socket-new"])
        XCTAssertEqual(delta.removedSocketIDs, ["socket-old"])
        XCTAssertEqual(delta.addedMachPortNames, [0x303])
        XCTAssertEqual(delta.removedMachPortNames, [0x101])
    }

    func testDirectSelfSnapshotIncludesMachPortSpaceMetadata() throws {
        let snapshot = ProcessSnapshotService.snapshotDirectly(pid: getpid())
        let portSpace = try XCTUnwrap(snapshot.machPortSpace)

        XCTAssertGreaterThan(portSpace.tableSize, 0)
        XCTAssertGreaterThanOrEqual(portSpace.tableEntryCount, UInt32(snapshot.machPorts.count))
    }
}
