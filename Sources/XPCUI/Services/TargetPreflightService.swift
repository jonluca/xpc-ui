import Foundation
import Security

enum TargetPreflightService {
    struct SigningMetadata: Equatable {
        let flags: UInt32
        let teamIdentifier: String?
        let allowsDYLDEnvironmentVariables: Bool
        let disablesLibraryValidation: Bool
        let isPlatformBinary: Bool
    }

    struct InjectionRestriction: Equatable {
        let detail: String
    }

    // Security.framework exposes these constants to C but not Swift.
    static let libraryValidationFlag: UInt32 = 0x2000
    static let hardenedRuntimeFlag: UInt32 = 0x10000

    static func inspect(
        url: URL,
        tracerURL: URL? = Bundle.main.url(forResource: "XPCTrace", withExtension: "dylib"),
        deepCaptureEnabled: Bool
    ) -> TargetPreflight {
        let targetKind: TargetPreflight.TargetKind = url.pathExtension.lowercased() == "app"
            ? .application
            : .executable
        let resolution = resolveExecutable(url: url, targetKind: targetKind)
        let targetArchitectures = resolution.executableURL.map(architectures(at:)) ?? []
        let tracerArchitectures = tracerURL.map(architectures(at:)) ?? []
        let tracerSigningMetadata = tracerURL.flatMap { signingMetadata(at: $0) }
        let restriction: InjectionRestriction?
        if let executableURL = resolution.executableURL {
            restriction = Self.injectionRestriction(
                path: executableURL.standardizedFileURL.path,
                targetSigningMetadata: signingMetadata(at: executableURL),
                tracerSigningMetadata: tracerSigningMetadata
            )
        } else {
            restriction = nil
        }
        let hasCompatibleArchitecture = targetArchitectures.isEmpty
            || !Set(targetArchitectures).intersection(tracerArchitectures).isEmpty
        let shouldInjectTracer = deepCaptureEnabled
            && tracerURL != nil
            && !tracerArchitectures.isEmpty
            && hasCompatibleArchitecture
            && restriction == nil
        let checks = [
            resolution.check,
            architectureCheck(
                targetArchitectures: targetArchitectures,
                tracerArchitectures: tracerArchitectures,
                deepCaptureEnabled: deepCaptureEnabled
            ),
            injectionCheck(
                tracerURL: tracerURL,
                deepCaptureEnabled: deepCaptureEnabled,
                hasCompatibleArchitecture: hasCompatibleArchitecture,
                hasReadableTracerSlice: !tracerArchitectures.isEmpty,
                injectionRestriction: restriction
            ),
            protectedTargetCheck(injectionRestriction: restriction),
        ]

        return TargetPreflight(
            targetURL: url,
            executableURL: resolution.executableURL,
            displayName: url.deletingPathExtension().lastPathComponent,
            targetKind: targetKind,
            targetArchitectures: targetArchitectures,
            tracerArchitectures: tracerArchitectures,
            shouldInjectTracer: shouldInjectTracer,
            checks: checks
        )
    }

    static func architectureCheck(
        targetArchitectures: [String],
        tracerArchitectures: [String],
        deepCaptureEnabled: Bool
    ) -> TargetPreflight.Check {
        guard deepCaptureEnabled else {
            return TargetPreflight.Check(
                id: "architectures",
                title: "Architecture support",
                level: .available,
                detail: architectureDetail(target: targetArchitectures, tracer: tracerArchitectures)
                    + " Deep XPC injection is disabled for this launch.",
                blocksLaunch: false
            )
        }
        guard !targetArchitectures.isEmpty else {
            return TargetPreflight.Check(
                id: "architectures",
                title: "Architecture support",
                level: .limited,
                detail: "The target architecture could not be read. The target may be a script or a non-Mach-O executable; injection coverage is unknown.",
                blocksLaunch: false
            )
        }
        guard !tracerArchitectures.isEmpty else {
            return TargetPreflight.Check(
                id: "architectures",
                title: "Architecture support",
                level: .limited,
                detail: "The bundled tracer architecture could not be read. The target can launch, but deep XPC injection is unavailable.",
                blocksLaunch: false
            )
        }

        let target = Set(targetArchitectures)
        let tracer = Set(tracerArchitectures)
        let supported = target.intersection(tracer)
        let detail = architectureDetail(target: targetArchitectures, tracer: tracerArchitectures)
        if supported.isEmpty {
            return TargetPreflight.Check(
                id: "architectures",
                title: "Architecture support",
                level: .limited,
                detail: detail + " No compatible injected tracer slice is available, so launch will continue with reduced visibility.",
                blocksLaunch: false
            )
        }
        if supported != target {
            return TargetPreflight.Check(
                id: "architectures",
                title: "Architecture support",
                level: .limited,
                detail: detail + " Some target slices are unsupported; deep capture depends on the slice selected by macOS.",
                blocksLaunch: false
            )
        }
        return TargetPreflight.Check(
            id: "architectures",
            title: "Architecture support",
            level: .available,
            detail: detail + " Every target slice has a matching injected tracer slice.",
            blocksLaunch: false
        )
    }

