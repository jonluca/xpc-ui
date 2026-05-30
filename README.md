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
  long pause.
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
- `Privileged helper`: a signed-client-validated LaunchDaemon snapshot RPC,
  registered from **Lab Setup** with admin approval.
- `Endpoint Security`: an explicit gated adapter until Apple's restricted
  entitlement is provisioned.
- `Kernel deep mode`: filtered `syscall` and `mach_trap` DTrace adapters. When
  the LaunchDaemon is enabled it owns DTrace and streams lines back over a
  private XPC callback endpoint; direct launch remains a reported fallback.
  The timeline reports runtime denial when SIP or privileges prevent capture.

## Export

Live sessions remain transient. **Export** writes a `.xpcapture` bundle with the
manifest, newline-delimited events, the latest resource snapshot, drop counters,
and full-fidelity sidecar blobs. Exports intentionally contain sensitive data.

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

SIP-enabled and platform-protected targets still reject some injection, Mach
inspection, and DTrace probes. Endpoint Security telemetry cannot activate
without Apple's restricted entitlement. The app reports these blind spots
instead of implying complete coverage.
