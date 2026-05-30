import XCTest
@testable import XPC_UI

final class KernelTraceServiceTests: XCTestCase {
    func testScriptFiltersBothProvidersToTargetPID() {
        let script = KernelTraceService.script(pid: 42, categories: [.syscall, .machTrap])
        XCTAssertTrue(script.contains("syscall:::entry"))
        XCTAssertTrue(script.contains("mach_trap:::return"))
        XCTAssertEqual(script.components(separatedBy: "/pid == 42/").count - 1, 4)
    }
}
