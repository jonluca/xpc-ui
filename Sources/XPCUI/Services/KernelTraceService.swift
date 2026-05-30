import Foundation

final class KernelTraceService: @unchecked Sendable {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case syscall
        case machTrap = "mach_trap"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .syscall: "Syscalls"
            case .machTrap: "Mach traps"
            }
        }
    }

    enum TraceError: LocalizedError {
        case noCategories
        case noProcesses
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .noCategories: "Select at least one kernel trace category."
            case .noProcesses: "No live process is available for kernel tracing."
            case .alreadyRunning: "Kernel deep mode is already running."
            }
        }
    }

    private let queue = DispatchQueue(label: "com.jonluca.xpcui.kernel-trace")
    private let lock = NSLock()
    private var process: Process?

    func start(
        pids: Set<Int32>,
        categories: Set<Category>,
        onLine: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws {
        guard !categories.isEmpty else { throw TraceError.noCategories }
        guard !pids.isEmpty else { throw TraceError.noProcesses }
        lock.lock()
        defer { lock.unlock() }
        guard process == nil else { throw TraceError.alreadyRunning }
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/dtrace")
        process.arguments = ["-q", "-n", Self.script(pids: pids, categories: categories)]
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
            self?.clear(process: process)
            onTermination(process.terminationStatus)
        }
    }

    func stop() {
        lock.lock()
        let process = process
        self.process = nil
        lock.unlock()
        process?.terminate()
    }

    private func clear(process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    static func script(pids: Set<Int32>, categories: Set<Category>) -> String {
        let predicate = pids.sorted().map { "pid == \($0)" }.joined(separator: " || ")
        return categories.sorted { $0.rawValue < $1.rawValue }.map { category in
            """
            \(category.rawValue):::entry
            /\(predicate)/
            {
                printf("\(category.rawValue)\\tentry\\t%s\\t%d\\t%d\\t%d\\n", probefunc, pid, ppid, tid);
            }
            \(category.rawValue):::return
            /\(predicate)/
            {
                printf("\(category.rawValue)\\treturn\\t%s\\t%d\\t%d\\t%d\\n", probefunc, pid, ppid, tid);
            }
            """
        }.joined(separator: "\n")
    }
}
