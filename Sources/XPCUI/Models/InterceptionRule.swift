import Foundation

struct InterceptionRule: Codable, Equatable, Identifiable, Sendable {
    enum Direction: String, Codable, CaseIterable, Identifiable, Sendable {
        case outgoing
        case incoming

        var id: String { rawValue }

        var title: String {
            switch self {
            case .outgoing: "Outgoing arguments"
            case .incoming: "Incoming responses"
            }
        }
    }

    enum ReplacementType: String, Codable, CaseIterable, Identifiable, Sendable {
        case string
        case bool
        case int64
        case uint64
        case double

        var id: String { rawValue }

        var title: String {
            switch self {
            case .string: "String"
            case .bool: "Boolean"
            case .int64: "Signed integer"
            case .uint64: "Unsigned integer"
            case .double: "Double"
            }
        }
    }

    static let maximumRuleCount = 32
    static let maximumKeyPathDepth = 8
    static let maximumKeyPathSegmentByteCount = 127
    static let maximumKeyPathByteCount = 1_024
    static let maximumReplacementValueByteCount = 4_096

    var id: UUID
    var name: String
    var enabled: Bool
    var serviceName: String
    var direction: Direction
    var operation: String
    var matchKey: String
    var matchStringValue: String
    var replacementKey: String
    var replacementType: ReplacementType
    var replacementValue: String

    init(
        id: UUID = UUID(),
        name: String = "New rule",
        enabled: Bool = true,
        serviceName: String = "com.example.service",
        direction: Direction = .outgoing,
        operation: String = "send",
        matchKey: String = "",
        matchStringValue: String = "",
        replacementKey: String = "key",
        replacementType: ReplacementType = .string,
        replacementValue: String = "replacement"
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.serviceName = serviceName
        self.direction = direction
        self.operation = operation
        self.matchKey = matchKey
        self.matchStringValue = matchStringValue
        self.replacementKey = replacementKey
        self.replacementType = replacementType
        self.replacementValue = replacementValue
    }

    var summary: String {
        "\(direction.rawValue) \(serviceName) \(operation)"
    }

    static func prepared(from event: CaptureEventEnvelope) -> InterceptionRule? {
        guard
            event.source == "injected-xpc",
            event.category == "xpc",
            let serviceName = event.serviceName,
            !serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let direction = Direction(rawValue: event.direction),
            !event.operation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            PayloadTemplate.isDictionaryPayload(event.payload)
        else {
            return nil
        }
        let template = PayloadTemplate.firstReplacement(in: event.payload)
        return InterceptionRule(
            name: String("Intercept \(event.operation)".prefix(120)),
            enabled: false,
            serviceName: serviceName,
            direction: direction,
            operation: event.operation,
            matchKey: template?.predicateKey ?? "",
            matchStringValue: template?.predicateValue ?? "",
            replacementKey: template?.keyPath ?? "key",
            replacementType: template?.type ?? .string,
            replacementValue: template?.value ?? "replacement"
        )
    }

    private struct PayloadTemplate {
        let keyPath: String
        let type: ReplacementType
        let value: String
        let predicateKey: String
        let predicateValue: String

        static func isDictionaryPayload(_ payload: JSONValue?) -> Bool {
            guard case let .object(fields)? = payload else { return false }
            return fields["type"] == .string("dictionary")
                || fields["type"] == .string("lazy-json")
        }

        static func firstReplacement(in payload: JSONValue?) -> PayloadTemplate? {
            guard
                case let .object(fields)? = payload,
                fields["type"] == .string("dictionary"),
                case let .object(dictionary)? = fields["value"]
            else {
                return nil
            }
            return firstReplacement(in: dictionary, path: [])
        }

        private static func firstReplacement(
            in dictionary: [String: JSONValue],
            path: [String]
        ) -> PayloadTemplate? {
            for key in dictionary.keys.sorted() {
                guard keyPathSegmentIsValid(key) else { continue }
                let nextPath = path + [key]
                guard nextPath.count <= InterceptionRule.maximumKeyPathDepth else { continue }
                guard let value = dictionary[key] else { continue }
                if let template = scalarReplacement(for: value, path: nextPath) {
                    return template
                }
                if
                    case let .object(fields) = value,
                    fields["type"] == .string("dictionary"),
                    case let .object(nestedDictionary)? = fields["value"],
                    let template = firstReplacement(in: nestedDictionary, path: nextPath)
                {
                    return template
                }
            }
            return nil
        }

