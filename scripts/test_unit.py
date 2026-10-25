#!/usr/bin/env python3
"""Run the unit tests (hibariTests) on iPhone 17, the one simulator they are written for."""

import argparse
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
DESTINATION = "platform=iOS Simulator,name=iPhone 17"


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     epilog="Other arguments go to xcodebuild (e.g. -only-testing:hibariTests/TimelineTabTests).")
    parser.add_argument("--derived-data", type=Path, default=ROOT / "build/DerivedData")
    args, xcodebuild_args = parser.parse_known_args()
    if not any(arg.startswith("-only-testing") for arg in xcodebuild_args):
        xcodebuild_args.append("-only-testing:hibariTests")

    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    log_path = build / f"unit-{os.getpid()}.log"
    command = [
        "xcodebuild", "test", "-project", str(ROOT / "hibari.xcodeproj"),
        "-scheme", "hibari", "-destination", DESTINATION,
        "-derivedDataPath", str(args.derived_data.resolve()),
        *xcodebuild_args,
    ]
    with log_path.open("w") as log:
        result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    for line in log_path.read_text(errors="replace").splitlines():
        if line.startswith("✘") or "error:" in line or "** TEST " in line or "Test run with " in line:
            print(line)
    print(f"log: {log_path}")
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
