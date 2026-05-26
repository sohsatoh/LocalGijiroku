#!/usr/bin/env bash
# Render AppIcon.iconset via the AppKit Swift program and convert it to
# Resources/AppIcon.icns with iconutil. The script uses AppKit, which the
# Swift JIT (`swift foo.swift`) cannot auto-link, so we compile to a real
# binary first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p Resources build
echo "==> Compiling make-icon"
swiftc -framework AppKit scripts/make-icon.swift -o build/make-icon
echo "==> Rendering PNG iconset"
build/make-icon
echo "==> Packing into .icns"
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
echo "==> Done: Resources/AppIcon.icns"
