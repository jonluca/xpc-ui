import XCTest
@testable import XPC_UI

final class KernelTraceServiceTests: XCTestCase {
    func testScriptFiltersBothProvidersToTrackedPIDs() {
        let script = KernelTraceService.script(pids: [42, 84], categories: [.syscall, .machTrap])
        XCTAssertTrue(script.contains("syscall:::entry"))
        XCTAssertTrue(script.contains("mach_trap:::return"))
        XCTAssertEqual(script.components(separatedBy: "/pid == 42 || pid == 84/").count - 1, 4)
        XCTAssertTrue(script.contains("probefunc, pid, ppid, tid"))
    }

    func testDecoderCreatesSharedCaptureEnvelope() {
        let event = KernelTraceEventDecoder().decode(
            line: "syscall\tentry\topen\t42\t1\t7",
            sessionID: "test-session"
        )

        XCTAssertEqual(event?.sessionID, "test-session")
        XCTAssertEqual(event?.source, "dtrace")
        XCTAssertEqual(event?.category, "syscall")
        XCTAssertEqual(event?.direction, "entry")
        XCTAssertEqual(event?.operation, "open")
        XCTAssertEqual(event?.pid, 42)
        XCTAssertEqual(event?.parentPID, 1)
        XCTAssertEqual(event?.threadID, 7)
    }

    func testDecoderIgnoresDTraceDiagnostics() {
        XCTAssertNil(
            KernelTraceEventDecoder().decode(
                line: "dtrace: failed to initialize dtrace: DTrace requires additional privileges",
                sessionID: "test-session"
            )
        )
    }
}
