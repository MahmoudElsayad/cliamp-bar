#!/bin/sh
set -eu
cd "$(dirname "$0")"
./build.sh
stage=$(mktemp -d /tmp/cliampbar-package.XXXXXX)
trap 'rm -rf "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
mkdir -p "$stage/CliampBar/build"
ditto build/CliampBar.app "$stage/CliampBar/build/CliampBar.app"
cp install.sh LICENSE "$stage/CliampBar/"
ditto -c -k --sequesterRsrc --keepParent "$stage/CliampBar" build/CliampBar-macOS.zip
(cd build && shasum -a 256 CliampBar-macOS.zip > SHA256SUMS)
echo "Packaged build/CliampBar-macOS.zip"
