#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library \
    Sources/DriveCore/*.swift Tests/Verification/Verification.swift \
    -o .build/verify
.build/verify
