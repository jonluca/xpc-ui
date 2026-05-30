import Foundation

final class KernelTraceService: @unchecked Sendable {
    enum Category: String, CaseIterable, Identifiable {
        case syscall
        case machTrap = "mach_trap"

        var id: String { rawValue }
    }

    enum TraceError: LocalizedError {
        case noCategories
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .noCategories: "Select at least one kernel trace category."
            case .alreadyRunning: "Kernel deep mode is already running."
            }
        }
    }

    private let queue = DispatchQueue(label: "com.jonluca.xpcui.kernel-trace")
    private var process: Process?

    func start(pid: Int32, categories: Set<Category>, onLine: @escaping @Sendable (String) -> Void) throws {
        guard !categories.isEmpty else { throw TraceError.noCategories }
        guard process == nil else { throw TraceError.alreadyRunning }
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/dtrace")
        process.arguments = ["-q", "-n", Self.script(pid: pid, categories: categories)]
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            guard let output = String(data: handle.availableData, encoding: .utf8), !output.isEmpty else {
                return
            }
            output.split(separator: "\n").forEach { onLine(String($0)) }
        }
        try process.run()
        self.process = process
        queue.async { [weak self] in
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            self?.process = nil
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    static func script(pid: Int32, categories: Set<Category>) -> String {
        categories.sorted { $0.rawValue < $1.rawValue }.map { category in
            """
            \(category.rawValue):::entry
            /pid == \(pid)/
            {
                printf("\(category.rawValue)\\tentry\\t%s\\t%d\\t%d\\n", probefunc, pid, tid);
            }
            \(category.rawValue):::return
            /pid == \(pid)/
            {
                printf("\(category.rawValue)\\treturn\\t%s\\t%d\\t%d\\n", probefunc, pid, tid);
            }
            """
        }.joined(separator: "\n")
    }
}
