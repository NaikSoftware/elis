#!/usr/bin/env bash
# Run the host-free SwiftPM tests: shared ElisCore, the Mac's ElisMac, and elis-server.
set -euo pipefail
cd "$(dirname "$0")/../../shared/ElisCore"
swift test
cd ../../macos/ElisMac && swift test
cd ../../server && swift test
