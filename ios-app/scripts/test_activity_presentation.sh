#!/bin/bash
# Runs the exact shared projection and XCTest contracts on macOS, without a simulator or device.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/.build/ActivityPresentationTests"
TEST_FRAMEWORKS="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
TEST_LIBRARIES="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
mkdir -p "$BUILD"
cat > "$BUILD/main.swift" <<'SWIFT'
import XCTest
import Darwin
let suite = AgentActivityPresentationTests.defaultTestSuite
suite.run()
guard let run = suite.testRun, run.executionCount > 0 else { fatalError("No presentation tests executed") }
exit(run.totalFailureCount == 0 ? 0 : 1)
SWIFT
xcrun swiftc -D TAPITO_PRESENTATION_HOST_TESTS -F "$TEST_FRAMEWORKS" -I "$TEST_LIBRARIES" -L "$TEST_LIBRARIES" \
    -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TEST_LIBRARIES" \
    "$ROOT/ios-app/Shared/AgentActivityAttributes.swift" \
    "$ROOT/ios-app/Shared/AgentActivityPresentation.swift" \
    "$ROOT/ios-app/TapitoTests/AgentActivityPresentationTests.swift" \
    "$BUILD/main.swift" -o "$BUILD/tests"
"$BUILD/tests"
