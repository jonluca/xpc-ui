import Foundation
import XCTest
@testable import XPC_UI

final class InterceptionRuleTests: XCTestCase {
    func testConfigurationRoundTripsBoundedRule() throws {
        let rule = InterceptionRule(
            name: "Rewrite fixture role",
            serviceName: "com.jonluca.xpcui.fixture.mach-service",
            direction: .outgoing,
            operation: "send",
            matchKey: "role",
            matchStringValue: "parent",
            replacementKey: "role",
            replacementValue: "intercepted"
        )

        let data = try InterceptionRuleStore.configurationData(rules: [rule])
        let configuration = try PropertyListDecoder().decode(
            InterceptionRuleConfiguration.self,
            from: data
        )

        XCTAssertEqual(configuration.schemaVersion, 2)
        XCTAssertEqual(configuration.rules, [rule])
    }

    func testIncompletePredicateIsRejected() {
        var rule = InterceptionRule()
        rule.matchKey = "role"

        XCTAssertThrowsError(try InterceptionRuleStore.configurationData(rules: [rule])) {
            XCTAssertEqual($0 as? InterceptionRuleValidationError, .incompletePredicate)
        }
    }

    func testNestedTypedReplacementRoundTrips() throws {
        let rule = InterceptionRule(
            matchKey: "nested.transport",
            matchStringValue: "Process",
            replacementKey: "nested.pid",
            replacementType: .int64,
            replacementValue: "4242"
        )

        let configuration = try PropertyListDecoder().decode(
            InterceptionRuleConfiguration.self,
            from: InterceptionRuleStore.configurationData(rules: [rule])
        )

        XCTAssertEqual(configuration.rules, [rule])
    }

    func testLegacyStringReplacementDecodes() throws {
        let id = UUID()
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "id": id.uuidString,
                "name": "Legacy",
                "enabled": true,
                "serviceName": "com.example.service",
                "direction": "outgoing",
                "operation": "send",
                "matchKey": "",
                "matchStringValue": "",
                "replacementKey": "key",
                "replacementStringValue": "legacy-value",
            ],
            format: .binary,
            options: 0
        )

        let rule = try PropertyListDecoder().decode(InterceptionRule.self, from: data)

        XCTAssertEqual(rule.replacementType, .string)
        XCTAssertEqual(rule.replacementValue, "legacy-value")
    }

    func testInvalidNestedKeyPathIsRejected() {
        var rule = InterceptionRule()
        rule.replacementKey = "nested..pid"

        XCTAssertThrowsError(try InterceptionRuleStore.configurationData(rules: [rule])) {
            XCTAssertEqual($0 as? InterceptionRuleValidationError, .invalidKeyPath)
        }
    }

    func testInvalidTypedReplacementIsRejected() {
        var rule = InterceptionRule()
        rule.replacementType = .int64
        rule.replacementValue = "not-a-number"

        XCTAssertThrowsError(try InterceptionRuleStore.configurationData(rules: [rule])) {
            XCTAssertEqual(
                $0 as? InterceptionRuleValidationError,
                .invalidReplacementValue(type: .int64)
            )
        }
    }

    func testPreparedRuleUsesCapturedCallAndNestedStringPayload() throws {
        let event = makeCapturedCall(
            payload: .object([
                "type": .string("dictionary"),
                "value": .object([
                    "nested": .object([
                        "type": .string("dictionary"),
                        "value": .object([
                            "role": .object([
                                "type": .string("string"),
                                "value": .string("parent"),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        )

        let rule = try XCTUnwrap(InterceptionRule.prepared(from: event))

        XCTAssertFalse(rule.enabled)
        XCTAssertEqual(rule.name, "Intercept send-with-reply")
        XCTAssertEqual(rule.serviceName, "com.example.fixture")
        XCTAssertEqual(rule.direction, .outgoing)
        XCTAssertEqual(rule.operation, "send-with-reply")
        XCTAssertEqual(rule.matchKey, "nested.role")
        XCTAssertEqual(rule.matchStringValue, "parent")
        XCTAssertEqual(rule.replacementKey, "nested.role")
        XCTAssertEqual(rule.replacementType, .string)
        XCTAssertEqual(rule.replacementValue, "parent")
        XCTAssertNoThrow(try InterceptionRuleStore.validate(rule))
    }

    func testPreparedRuleFallsBackToEditableReplacementForLazyPayload() throws {
        let event = makeCapturedCall(
            direction: "incoming",
            operation: "reply",
            payload: .object([
                "type": .string("lazy-json"),
                "encoding": .string("json"),
                "blobReference": .string("payload.json"),
            ])
        )

        let rule = try XCTUnwrap(InterceptionRule.prepared(from: event))

        XCTAssertEqual(rule.direction, .incoming)
        XCTAssertEqual(rule.operation, "reply")
        XCTAssertEqual(rule.replacementKey, "key")
        XCTAssertEqual(rule.replacementValue, "replacement")
        XCTAssertNoThrow(try InterceptionRuleStore.validate(rule))
    }

    func testPreparedRuleRejectsNonDictionaryEvent() {
        let event = makeCapturedCall(
            payload: .object([
                "type": .string("string"),
                "value": .string("not a dictionary"),
            ])
        )

        XCTAssertNil(InterceptionRule.prepared(from: event))
    }

    @MainActor
    func testEnabledStoreWritesPrivateSessionConfiguration() throws {
        let session = try TraceSession.create()
        defer { try? FileManager.default.removeItem(at: session.directoryURL) }
        let store = InterceptionRuleStore()
        try store.add()
        store.enabled = true

        let url = try XCTUnwrap(store.writeConfiguration(to: session.directoryURL))
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )

        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }

    @MainActor
    func testDisabledStoreDoesNotWriteConfiguration() throws {
        let session = try TraceSession.create()
        defer { try? FileManager.default.removeItem(at: session.directoryURL) }

        XCTAssertNil(try InterceptionRuleStore().writeConfiguration(to: session.directoryURL))
    }

    private func makeCapturedCall(
        direction: String = "outgoing",
        operation: String = "send-with-reply",
        payload: JSONValue
    ) -> CaptureEventEnvelope {
        CaptureEventEnvelope(
            schemaVersion: CaptureEventEnvelope.currentSchemaVersion,
            sessionID: "session",
            sequence: 1,
            monotonicTimestamp: 2,
            pid: 42,
            parentPID: 1,
            threadID: 3,
            source: "injected-xpc",
            category: "xpc",
            direction: direction,
            operation: operation,
            serviceName: "com.example.fixture",
            summary: operation,
            payload: payload,
            diagnostics: [],
            droppedEventCount: 0
        )
    }
}