    static func injectionRestriction(
        path: String,
        targetSigningMetadata: SigningMetadata?,
        tracerSigningMetadata: SigningMetadata?
    ) -> InjectionRestriction? {
        let protectedPrefixes = ["/System/", "/usr/bin/", "/bin/", "/sbin/"]
        if protectedPrefixes.contains(where: path.hasPrefix) {
            return InjectionRestriction(
                detail: "The target is in a protected system location. SIP and runtime protections are expected to reject DYLD_INSERT_LIBRARIES."
            )
        }
        guard let targetSigningMetadata else { return nil }
        if targetSigningMetadata.isPlatformBinary {
            return InjectionRestriction(
                detail: "The target is an Apple platform binary. SIP and runtime protections are expected to reject DYLD_INSERT_LIBRARIES."
            )
        }
        let usesHardenedRuntime = targetSigningMetadata.flags & hardenedRuntimeFlag != 0
        if usesHardenedRuntime && !targetSigningMetadata.allowsDYLDEnvironmentVariables {
            return InjectionRestriction(
                detail: "The target enables Hardened Runtime without the Allow DYLD Environment Variables entitlement. macOS is expected to reject DYLD_INSERT_LIBRARIES."
            )
        }
        let requiresLibraryValidation = usesHardenedRuntime
            || targetSigningMetadata.flags & libraryValidationFlag != 0
        let tracerHasMatchingTeam = targetSigningMetadata.teamIdentifier != nil
            && targetSigningMetadata.teamIdentifier == tracerSigningMetadata?.teamIdentifier
        if requiresLibraryValidation
            && !targetSigningMetadata.disablesLibraryValidation
            && !tracerHasMatchingTeam {
            return InjectionRestriction(
                detail: "The target enforces library validation for a differently signed tracer. macOS is expected to reject XPCTrace unless the target disables library validation."
            )
        }
        return nil
    }

