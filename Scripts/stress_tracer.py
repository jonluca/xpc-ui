#!/usr/bin/env python3
"""Exercise the injected tracer with a stalled socket consumer."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import tempfile
import threading
import time
import plistlib


def read_exact(connection: socket.socket, byte_count: int) -> bytes | None:
    data = b""
    while len(data) < byte_count:
        chunk = connection.recv(byte_count - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def sample_rss_kib(pid: int) -> int:
    result = subprocess.run(
        ["/bin/ps", "-o", "rss=", "-p", str(pid)],
        check=False,
        capture_output=True,
        text=True,
    )
    try:
        return int(result.stdout.strip())
    except ValueError:
        return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--products-dir",
        type=Path,
        default=Path(".derived/Build/Products/Debug"),
    )
    parser.add_argument("--events-per-second", type=int, default=25_000)
    parser.add_argument("--duration-seconds", type=int, default=60)
    parser.add_argument("--max-rss-mib", type=int, default=128)
    parser.add_argument(
        "--interception",
        action="store_true",
        help="exercise the public XPC send hook with an active nested scalar rewrite",
    )
    args = parser.parse_args()

    products_dir = args.products_dir.resolve()
    tracer = products_dir / "XPCTrace.dylib"
    fixture = products_dir / "XPCFixtureCLI"
    if not tracer.is_file() or not fixture.is_file():
        parser.error(f"build products are missing from {products_dir}")

    with tempfile.TemporaryDirectory(prefix="XPCUIStress-", dir="/tmp") as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        socket_path = root / "capture.sock"
        blobs_path = root / "blobs"
        blobs_path.mkdir(mode=0o700)
        rules_path = root / "interception-rules.plist"
        if args.interception:
            with rules_path.open("wb") as rules_file:
                plistlib.dump(
                    {
                        "schemaVersion": 2,
                        "rules": [
                            {
                                "id": "stress-nested-pid-rule",
                                "name": "Rewrite nested stress PID",
                                "enabled": True,
                                "serviceName": "com.jonluca.xpcui.fixture.mach-service",
                                "direction": "outgoing",
                                "operation": "send",
                                "matchKey": "nested.transport",
                                "matchStringValue": "Process",
                                "replacementKey": "nested.pid",
                                "replacementType": "int64",
                                "replacementValue": "4242",
                            }
                        ],
                    },
                    rules_file,
                    fmt=plistlib.FMT_BINARY,
                )
            rules_path.chmod(0o600)
        auth_token = secrets.token_hex(32)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(socket_path))
        socket_path.chmod(0o600)
        server.listen(1)
        authenticated = threading.Event()
        release_connection = threading.Event()
        authentication: dict[str, str] = {}

        def hold_stalled_connection() -> None:
            connection, _ = server.accept()
            with connection:
                header = read_exact(connection, 4)
                if not header:
                    return
                frame = read_exact(connection, struct.unpack(">I", header)[0])
                if not frame:
                    return
                authentication.update(json.loads(frame))
                authenticated.set()
                release_connection.wait()

        consumer = threading.Thread(target=hold_stalled_connection, daemon=True)
        consumer.start()
        environment = os.environ.copy()
        environment.update(
            {
                "DYLD_INSERT_LIBRARIES": str(tracer),
                "XPCUI_SESSION_ID": "stress-tracer",
                "XPCUI_AUTH_TOKEN": auth_token,
                "XPCUI_SOCKET_PATH": str(socket_path),
                "XPCUI_BLOBS_PATH": str(blobs_path),
            }
        )
        if args.interception:
            environment["XPCUI_INTERCEPTION_RULES_PATH"] = str(rules_path)
        process = subprocess.Popen(
            [
                str(fixture),
                "--stress-xpc" if args.interception else "--stress-lifecycle",
                str(args.events_per_second),
                str(args.duration_seconds),
            ],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        maximum_rss_kib = 0
        while process.poll() is None:
            maximum_rss_kib = max(maximum_rss_kib, sample_rss_kib(process.pid))
            time.sleep(0.05)
        stdout, stderr = process.communicate()
        maximum_rss_kib = max(maximum_rss_kib, sample_rss_kib(process.pid))
        release_connection.set()
        server.close()
        consumer.join(timeout=1)

    result = json.loads(stdout)
    expected_events = args.events_per_second * args.duration_seconds
    elapsed_seconds = result["elapsedNanoseconds"] / 1_000_000_000
    maximum_rss_mib = maximum_rss_kib / 1024
    passed = (
        process.returncode == 0
        and authentication.get("authToken") == auth_token
        and result["submittedEvents"] == expected_events
        and elapsed_seconds <= args.duration_seconds + 2
        and maximum_rss_mib <= args.max_rss_mib
    )
    print(
        json.dumps(
            {
                "passed": passed,
                "submittedEvents": result["submittedEvents"],
                "eventsPerSecond": args.events_per_second,
                "durationSeconds": args.duration_seconds,
                "targetElapsedSeconds": round(elapsed_seconds, 3),
                "maximumRSSMiB": round(maximum_rss_mib, 3),
                "maximumAllowedRSSMiB": args.max_rss_mib,
                "authenticatedTransport": authentication.get("authToken") == auth_token,
                "interceptionEnabled": args.interception,
                "fixtureStatus": process.returncode,
                "fixtureStderr": stderr.strip(),
            },
            indent=2,
        )
    )
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
