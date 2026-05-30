import Foundation
import XCTest
@testable import XPC_UI

final class TargetPreflightServiceTests: XCTestCase {
    func testApplicationBundleResolvesExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let application = root.appendingPathComponent("Fixture.app")
        let macOS = application.appendingPathComponent("Contents/MacOS")
        let executable = macOS.appendingPathComponent("Fixture")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleExecutable</key>
                <string>Fixture</string>
                <key>CFBundleIdentifier</key>
                <string>com.jonluca.xpcui.test-fixture</string>
                <key>CFBundlePackageType</key>
                <string>APPL</string>
            </dict>
            </plist>
            """.utf8
        ).write(to: application.appendingPathComponent("Contents/Info.plist"))

        let preflight = TargetPreflightService.inspect(
            url: application,
            tracerURL: nil,
            deepCaptureEnabled: false
        )

        XCTAssertTrue(preflight.canLaunch)
        XCTAssertEqual(preflight.targetKind, .application)
        XCTAssertEqual(preflight.executableURL?.standardizedFileURL.path, executable.standardizedFileURL.path)
    }

    func testMissingExecutableBlocksLaunch() {
        let preflight = TargetPreflightService.inspect(
            url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            tracerURL: nil,
            deepCaptureEnabled: true
        )

        XCTAssertFalse(preflight.canLaunch)
        XCTAssertEqual(preflight.checks.first { $0.id == "target" }?.level, .unavailable)
    }

    func testProtectedSystemExecutableLaunchesWithReportedBlindSpots() {
        let preflight = TargetPreflightService.inspect(
            url: URL(fileURLWithPath: "/bin/echo"),
            tracerURL: nil,
            deepCaptureEnabled: true
        )

        XCTAssertTrue(preflight.canLaunch)
        XCTAssertEqual(preflight.targetKind, .executable)
        XCTAssertEqual(preflight.checks.first { $0.id == "protected-target" }?.level, .limited)
        XCTAssertEqual(preflight.checks.first { $0.id == "injection" }?.level, .limited)
        XCTAssertFalse(preflight.shouldInjectTracer)
    }

    func testArchitectureCheckReportsMatchingUniversalTracer() {
        let check = TargetPreflightService.architectureCheck(
            targetArchitectures: ["arm64", "x86_64"],
            tracerArchitectures: ["arm64", "x86_64"],
            deepCaptureEnabled: true
        )

        XCTAssertEqual(check.level, .available)
    }

    func testArchitectureCheckReportsMissingTracerSlice() {
        let check = TargetPreflightService.architectureCheck(
            targetArchitectures: ["arm64"],
            tracerArchitectures: ["x86_64"],
            deepCaptureEnabled: true
        )

        XCTAssertEqual(check.level, .limited)
        XCTAssertTrue(check.detail.contains("reduced visibility"))
    }
}
