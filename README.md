# XPC UI

XPC UI is a native macOS lab tool for launching a process and inspecting its
XPC traffic, open resources, Mach port namespace, and opt-in kernel tracing
capabilities.

The app is intentionally unsandboxed. Deep capture uses launch-time
instrumentation and is best effort: macOS security policy can still reject
inspection of protected targets.

## Build

```sh
xcodegen generate
xcodebuild -project XPCUI.xcodeproj -scheme XPCUI -configuration Debug build
```

Run `XPC UI.app`, choose **Launch Target**, and select either an `.app` bundle or
an executable. For a deterministic first capture, select the built fixture:

```text
.derived/Build/Products/Debug/XPC Fixture.app
```

The fixture emits classic connection traffic and public session traffic,
including async replies, sync replies, nested values, binary data, and an
intentional no-reply message.

To exercise executable launch and descendant tracking, select:

```text
.derived/Build/Products/Debug/XPCFixtureCLI
```

The command-line fixture opens a file, folder, and UNIX socket, emits XPC
traffic, spawns an inherited child copy, and stays alive briefly for snapshots.

The **Kernel** switch is intentionally opt-in and must be enabled before
launching the target.

## Capture tiers

- `Injected XPC`: decoded low-level `libxpc` connection and public session send,
  receive, and reply traffic.
  Payloads are deep-copied before deferred serialization. Rare non-copyable XPC
  types stay visible through a retained fallback and carry a diagnostic.
  Oversized structured payloads are stored as lazy sidecars so the live
  timeline remains responsive without losing export fidelity. UI ingestion is
  also bounded and reports its own overflow drops during sustained bursts or a
  long pause. A private transient NDJSON journal preserves the complete decoded
  session for export even when older timeline rows are trimmed from memory.
- `Optional NSXPC lifecycle`: an explicit launch-time opt-in for replaceable
  `NSXPCConnection` initializer hooks. This swizzled adapter remains disabled by
  default so brittle experiments stay separate from the stable public hooks.
- `Descendants`: child processes inherit launch-time injection when macOS allows
  their environment to propagate. Resource snapshots follow the live descendant
  tree, and opt-in kernel deep mode updates its DTrace PID filters as children
  appear or exit.
- `Process snapshots`: files, folders, sockets, Mach namespace capacity, decoded
  port rights, and refresh-to-refresh deltas when the target permits inspection.
  Observed XPC services stay separate from opaque process-local Mach names.
- `Privileged helper`: a valid same-team signed-client LaunchDaemon snapshot
  RPC, registered from **Lab Setup** with admin approval. ServiceManagement
  registration requires a signed, notarized app bundle.
- `Endpoint Security`: an embedded, entitlement-gated system extension for
  process lifecycle, file open/close, UNIX-domain socket connects, and named
  XPC service connects. **Lab Setup** exposes explicit activation and Full Disk
  Access controls. The extension accepts control messages only from the signed
  XPC UI app. Runtime collection still requires Apple's restricted entitlement
  and Full Disk Access approval.
- `Kernel deep mode`: filtered `syscall` and `mach_trap` DTrace adapters. When
  the LaunchDaemon is enabled it owns DTrace and streams lines back over a
  private XPC callback endpoint; direct launch remains a reported fallback.
  The timeline reports runtime denial when SIP or privileges prevent capture.

## Export

Live sessions remain transient. **Export** writes a `.xpcapture` bundle with the
manifest, newline-delimited events, the latest resource snapshot, structured
capability results, aggregate and per-collector drop counters, and full-fidelity
sidecar blobs. Exports intentionally contain sensitive data.

## Verify

```sh
xcodebuild -project XPCUI.xcodeproj -scheme XPCUI \
  -configuration Debug -derivedDataPath .derived \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test

xcodebuild -project XPCUI.xcodeproj -scheme XPCUI \
  -configuration Release -derivedDataPath .derived-universal \
  ONLY_ACTIVE_ARCH=NO ARCHS='arm64 x86_64' build
lipo -info .derived-universal/Build/Products/Release/XPCTrace.dylib
```

## Lab limits

SIP-enabled, platform-protected, and hardened-runtime targets still reject some
injection, Mach inspection, and DTrace probes. Launch preflight checks the
target's DYLD-environment and library-validation signature policy before
requesting injection. Endpoint Security telemetry cannot activate without
Apple's restricted entitlement. The app reports these blind spots instead of
implying complete coverage.
