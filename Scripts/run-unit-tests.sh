#!/bin/bash
# Run the SwiftPM unit tests (swift-testing).
#
# This repo builds against the Command Line Tools toolchain (no full Xcode), which ships the
# swift-testing frameworks but does NOT put them on the default runtime search path. We therefore
# pass the framework search path at compile time and bake two rpaths into the test bundle so the
# swiftpm-testing-helper can dlopen Testing.framework + lib_TestingInterop.dylib. With full Xcode
# selected these flags are harmless.
set -euo pipefail
cd "$(dirname "$0")/.."

FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
INTEROP="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

exec swift test "$@" \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$INTEROP"
