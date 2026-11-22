#!/usr/bin/env bash
# Run the host-free SwiftPM tests: shared ElisCore, the Mac's ElisMac, and elis-server.
# Every package runs even after one fails, as the single swift test of one package used to report them all.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
status=0
for package in shared/ElisCore macos/ElisMac server; do
  (cd "$root/$package" && swift test) || status=1
done
exit "$status"
