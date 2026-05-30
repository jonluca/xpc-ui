import XCTest
@testable import XPC_UI

final class KernelTraceServiceTests: XCTestCase {
    func testScriptFiltersBothProvidersToTargetPID() {
        let script = KernelTraceService.script(pid: 42, categories: [.syscall, .machTrap])
        XCTAssertTrue(script.contains("syscall:::entry"))
        XCTAssertTrue(script.contains("mach_trap:::return"))
        XCTAssertEqual(script.components(separatedBy: "/pid == 42/").count - 1, 4)
    }

    func testDecoderCreatesSharedCaptureEnvelope() {
        let event = KernelTraceEventDecoder().decode(
            line: "syscall\tentry\topen\t42\t7",
            sessionID: "test-session"
        )

        XCTAssertEqual(event?.sessionID, "test-session")
        XCTAssertEqual(event?.source, "dtrace")
        XCTAssertEqual(event?.category, "syscall")
        XCTAssertEqual(event?.direction, "entry")
        XCTAssertEqual(event?.operation, "open")
        XCTAssertEqual(event?.pid, 42)
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
