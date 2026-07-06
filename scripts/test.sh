#!/bin/sh
# Run the PensieveKit test suite. Under an active Xcode toolchain, plain `swift test`
# loads Swift Testing natively; this wrapper is kept as the stable entry point (and for
# passing filters, e.g. ./scripts/test.sh --filter projectRoundTrips).
exec swift test "$@"
