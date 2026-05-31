# XPC UI

XPC UI is a native macOS lab tool for launching a process and inspecting its
XPC traffic, open resources, Mach port namespace, descendants, and optional
kernel-level telemetry.

It is built for controlled debugging and security research on software you own
or are authorized to inspect. It is not a production monitoring agent, a
security boundary, or a complete record of process activity.

## Security warning

XPC UI is intentionally unsandboxed and can collect sensitive data. The default
deep-capture path launches the selected target with an injected dynamic library.
Optional modes can install a privileged LaunchDaemon, request Endpoint Security
activation, and run DTrace probes.

Use it on a dedicated lab Mac when possible. Do not use it casually on a daily
driver, a shared machine, or a system that contains production credentials.
Keep System Integrity Protection (SIP) enabled unless you have a specific test
plan for an isolated lab machine and understand the consequences of disabling
it.

Captures are not redacted or encrypted. They may include:

- XPC payload strings, nested values, and binary blobs
- File and directory paths
- UNIX socket paths and network endpoints
- Process identifiers, executable paths, and descendant relationships
- Mach port namespace metadata
- Named XPC services
- Selected syscall and Mach trap names

Treat every exported `.xpcapture` bundle as sensitive evidence. Store it on an
access-controlled volume, do not commit it to source control, and remove it
according to your lab's data-retention policy.

## Requirements

- macOS 14 or later
- Xcode command-line tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

The basic local fixture workflow does not require a privileged installation.
The privileged helper and Endpoint Security modes have additional signing,
approval, and entitlement requirements described below.

## Build

Generate the Xcode project and create a local Debug build:

```sh
xcodegen generate
xcodebuild \
  -project XPCUI.xcodeproj \
  -scheme XPCUI \
  -configuration Debug \
  -derivedDataPath .derived \
  build
```

Launch the app:

```sh
open ".derived/Build/Products/Debug/XPC UI.app"
```

The checked-in XcodeGen configuration is intentionally lab-oriented:
`ENABLE_HARDENED_RUNTIME` is disabled and the app is unsandboxed. It is not a
distribution-ready signing configuration. Configure your own signing,
provisioning, hardened-runtime, and notarization settings before deploying a
build outside your local lab.

## First capture

Start with the built fixture and the available inspection modes enabled:

1. Open **Lab Setup** and review the reported capability status.
2. Review the default **Kernel**, **NSXPC**, and **ES** switches. Each starts on
   when its local prerequisite is present.
3. Click **Launch Target**.
4. Select `.derived/Build/Products/Debug/XPC Fixture.app`.
5. Read the preflight report and click **Launch Capture**.
6. Inspect the **Timeline** and **Resources** views.
7. Click **Stop** when finished.

The fixture emits classic connection and public-session XPC traffic, including
async replies, sync replies, nested values, binary data, and an intentional
no-reply message.

To exercise executable launch, resource snapshots, and descendant tracking,
launch:

```text
.derived/Build/Products/Debug/XPCFixtureCLI
```

The command-line fixture opens a file, folder, and UNIX socket, emits XPC
traffic, spawns an inherited child copy, and stays alive briefly for snapshots.
Its Mach-service traffic uses the owned
`com.jonluca.xpcui.fixture.mach-service` fixture rather than a system service.

To register that service temporarily and inspect a deterministic round trip:

```sh
python3 Scripts/fixture_mach_service.py -- \
  .derived/Build/Products/Debug/XPCFixtureCLI --interception-probe
```

XPC UI launches targets; it does not attach the injected tracer to an already
running process. Configure any optional switches before selecting a target.

## What each mode does

| Mode | Default | What it collects | Security and reliability notes |
| --- | --- | --- | --- |
| Injected XPC capture | On when preflight permits it | Decoded low-level `libxpc` sends, receives, replies, and public-session traffic | Uses `DYLD_INSERT_LIBRARIES`. The target and inherited descendants receive session paths and a capture token in their environment. Protected or hardened targets may reject injection. |
| Process snapshots | On | Files, folders, sockets, Mach namespace capacity, decoded port rights, and refresh deltas | Direct inspection is best effort. The privileged helper is used as a fallback for snapshots only when it is enabled and direct inspection reports an error. |
| Descendant tracking | On | Process-tree snapshots and inherited launch-time capture | Descendants inherit injection only when their environment propagates. Kernel filters and Endpoint Security PID tracking update as descendants appear or exit. |
| Intercept | Off | Selected XPC dictionary scalar arguments or responses rewritten before forwarding | Lab-only explicit opt-in. Rules are bounded, exact-match, and configured before launch. Dot-separated dictionary key paths support nested values, each matching event records every applied rule identifier, and exports include the unredacted applied rule file. |
| NSXPC | On when the injected tracer is bundled | `NSXPCConnection` initializer lifecycle events | Uses Objective-C method swizzling inside the target process. Disable it before launch for experiments where in-process behavioral changes are unacceptable. |
| Kernel | On when `dtrace` is installed | Filtered `syscall` and `mach_trap` DTrace events | DTrace is frequently limited by SIP and privileges. The registered helper is preferred; direct launch is a reported fallback. |
| ES | On when the system extension is embedded | Endpoint Security notifications for process lifecycle, file open/close, UNIX-domain socket connects, and named XPC service connects | Requires Apple's restricted entitlement, system-extension activation, and Full Disk Access. |

