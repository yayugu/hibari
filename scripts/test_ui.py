#!/usr/bin/env python3
"""Run the small UI suite with a private mock server on an OS-assigned port."""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", default=os.environ.get("DESTINATION", "platform=iOS Simulator,name=iPhone 17"))
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--derived-data", type=Path, default=ROOT / "build/DerivedData")
    args, xcodebuild_args = parser.parse_known_args()
    if args.workers < 1:
        parser.error("--workers must be positive")

    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    log_path = build / f"ui-{os.getpid()}.log"
    with tempfile.TemporaryDirectory(prefix="hibari-ui-") as temporary:
        ready = Path(temporary) / "ready"
        with (build / f"mock-{os.getpid()}.log").open("w") as mock_log:
            mock = subprocess.Popen(
                [sys.executable, str(ROOT / "scripts/mock_misskey.py"), "--port", "0", "--ready-file", str(ready)],
                cwd=ROOT, stdout=mock_log, stderr=subprocess.STDOUT,
            )
            try:
                deadline = time.monotonic() + 10
                while not ready.exists() and mock.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                if not ready.exists():
                    print("mock server failed to start; see", mock_log.name, file=sys.stderr)
                    return 1
                url = ready.read_text().strip()
                print(f"mock server: {url}", flush=True)
                env = os.environ.copy()
                env["TEST_RUNNER_HIBARI_MOCK_URL"] = url
                command = [
                    "xcodebuild", "test", "-project", str(ROOT / "hibari.xcodeproj"),
                    "-scheme", "hibari-ui", "-destination", args.destination,
                    "-derivedDataPath", str(args.derived_data.resolve()),
                    "-parallel-testing-enabled", "YES", "-maximum-parallel-testing-workers", str(args.workers),
                    *xcodebuild_args,
                ]
                with log_path.open("w") as log:
                    result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
                for line in log_path.read_text(errors="replace").splitlines():
                    if (("Test case " in line or "Test Case " in line)
                            and (" passed " in line or " failed " in line)
                            or "error:" in line or "** TEST " in line or "Test run with " in line):
                        print(line)
                print(f"log: {log_path}")
                return result.returncode
            finally:
                mock.terminate()
                try:
                    mock.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    mock.kill()
                    mock.wait()


if __name__ == "__main__":
    sys.exit(main())
