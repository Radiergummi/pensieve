#!/bin/sh
# Run `swift test` with the Command Line Tools' Swift Testing framework available.
#
# This machine is CommandLineTools-only (no Xcode.app). Plain `swift test` cannot
# find Testing.framework or lib_TestingInterop.dylib, so we add both to the compiler
# search path and the runtime rpath. All args pass through, e.g.:
#   ./scripts/test.sh --filter projectRoundTrips
set -e
DEV="$(xcode-select -p)"
FDIR="$DEV/Library/Developer/Frameworks"
LDIR="$DEV/Library/Developer/usr/lib"
exec swift test \
  -Xswiftc -F -Xswiftc "$FDIR" \
  -Xlinker -rpath -Xlinker "$FDIR" \
  -Xlinker -rpath -Xlinker "$LDIR" \
  "$@"
