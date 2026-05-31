#!/usr/bin/env python3
"""Verify bidirectional fixture interception against an owned XPC Mach service."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import secrets
import socket
import struct
import subprocess
import tempfile
import threading
import time

from fixture_mach_service import SERVICE_LABEL, bootstrapped_fixture_mach_service


def read_exact(connection: socket.socket, byte_count: int) -> bytes | None:
    data = b""
    while len(data) < byte_count:
        chunk = connection.recv(byte_count - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def rule(
    identifier: str,
    *,
    direction: str,
    operation: str,
    replacement_key: str,
    replacement_type: str,
    replacement_value: str,
) -> dict[str, object]:
    match_key = "kind" if direction == "outgoing" else "status"
    match_value = "interception-probe" if direction == "outgoing" else "ok"
    return {
        "id": identifier,
        "name": f"Rewrite {replacement_key}",
        "enabled": True,
        "serviceName": SERVICE_LABEL,
        "direction": direction,
        "operation": operation,
        "matchKey": match_key,
        "matchStringValue": match_value,
        "replacementKey": replacement_key,
        "replacementType": replacement_type,
        "replacementValue": replacement_value,
    }


def nested_value(event: dict[str, object], *keys: str) -> object:
    value: object = event["payload"]
    for key in keys:
        value = value["value"][key]  # type: ignore[index]
    return value["value"]  # type: ignore[index]


def find_intercepted_event(
    events: list[dict[str, object]],
    *,
    direction: str,
    operation: str,
    expected_rule_ids: list[str],
) -> dict[str, object] | None:
    expected_diagnostics = {f"intercepted-rule:{identifier}" for identifier in expected_rule_ids}
    for event in events:
        if (
            event.get("serviceName") == SERVICE_LABEL
            and event.get("direction") == direction
            and event.get("operation") == operation
            and expected_diagnostics.issubset(set(event.get("diagnostics", [])))
        ):
            return event
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--products-dir",
        type=Path,
        default=Path(".derived/Build/Products/Debug"),
    )
    args = parser.parse_args()

    products_dir = args.products_dir.resolve()
    tracer = products_dir / "XPCTrace.dylib"
    fixture = products_dir / "XPCFixtureCLI"
    if not tracer.is_file() or not fixture.is_file():
        parser.error(f"build products are missing from {products_dir}")

    outgoing_rule_ids = [
        "outgoing-role",
        "outgoing-enabled",
        "outgoing-signed",
        "outgoing-unsigned",
        "outgoing-ratio",
        "outgoing-nested-pid",
    ]
    incoming_rule_ids = [
        "incoming-label",
        "incoming-enabled",
        "incoming-signed",
        "incoming-unsigned",
        "incoming-ratio",
    ]
    rules = [
        rule(outgoing_rule_ids[0], direction="outgoing", operation="send-with-reply-sync", replacement_key="probe.role", replacement_type="string", replacement_value="intercepted-client"),
        rule(outgoing_rule_ids[1], direction="outgoing", operation="send-with-reply-sync", replacement_key="probe.enabled", replacement_type="bool", replacement_value="false"),
        rule(outgoing_rule_ids[2], direction="outgoing", operation="send-with-reply-sync", replacement_key="probe.signed", replacement_type="int64", replacement_value="-42"),
        rule(outgoing_rule_ids[3], direction="outgoing", operation="send-with-reply-sync", replacement_key="probe.unsigned", replacement_type="uint64", replacement_value="42"),
        rule(outgoing_rule_ids[4], direction="outgoing", operation="send-with-reply-sync", replacement_key="probe.ratio", replacement_type="double", replacement_value="2.5"),
        rule(outgoing_rule_ids[5], direction="outgoing", operation="send-with-reply-sync", replacement_key="probe.nested.pid", replacement_type="int64", replacement_value="4242"),
        rule(incoming_rule_ids[0], direction="incoming", operation="reply-sync", replacement_key="response.label", replacement_type="string", replacement_value="intercepted-service"),
        rule(incoming_rule_ids[1], direction="incoming", operation="reply-sync", replacement_key="response.enabled", replacement_type="bool", replacement_value="true"),
        rule(incoming_rule_ids[2], direction="incoming", operation="reply-sync", replacement_key="response.signed", replacement_type="int64", replacement_value="-84"),
        rule(incoming_rule_ids[3], direction="incoming", operation="reply-sync", replacement_key="response.unsigned", replacement_type="uint64", replacement_value="84"),
        rule(incoming_rule_ids[4], direction="incoming", operation="reply-sync", replacement_key="response.ratio", replacement_type="double", replacement_value="5.25"),
    ]

    with tempfile.TemporaryDirectory(prefix="XPCUIIntercept-", dir="/tmp") as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        socket_path = root / "capture.sock"
        blobs_path = root / "blobs"
        blobs_path.mkdir(mode=0o700)
        rules_path = root / "interception-rules.plist"
        with rules_path.open("wb") as rules_file:
            plistlib.dump(
                {"schemaVersion": 2, "rules": rules},
                rules_file,
                fmt=plistlib.FMT_BINARY,
            )
        rules_path.chmod(0o600)

        auth_token = secrets.token_hex(32)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(socket_path))
        socket_path.chmod(0o600)
        server.listen(8)
        server.settimeout(0.25)
        events: list[dict[str, object]] = []
        stop = threading.Event()

        def consume(connection: socket.socket) -> None:
            with connection:
                while not stop.is_set():
                    header = read_exact(connection, 4)
                    if not header:
                        return
                    frame = read_exact(connection, struct.unpack(">I", header)[0])
                    if not frame:
                        return
                    event = json.loads(frame)
                    if event.get("authToken") != auth_token:
                        events.append(event)

        def accept_connections() -> None:
            while not stop.is_set():
                try:
                    connection, _ = server.accept()
                except socket.timeout:
                    continue
                threading.Thread(target=consume, args=(connection,), daemon=True).start()

        accept_thread = threading.Thread(target=accept_connections, daemon=True)
        accept_thread.start()
        environment = os.environ.copy()
        environment.update(
            {
                "DYLD_INSERT_LIBRARIES": str(tracer),
                "XPCUI_SESSION_ID": "interception-runtime-test",
                "XPCUI_AUTH_TOKEN": auth_token,
                "XPCUI_SOCKET_PATH": str(socket_path),
                "XPCUI_BLOBS_PATH": str(blobs_path),
                "XPCUI_INTERCEPTION_RULES_PATH": str(rules_path),
            }
        )
        with bootstrapped_fixture_mach_service(products_dir):
            process = subprocess.run(
                [str(fixture), "--interception-probe"],
                env=environment,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        time.sleep(0.25)
        stop.set()
        server.close()
        accept_thread.join(timeout=1)

    try:
        probe = json.loads(process.stdout)
    except json.JSONDecodeError:
        probe = None
    outgoing = find_intercepted_event(
        events,
        direction="outgoing",
        operation="send-with-reply-sync",
        expected_rule_ids=outgoing_rule_ids,
    )
    incoming = find_intercepted_event(
        events,
        direction="incoming",
        operation="reply-sync",
        expected_rule_ids=incoming_rule_ids,
    )
    expected_probe = {
        "received": {
            "role": "intercepted-client",
            "enabled": False,
            "signed": -42,
            "unsigned": 42,
            "ratio": 2.5,
            "nestedPID": 4242,
        },
        "response": {
            "label": "intercepted-service",
            "enabled": True,
            "signed": -84,
            "unsigned": 84,
            "ratio": 5.25,
        },
    }
    passed = (
        process.returncode == 0
        and probe == expected_probe
        and outgoing is not None
        and incoming is not None
        and nested_value(outgoing, "probe", "nested", "pid") == 4242
        and nested_value(incoming, "response", "label") == "intercepted-service"
    )
    print(
        json.dumps(
            {
                "passed": passed,
                "fixtureStatus": process.returncode,
                "capturedEvents": len(events),
                "probe": probe,
                "outgoingDiagnostics": outgoing.get("diagnostics", []) if outgoing else [],
                "incomingDiagnostics": incoming.get("diagnostics", []) if incoming else [],
                "fixtureStderr": process.stderr.strip(),
            },
            indent=2,
        )
    )
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