        private static func scalarReplacement(
            for value: JSONValue,
            path: [String]
        ) -> PayloadTemplate? {
            guard case let .object(fields) = value, case let .string(type)? = fields["type"] else {
                return nil
            }
            let keyPath = path.joined(separator: ".")
            switch (type, fields["value"]) {
            case let ("string", .string(value)?):
                guard value.utf8.count <= InterceptionRule.maximumReplacementValueByteCount else {
                    return nil
                }
                return PayloadTemplate(
                    keyPath: keyPath,
                    type: .string,
                    value: value,
                    predicateKey: keyPath,
                    predicateValue: value
                )
            case let ("bool", .bool(value)?):
                return PayloadTemplate(
                    keyPath: keyPath,
                    type: .bool,
                    value: value ? "true" : "false",
                    predicateKey: "",
                    predicateValue: ""
                )
            case let ("int64", .number(value)?):
                guard let value = Int64(exactly: value) else { return nil }
                return numericTemplate(keyPath: keyPath, type: .int64, value: String(value))
            case let ("uint64", .number(value)?):
                guard let value = UInt64(exactly: value) else { return nil }
                return numericTemplate(keyPath: keyPath, type: .uint64, value: String(value))
            case let ("double", .number(value)?) where value.isFinite:
                return numericTemplate(keyPath: keyPath, type: .double, value: String(value))
            default:
                return nil
            }
        }

        private static func numericTemplate(
            keyPath: String,
            type: ReplacementType,
            value: String
        ) -> PayloadTemplate {
            PayloadTemplate(
                keyPath: keyPath,
                type: type,
                value: value,
                predicateKey: "",
                predicateValue: ""
            )
        }

        private static func keyPathSegmentIsValid(_ segment: String) -> Bool {
            !segment.isEmpty
                && !segment.contains(".")
                && segment.utf8.count <= InterceptionRule.maximumKeyPathSegmentByteCount
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case serviceName
        case direction
        case operation
        case matchKey
        case matchStringValue
        case replacementKey
        case replacementType
        case replacementValue
        case replacementStringValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        serviceName = try container.decode(String.self, forKey: .serviceName)
        direction = try container.decode(Direction.self, forKey: .direction)
        operation = try container.decode(String.self, forKey: .operation)
        matchKey = try container.decode(String.self, forKey: .matchKey)
        matchStringValue = try container.decode(String.self, forKey: .matchStringValue)
        replacementKey = try container.decode(String.self, forKey: .replacementKey)
        replacementType = try container.decodeIfPresent(ReplacementType.self, forKey: .replacementType)
            ?? .string
        replacementValue = try container.decodeIfPresent(String.self, forKey: .replacementValue)
            ?? container.decode(String.self, forKey: .replacementStringValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(serviceName, forKey: .serviceName)
        try container.encode(direction, forKey: .direction)
        try container.encode(operation, forKey: .operation)
        try container.encode(matchKey, forKey: .matchKey)
        try container.encode(matchStringValue, forKey: .matchStringValue)
        try container.encode(replacementKey, forKey: .replacementKey)
        try container.encode(replacementType, forKey: .replacementType)
        try container.encode(replacementValue, forKey: .replacementValue)
    }
}

struct InterceptionRuleConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let rules: [InterceptionRule]
}

enum InterceptionRuleValidationError: LocalizedError, Equatable {
    case noEnabledRules
    case tooManyRules(maximum: Int)
    case missingName
    case missingServiceName
    case missingOperation
    case incompletePredicate
    case invalidKeyPath
    case invalidReplacementValue(type: InterceptionRule.ReplacementType)
    case valueTooLong

    var errorDescription: String? {
        switch self {
        case .noEnabledRules:
            "Enable at least one interception rule before launching with interception enabled."
        case let .tooManyRules(maximum):
            "Interception is limited to \(maximum) rules so matching remains bounded on target threads."
        case .missingName:
            "Every interception rule needs a display name."
        case .missingServiceName:
            "Every interception rule needs an exact XPC service name."
        case .missingOperation:
            "Every interception rule needs an exact operation."
        case .incompletePredicate:
            "Provide both a predicate key and string value, or leave both blank."
        case .invalidKeyPath:
            "Use dot-separated dictionary key paths with at most \(InterceptionRule.maximumKeyPathDepth) non-empty segments."
        case let .invalidReplacementValue(type):
            "The replacement value is not a valid \(type.title.lowercased())."
        case .valueTooLong:
            "Interception rule fields exceed the bounded size allowed inside launched targets."
        }
    }
}

@MainActor
final class InterceptionRuleStore: ObservableObject {
    @Published var enabled = false
    @Published private(set) var rules: [InterceptionRule] = []

