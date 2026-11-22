#!/usr/bin/env bash
# Run the host-free ElisCore unit tests (no Xcode, no libghostty, no Metal).
set -euo pipefail
cd "$(dirname "$0")/../../shared/ElisCore"
swift test
# the Mac relay's Network listener and Core Bluetooth pipe, through the same suites
cd ../../macos/ElisMac
swift test
