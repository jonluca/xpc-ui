import Foundation

struct TargetPreflight: Identifiable, Sendable {
    struct Check: Identifiable, Sendable {
        enum Level: String, Sendable {
            case available
            case limited
            case unavailable
        }

        let id: String
        let title: String
        let level: Level
        let detail: String
        let blocksLaunch: Bool
    }

    enum TargetKind: String, Sendable {
        case application = "Application bundle"
        case executable = "Executable"
    }

    let id = UUID()
    let targetURL: URL
    let executableURL: URL?
    let displayName: String
    let targetKind: TargetKind
    let targetArchitectures: [String]
    let tracerArchitectures: [String]
    let shouldInjectTracer: Bool
    let checks: [Check]

    var canLaunch: Bool {
        !checks.contains { $0.blocksLaunch && $0.level == .unavailable }
    }

    var hasLimitedCoverage: Bool {
        checks.contains { $0.level != .available }
    }
}
