#!/bin/sh
set -eu
if [ -n "${CLIAMP_BINARY:-}" ]; then
  case "$CLIAMP_BINARY" in
    /*) ;;
    *) CLIAMP_BINARY="$PWD/$CLIAMP_BINARY" ;;
  esac
  export CLIAMP_BINARY
  if [ ! -x "$CLIAMP_BINARY" ]; then
    echo "CLIAMP_BINARY does not name an executable: $CLIAMP_BINARY" >&2
    exit 1
  fi
fi
cd "$(dirname "$0")"

if [ "$(uname -s)" != Darwin ]; then
  echo "CliampBar requires macOS 13 or later." >&2
  exit 1
fi

find_cliamp() {
  if [ -n "${CLIAMP_BINARY:-}" ] && [ -x "$CLIAMP_BINARY" ]; then
    printf '%s\n' "$CLIAMP_BINARY"
    return
  fi
  command -v cliamp 2>/dev/null && return
  for candidate in /opt/homebrew/bin/cliamp /usr/local/bin/cliamp "$HOME/.local/bin/cliamp"; do
    if [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return; fi
  done
  return 1
}

cliamp_path=$(find_cliamp || true)
if [ -z "$cliamp_path" ]; then
  brew_path=$(command -v brew || true)
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -z "$brew_path" ] && [ -x "$candidate" ]; then brew_path="$candidate"; fi
  done
  if [ -z "$brew_path" ]; then
    echo "Install Homebrew from https://brew.sh, then run ./install.sh again. The installer will install Cliamp for you." >&2
    exit 1
  fi
  "$brew_path" install bjarneo/cliamp/cliamp
  cliamp_path=$(find_cliamp)
fi
case "$cliamp_path" in
  /*) ;;
  *) cliamp_path="$(cd "$(dirname "$cliamp_path")" && pwd)/$(basename "$cliamp_path")" ;;
esac

version=$("$cliamp_path" --version | sed -n 's/.*v\([0-9][0-9.]*\).*/\1/p')
if ! awk -v version="$version" 'BEGIN { split(version,v,"."); exit !(v[1]>2 || (v[1]==2 && v[2]>=3)) }'; then
  echo "Cliamp 2.3.0 or later is required. Update Cliamp, then run ./install.sh again." >&2
  exit 1
fi

if [ -d Sources ]; then
  ./build.sh
elif [ ! -d build/CliampBar.app ]; then
  echo "Keep install.sh beside the build/CliampBar.app folder, or run it from a source checkout." >&2
  exit 1
fi

target="$HOME/Applications/CliampBar.app"
mkdir -p "$HOME/Applications"
staged=$(mktemp -d "$HOME/Applications/.cliampbar-install.XXXXXX")
cleanup() {
  if [ ! -e "$target" ] && [ -e "$staged/previous.app" ]; then mv "$staged/previous.app" "$target"; fi
  rm -rf "$staged"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
ditto build/CliampBar.app "$staged/CliampBar.app"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$staged/CliampBar.app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:CLIAMP_BINARY string $cliamp_path" "$staged/CliampBar.app/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier io.github.mahmoudelsayad.cliamp-bar "$staged/CliampBar.app"

for pid in $(pgrep -x CliampBar || true); do
  kill "$pid"
  attempt=0
  while kill -0 "$pid" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ]; then
      echo "Quit the running CliampBar app, then run ./install.sh again." >&2
      exit 1
    fi
    sleep 0.1
  done
done
if [ -e "$target" ]; then mv "$target" "$staged/previous.app"; fi
if ! mv "$staged/CliampBar.app" "$target"; then
  if [ -e "$staged/previous.app" ]; then mv "$staged/previous.app" "$target"; fi
  exit 1
fi
open "$target"
echo "Installed $target with $cliamp_path. Click the speaker icon in the menu bar."