Preflight checks the target architecture, bundled tracer architecture, known
protected locations, Apple platform-binary status, hardened-runtime policy,
DYLD environment-variable policy, and library-validation policy. A target may
still launch with reduced visibility. Review the preflight report and exported
capability results before drawing conclusions from missing events.

Use the **Intercepted** timeline preset to isolate mutated events. The **Mut.**
column marks rewritten messages, and the payload pane lists every applied rule
identifier for the selected event.

Select an injected XPC dictionary event to copy its full envelope as formatted
JSON or draft an interception rule directly from the payload pane. The timeline
context menu exposes the same rule-drafting workflow. Drafts prefill the exact
service, direction, operation, and a writable scalar key path when available,
then open disabled so the match and replacement can be reviewed before use.

## Privileged helper

The optional helper is bundled as a LaunchDaemon and registered through
`SMAppService`. It improves best-effort process snapshots and owns privileged
DTrace launch when **Kernel** mode is enabled.

To enable it:

1. Use an appropriately signed and notarized app bundle. Arbitrary unsigned or
   ad hoc local builds should not be expected to register successfully.
2. Open **Lab Setup**.
3. Click **Register Helper**.
4. Complete any approval requested by macOS in System Settings.
5. Return to **Lab Setup** and click **Refresh**.
6. Confirm that **Privileged capture helper** reports that the LaunchDaemon is
   registered and enabled.

Registration is optional. Without the helper, XPC UI still performs direct
snapshots and attempts direct DTrace launch when **Kernel** is selected.

The helper runs with elevated privileges. Its XPC listener rejects callers
unless macOS validates the client signature, the bundle identifier is
`com.jonluca.xpcui`, and the client has the helper's signing team identifier.
Treat a helper-enabled build as privileged software: keep its signing identity
controlled, distribute it narrowly, and unregister or remove it when the lab
work is complete.

## Endpoint Security

The embedded Endpoint Security system extension is an advanced opt-in. It
subscribes to supported system notifications, then forwards events only for the
tracked target PID set and descendants.

To use it:

1. Request Apple's `com.apple.developer.endpoint-security.client` entitlement.
2. Sign and provision the system extension with that restricted entitlement.
3. Sign the containing app with
   `com.apple.developer.system-extension.install`.
4. Open **Lab Setup** and click **Activate ES**.
5. Approve the system extension when macOS requests approval.
6. Click **Full Disk Access** and grant the required Full Disk Access approval
   in System Settings.
7. Confirm **ES** remains enabled before launching a target.

The checked-in entitlement files declare the required keys, but declarations
alone are not sufficient. Apple must authorize the restricted Endpoint Security
entitlement in the provisioning profile, and the user must grant the required
macOS approvals.

The extension's control service accepts commands only from the expected XPC UI
app identity. Release builds use the native peer-team requirement on supported
macOS versions; the fallback validates the app bundle identifier and signing
team. Debug builds allow the expected app and extension to communicate when
both are ad hoc signed. That Debug allowance is for local development only.

## Kernel tracing

To request filtered DTrace events:

1. Optionally register the privileged helper from **Lab Setup**.
2. Confirm **Kernel** remains enabled before launching the target.
3. Use **Kernel Filters** to select **Syscalls**, **Mach traps**, or both.
4. Launch the target and watch the status text beside the switch.

When the helper is enabled, it starts DTrace and streams lines back to the app
through a private callback endpoint. Otherwise, the app attempts a direct
DTrace launch. Runtime denial is reported in the UI; it should be treated as a
coverage gap, not as proof that no activity occurred.

## NSXPC lifecycle adapter

**NSXPC** starts enabled when the injected tracer is bundled. It collects
initializer lifecycle events for `NSXPCConnection` by swizzling Objective-C
methods in the target process. Disable it before launch for software where
in-process behavioral changes are unacceptable.

## Session storage and export

During capture, XPC UI creates a private working directory similar to:

```text
/tmp/XPCUI-<random UUID>/
```

The session directory and blob directory are created with mode `0700`. The
capture socket and event journal use mode `0600`. Injected collectors
authenticate to the local socket with a random per-session token before sending
frames.

This token prevents accidental cross-session writes; it does not isolate the
app from a hostile target. The launched target receives the token and session
paths in its environment so that its injected collector can connect. A target
under inspection can therefore read, misuse, or spoof its own capture channel.
Do not treat XPC UI output as tamper-proof forensic evidence.

