#!/usr/bin/env python3
"""Run a command with the owned XPC fixture Mach service temporarily registered."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
from typing import Iterator, Sequence


SERVICE_LABEL = "com.jonluca.xpcui.fixture.mach-service"


def launchd_target() -> str:
    return f"gui/{os.getuid()}"


def launchd_service_target() -> str:
    return f"{launchd_target()}/{SERVICE_LABEL}"


def bootout() -> None:
    subprocess.run(
        ["launchctl", "bootout", launchd_service_target()],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


@contextmanager
def bootstrapped_fixture_mach_service(products_dir: Path) -> Iterator[Path]:
    service = products_dir.resolve() / "XPCFixtureMachService"
    if not service.is_file():
        raise FileNotFoundError(f"fixture Mach service is missing from {products_dir}")

    with tempfile.TemporaryDirectory(prefix="XPCUIFixtureService-", dir="/tmp") as temporary:
        plist_path = Path(temporary) / f"{SERVICE_LABEL}.plist"
        with plist_path.open("wb") as plist_file:
            plistlib.dump(
                {
                    "Label": SERVICE_LABEL,
                    "ProgramArguments": [str(service)],
                    "MachServices": {SERVICE_LABEL: True},
                    "ProcessType": "Interactive",
                },
                plist_file,
            )
        bootout()
        subprocess.run(
            ["launchctl", "bootstrap", launchd_target(), str(plist_path)],
            check=True,
            capture_output=True,
            text=True,
        )
        try:
            yield service
        finally:
            bootout()


def run_command(products_dir: Path, command: Sequence[str]) -> int:
    with bootstrapped_fixture_mach_service(products_dir):
        return subprocess.run(command, check=False).returncode


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--products-dir",
        type=Path,
        default=Path(".derived/Build/Products/Debug"),
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("provide a command after --")
    return run_command(args.products_dir, command)


if __name__ == "__main__":
    raise SystemExit(main())
