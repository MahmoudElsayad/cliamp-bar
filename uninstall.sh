#!/bin/sh
set -eu
target="$HOME/Applications/CliampBar.app"
if [ ! -d "$target" ]; then echo "CliampBar is not installed in ~/Applications."; exit 0; fi
echo "Turn off Launch at Login in CliampBar Settings before uninstalling."
pid=$(pgrep -f "^$target/Contents/MacOS/CliampBar$" || true)
if [ -n "$pid" ]; then kill "$pid"; fi
mkdir -p "$HOME/.Trash"
mv "$target" "$HOME/.Trash/CliampBar-$(date +%Y%m%d-%H%M%S).app"
echo "Moved CliampBar to Trash. Cliamp and its music configuration remain installed."
