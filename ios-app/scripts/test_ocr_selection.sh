#!/bin/bash
# Run the actual Foundation-only OCR selection code without a simulator or device.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/.build/OCRSelectionTests"
TEST_FRAMEWORKS="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
TEST_LIBRARIES="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
mkdir -p "$BUILD"
cat > "$BUILD/main.swift" <<'SWIFT'
import XCTest
import Darwin
let suite = XCTestSuite(name: "Screen observation and targeting")
suite.addTest(ScreenTextSelectionTests.defaultTestSuite)
suite.addTest(ScreenStabilityTests.defaultTestSuite)
suite.run()
guard let run = suite.testRun, run.executionCount > 0 else { fatalError("No OCR selection tests executed") }
exit(run.totalFailureCount == 0 ? 0 : 1)
SWIFT
xcrun swiftc -D TAPITO_OCR_SELECTION_HOST_TESTS -F "$TEST_FRAMEWORKS" -I "$TEST_LIBRARIES" -L "$TEST_LIBRARIES" \
    -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TEST_LIBRARIES" \
    "$ROOT/ios-app/Tapito/Models/AppError.swift" \
    "$ROOT/ios-app/Tapito/Capture/ScreenTextObservation.swift" \
    "$ROOT/ios-app/Tapito/Capture/FrameImage.swift" \
    "$ROOT/ios-app/Tapito/Models/CaptureStamp.swift" \
    "$ROOT/ios-app/Tapito/Capture/ScreenStability.swift" \
    "$ROOT/ios-app/TapitoTests/ScreenTextSelectionTests.swift" \
    "$ROOT/ios-app/TapitoTests/ScreenStabilityTests.swift" \
    "$BUILD/main.swift" -o "$BUILD/tests"
"$BUILD/tests"
