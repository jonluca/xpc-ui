import Foundation
import XCTest
@testable import XPC_UI

final class ProcessTreeServiceTests: XCTestCase {
    func testDiscoveryIncludesRootAndChildProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["3"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }

        let processes = ProcessTreeService.discoverDirectly(rootPID: getpid())

        XCTAssertTrue(processes.contains { $0.pid == getpid() })
        XCTAssertTrue(
            processes.contains {
                $0.pid == child.processIdentifier && $0.parentPID == getpid()
            }
        )
    }
}
