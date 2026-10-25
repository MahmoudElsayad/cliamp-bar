#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun swiftc -swift-version 5 Sources/Player.swift Sources/PlayerStore.swift Sources/Spectrum.swift tests/SpectrumTests.swift tests/main.swift -o build/tests/PlayerTests
build/tests/PlayerTests

if [ "${CLIAMPBAR_INTEGRATION:-0}" = 1 ]; then
  if [ ! -x build/CliampBar.app/Contents/MacOS/CliampBar ]; then ./build.sh; fi
  runtime=$(mktemp -d /tmp/cliampbar-test.XXXXXX)
  trap 'rm -rf "$runtime"' EXIT HUP INT TERM
  CLIAMP_CONFIG_DIR="$runtime" build/tests/PlayerTests --integration
fi