    private static func resolveExecutable(
        url: URL,
        targetKind: TargetPreflight.TargetKind
    ) -> (executableURL: URL?, check: TargetPreflight.Check) {
        switch targetKind {
        case .application:
            guard
                FileManager.default.fileExists(atPath: url.path),
                let executableURL = Bundle(url: url)?.executableURL
            else {
                return (
                    nil,
                    TargetPreflight.Check(
                        id: "target",
                        title: "Launch target",
                        level: .unavailable,
                        detail: "The selected application bundle does not contain a launchable executable.",
                        blocksLaunch: true
                    )
                )
            }
            return (
                executableURL,
                TargetPreflight.Check(
                    id: "target",
                    title: "Launch target",
                    level: .available,
                    detail: "Resolved application executable at \(executableURL.path).",
                    blocksLaunch: false
                )
            )
        case .executable:
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                return (
                    nil,
                    TargetPreflight.Check(
                        id: "target",
                        title: "Launch target",
                        level: .unavailable,
                        detail: "The selected path is missing or is not executable.",
                        blocksLaunch: true
                    )
                )
            }
            return (
                url,
                TargetPreflight.Check(
                    id: "target",
                    title: "Launch target",
                    level: .available,
                    detail: "The selected executable is launchable.",
                    blocksLaunch: false
                )
            )
        }
    }

    private static func injectionCheck(
        tracerURL: URL?,
        deepCaptureEnabled: Bool,
        hasCompatibleArchitecture: Bool,
        hasReadableTracerSlice: Bool,
        injectionRestriction: InjectionRestriction?
    ) -> TargetPreflight.Check {
        guard deepCaptureEnabled else {
            return TargetPreflight.Check(
                id: "injection",
                title: "Injected XPC payload capture",
                level: .limited,
                detail: "Deep capture is disabled. Resource snapshots and supported telemetry remain available.",
                blocksLaunch: false
            )
        }
        guard tracerURL != nil else {
            return TargetPreflight.Check(
                id: "injection",
                title: "Injected XPC payload capture",
                level: .limited,
                detail: "The bundled XPCTrace dylib is missing. Launch can continue, but decoded XPC payload capture is unavailable.",
                blocksLaunch: false
            )
        }
        guard hasReadableTracerSlice else {
            return TargetPreflight.Check(
                id: "injection",
                title: "Injected XPC payload capture",
                level: .limited,
                detail: "The bundled XPCTrace architecture could not be read. Launch will continue without dylib injection.",
                blocksLaunch: false
            )
        }
        guard hasCompatibleArchitecture else {
            return TargetPreflight.Check(
                id: "injection",
                title: "Injected XPC payload capture",
                level: .limited,
                detail: "The target has no compatible XPCTrace architecture slice. Launch will continue without dylib injection.",
                blocksLaunch: false
            )
        }
        if let injectionRestriction {
            return TargetPreflight.Check(
                id: "injection",
                title: "Injected XPC payload capture",
                level: .limited,
                detail: injectionRestriction.detail
                    + " Launch will continue without dylib injection; resource snapshots and supported telemetry may still be available.",
                blocksLaunch: false
            )
        }
        return TargetPreflight.Check(
            id: "injection",
            title: "Injected XPC payload capture",
            level: .available,
            detail: "The bundled XPCTrace dylib will be injected at launch.",
            blocksLaunch: false
        )
    }

    private static func protectedTargetCheck(
        injectionRestriction: InjectionRestriction?
    ) -> TargetPreflight.Check {
        TargetPreflight.Check(
            id: "protected-target",
            title: "Target runtime restrictions",
            level: injectionRestriction == nil ? .available : .limited,
            detail: injectionRestriction?.detail
                ?? "The target does not expose a known launch-time injection restriction.",
            blocksLaunch: false
        )
    }

    private static func signingMetadata(at url: URL) -> SigningMetadata? {
        var staticCode: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
            let staticCode
        else {
            return nil
        }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
            let values = information as? [String: Any]
        else {
            return nil
        }
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        return SigningMetadata(
            flags: (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0,
            teamIdentifier: values[kSecCodeInfoTeamIdentifier as String] as? String,
            allowsDYLDEnvironmentVariables: boolEntitlement(
                "com.apple.security.cs.allow-dyld-environment-variables",
                in: entitlements
            ),
            disablesLibraryValidation: boolEntitlement(
                "com.apple.security.cs.disable-library-validation",
                in: entitlements
            ),
            isPlatformBinary: values[kSecCodeInfoPlatformIdentifier as String] != nil
        )
    }

    private static func boolEntitlement(_ key: String, in entitlements: [String: Any]) -> Bool {
        (entitlements[key] as? NSNumber)?.boolValue == true
    }

    private static func architectures(at url: URL) -> [String] {
        let result = commandOutput("/usr/bin/lipo", arguments: ["-archs", url.path])
        guard result.status == 0 else { return [] }
        return result.output
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .sorted()
    }

    private static func architectureDetail(target: [String], tracer: [String]) -> String {
        "Target: \(list(target)). Tracer: \(list(tracer))."
    }

    private static func list(_ architectures: [String]) -> String {
        architectures.isEmpty ? "unknown" : architectures.joined(separator: ", ")
    }

    private static func commandOutput(_ executable: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
