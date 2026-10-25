#!/bin/sh
set -eu
cd "$(dirname "$0")"

if [ "$(uname -s)" != Darwin ]; then
  echo "CliampBar requires macOS 13 or later." >&2
  exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Install Xcode Command Line Tools with xcode-select --install, then run ./build.sh again." >&2
  exit 1
fi

app=build/CliampBar.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    Sources/*.swift -o "build/CliampBar-$arch"
done
lipo -create build/CliampBar-arm64 build/CliampBar-x86_64 -output "$app/Contents/MacOS/CliampBar"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.mahmoudelsayad.cliamp-bar</string>
  <key>CFBundleName</key><string>CliampBar</string>
  <key>CFBundleDisplayName</key><string>CliampBar</string>
  <key>CFBundleExecutable</key><string>CliampBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.2</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp LICENSE "$app/Contents/Resources/LICENSE"
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier io.github.mahmoudelsayad.cliamp-bar "$app"
echo "Built $app (Apple Silicon and Intel)."
