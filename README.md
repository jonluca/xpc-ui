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

## Current capture tiers

- `Injected XPC`: decoded low-level `libxpc` send, receive, and reply traffic.
- `Process snapshots`: files, folders, sockets, and Mach port rights when the
  target permits inspection.
- `Privileged helper`: scaffolded LaunchDaemon registration and snapshot RPC.
- `Endpoint Security`: reported as gated until the restricted Apple entitlement
  is available.
- `Kernel deep mode`: reported as gated until the helper and reduced-security
  lab setup are active.