    var enabledRuleCount: Int {
        rules.count(where: \.enabled)
    }

    func add(_ rule: InterceptionRule = InterceptionRule()) throws {
        guard rules.count < InterceptionRule.maximumRuleCount else {
            throw InterceptionRuleValidationError.tooManyRules(
                maximum: InterceptionRule.maximumRuleCount
            )
        }
        try Self.validate(rule)
        rules.append(rule)
    }

    func update(_ rule: InterceptionRule) throws {
        try Self.validate(rule)
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else {
            return
        }
        rules[index] = rule
    }

    func remove(id: InterceptionRule.ID) {
        rules.removeAll { $0.id == id }
    }

    func writeConfiguration(to directoryURL: URL) throws -> URL? {
        guard enabled else { return nil }
        let enabledRules = rules.filter(\.enabled)
        guard !enabledRules.isEmpty else {
            throw InterceptionRuleValidationError.noEnabledRules
        }
        let data = try Self.configurationData(rules: enabledRules)
        let url = directoryURL.appendingPathComponent("interception-rules.plist")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url
    }

    nonisolated static func configurationData(rules: [InterceptionRule]) throws -> Data {
        guard rules.count <= InterceptionRule.maximumRuleCount else {
            throw InterceptionRuleValidationError.tooManyRules(
                maximum: InterceptionRule.maximumRuleCount
            )
        }
        try rules.forEach(validate)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(
            InterceptionRuleConfiguration(
                schemaVersion: InterceptionRuleConfiguration.currentSchemaVersion,
                rules: rules
            )
        )
    }

    nonisolated static func validate(_ rule: InterceptionRule) throws {
        guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InterceptionRuleValidationError.missingName
        }
        guard !rule.serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InterceptionRuleValidationError.missingServiceName
        }
        guard !rule.operation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InterceptionRuleValidationError.missingOperation
        }
        guard rule.matchKey.isEmpty == rule.matchStringValue.isEmpty else {
            throw InterceptionRuleValidationError.incompletePredicate
        }
        guard fieldLengthsAreBounded(rule) else {
            throw InterceptionRuleValidationError.valueTooLong
        }
        guard rule.matchKey.isEmpty || keyPathIsValid(rule.matchKey),
              keyPathIsValid(rule.replacementKey)
        else {
            throw InterceptionRuleValidationError.invalidKeyPath
        }
        guard replacementValueIsValid(rule) else {
            throw InterceptionRuleValidationError.invalidReplacementValue(type: rule.replacementType)
        }
    }

    nonisolated private static func fieldLengthsAreBounded(_ rule: InterceptionRule) -> Bool {
        rule.name.utf8.count <= InterceptionRule.maximumKeyPathByteCount
            && rule.serviceName.utf8.count <= InterceptionRule.maximumKeyPathByteCount
            && rule.operation.utf8.count <= InterceptionRule.maximumKeyPathByteCount
            && rule.matchStringValue.utf8.count <= InterceptionRule.maximumReplacementValueByteCount
            && rule.replacementValue.utf8.count <= InterceptionRule.maximumReplacementValueByteCount
    }

    nonisolated private static func keyPathIsValid(_ keyPath: String) -> Bool {
        guard !keyPath.isEmpty,
              keyPath.utf8.count <= InterceptionRule.maximumKeyPathByteCount
        else {
            return false
        }
        let segments = keyPath.split(separator: ".", omittingEmptySubsequences: false)
        return segments.count <= InterceptionRule.maximumKeyPathDepth
            && segments.allSatisfy {
                !$0.isEmpty && $0.utf8.count <= InterceptionRule.maximumKeyPathSegmentByteCount
            }
    }

    nonisolated private static func replacementValueIsValid(_ rule: InterceptionRule) -> Bool {
        switch rule.replacementType {
        case .string:
            true
        case .bool:
            ["true", "false"].contains(rule.replacementValue.lowercased())
        case .int64:
            Int64(rule.replacementValue) != nil
        case .uint64:
            UInt64(rule.replacementValue) != nil
        case .double:
            Double(rule.replacementValue)?.isFinite == true
        }
    }
}
