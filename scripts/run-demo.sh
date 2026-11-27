#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export DEVELOPER_DIR="/Applications/Xcode-26.6.0.app/Contents/Developer"

APP_PATH="$ROOT_DIR/build/Products/Debug/OpenUsage.app"
BIN_PATH="$APP_PATH/Contents/MacOS/OpenUsage"

needs_build=0
if [[ ! -x "$BIN_PATH" ]]; then
  needs_build=1
elif [[ -n "$(find "$ROOT_DIR/Sources" "$ROOT_DIR/Resources" "$ROOT_DIR/project.yml" -newer "$BIN_PATH" -print -quit 2>/dev/null)" ]]; then
  needs_build=1
fi

if [[ "$needs_build" -eq 1 ]]; then
  APP_PATH="$("$ROOT_DIR/scripts/build.sh")"
  BIN_PATH="$APP_PATH/Contents/MacOS/OpenUsage"
fi

exec "$BIN_PATH" --demo "$@"