The live timeline is bounded to remain responsive. A private NDJSON journal
preserves the complete decoded session for export unless its own queue
overflows. The UI and exported manifest report drop counters. Large structured
payloads and binary values may be stored as sidecar blobs.

Click **Export** to write a `.xpcapture` bundle containing:

```text
Capture.xpcapture/
  manifest.json
  events.ndjson
  snapshot.json        # when a snapshot is available
  interception-rules.plist # when interception was enabled
  blobs/
```

Click **Open Capture** to inspect an exported bundle offline. Reopening verifies
the manifest against the NDJSON journal, restores the final resource snapshot,
and reconnects lazy blob loading. For large captures, the app streams the
journal and retains the newest 200,000 timeline rows while preserving aggregate
process, category, service, and drop-counter metadata. Use **Capture Info** in
offline mode to review the target, session identity, capability results,
evidence warnings, and drop counters recorded at export time.

Exports contain full-fidelity, unredacted payloads and inherit the permissions
of the destination you choose. They are not encrypted by XPC UI.

Session directories are working files, not a secure deletion mechanism. A
previous directory is removed when a new capture starts in the same app
session, but files can remain after a quit or crash. After closing XPC UI,
inspect and remove stale lab sessions when appropriate:

```sh
find /tmp -maxdepth 1 -type d -name 'XPCUI-*' -print
find /tmp -maxdepth 1 -type d -name 'XPCUI-*' -exec rm -rf {} +
```

## Security boundaries

- XPC UI reports best-effort visibility, not completeness. SIP, platform-binary
  protections, hardened runtime, library validation, permissions, queue
  pressure, and process lifetime can all produce blind spots.
- The app is unsandboxed because inspection requires access that a sandboxed
  app would not have. Run only builds you trust.
- The capture socket is local, private by filesystem permission, and
  token-authenticated. The inspected target still receives the token.
- The privileged helper trusts only a valid same-team `com.jonluca.xpcui`
  client. A compromise of that trusted app identity can expose privileged
  operations.
- The Endpoint Security extension filters forwarded events to tracked PIDs, but
  Endpoint Security itself is a system-wide capability. Activate it only on a
  machine where that level of telemetry is appropriate.
- Disabling SIP may increase visibility but weakens system protections. Never
  disable SIP merely to make a routine capture work.
- Exported captures can contain secrets. Review destination permissions and
  retention before sharing them.

## Verify

Run the unit tests:

```sh
xcodebuild \
  -project XPCUI.xcodeproj \
  -scheme XPCUI \
  -configuration Debug \
  -derivedDataPath .derived \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Build a universal Release tracer and inspect its slices:

```sh
xcodebuild \
  -project XPCUI.xcodeproj \
  -scheme XPCUI \
  -configuration Release \
  -derivedDataPath .derived-universal \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS='arm64 x86_64' \
  build
lipo -info .derived-universal/Build/Products/Release/XPCTrace.dylib
```

Exercise the injected tracer under backpressure:

```sh
python3 Scripts/stress_tracer.py
python3 Scripts/stress_tracer.py --interception --events-per-second 10000 --duration-seconds 10
```

Verify an opt-in fixture argument rewrite end to end:

```sh
python3 Scripts/verify_interception.py
```

The verifier temporarily registers the owned fixture Mach service, applies
outgoing and incoming rewrite rules for nested values and every supported scalar
type, then removes the service registration.

## Troubleshooting

**The target launches but injected events are missing.**

Read the preflight report. Protected paths, Apple platform binaries, hardened
runtime, library validation, and architecture mismatch can prevent injection.

**Register Helper does not enable the LaunchDaemon.**

Use a properly signed and notarized bundle, complete the macOS approval flow,
then click **Refresh** in **Lab Setup**. A local Debug build may be useful for
basic capture while remaining unsuitable for helper registration.

**ES activation completes but ES events are missing.**

Confirm the restricted entitlement is authorized in the extension's
provisioning profile, the extension is approved, Full Disk Access is granted,
and **ES** was enabled before target launch.

**Kernel mode reports unavailable.**

Treat the message as a DTrace coverage limitation. Check the helper status,
selected filters, SIP state, and local privilege policy.

**The timeline reports dropped events.**

Reduce capture load, avoid leaving the UI paused during sustained bursts, and
inspect the exported drop counters before relying on the capture.

## Apple platform references

- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Endpoint Security](https://developer.apple.com/documentation/endpointsecurity)
- [`com.apple.developer.endpoint-security.client`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.endpoint-security.client)
- [`es_new_client`](https://developer.apple.com/documentation/endpointsecurity/3259700-es_new_client)
- [System Extension Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.system-extension.install)
- [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [System Extensions and DriverKit](https://developer.apple.com/system-extensions/)
