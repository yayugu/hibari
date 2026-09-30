#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

DESTINATION=${DESTINATION:-"platform=iOS Simulator,name=iPhone 17"}
mkdir -p build
RESULT="build/perf-$(date +%Y%m%d-%H%M%S).xcresult"

if [ ! -d perf/Fixtures.bundle ]; then
  echo "perf/Fixtures.bundle is missing: run scripts/fetch_fixtures.py first" >&2
  exit 1
fi

set +e
xcodebuild test \
  -project hibari.xcodeproj \
  -scheme hibari-perf \
  -destination "$DESTINATION" \
  -derivedDataPath build/DerivedData \
  -resultBundlePath "$RESULT" \
  "$@" > build/perf.log 2>&1
STATUS=$?
set -e

grep -E "HIBARI_BENCHMARK_RESULT|Test Case .*(passed|failed)|error:|measured \[" build/perf.log \
  | sed 's/^.*HIBARI_BENCHMARK_RESULT //'
echo "log: build/perf.log"
echo "result bundle: $RESULT (open in Xcode for metrics and attachments)"
exit $STATUS
