#!/bin/sh
# Runs the unit tests: the broker/pricing logic compiled with Tests/*.swift (no UI, no network).
set -eu
cd "$(dirname "$0")/.."
. scripts/sdkflag.sh
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
swiftc -parse-as-library $SDKFLAG \
  Sources/Chillar/Broker.swift Sources/Chillar/DhanBroker.swift Sources/Chillar/HTTP.swift \
  Sources/Chillar/Pricing.swift Tests/*.swift -o "$OUT/tests"
"$OUT/tests" Fixtures
