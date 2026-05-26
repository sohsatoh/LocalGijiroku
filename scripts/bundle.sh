#!/usr/bin/env bash
# Builds GijirokuTaker through xcodebuild (so that MLX's Metal shaders compile
# into default.metallib) and wraps the binary plus SPM resource bundles into a
# .app that macOS can launch from Finder.
#
# Usage:
#   scripts/bundle.sh            # debug build
#   scripts/bundle.sh release    # release build
#
# Requires Xcode + the Metal Toolchain component:
#   xcodebuild -downloadComponent MetalToolchain
set -euo pipefail

CONFIG="${1:-debug}"
if [ "${CONFIG}" = "release" ]; then
    XCODE_CONFIG="Release"
else
    XCODE_CONFIG="Debug"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="GijirokuTaker"
BUNDLE_ID="com.gijirokutaker.app"
DERIVED="${ROOT}/xcode-build"
PRODUCTS_DIR="${DERIVED}/Build/Products/${XCODE_CONFIG}"
APP_PATH="${ROOT}/build/${APP_NAME}.app"
CONTENTS="${APP_PATH}/Contents"

echo "==> Building ${APP_NAME} (${XCODE_CONFIG}) via xcodebuild"
cd "${ROOT}"
xcodebuild \
    -scheme "${APP_NAME}" \
    -configuration "${XCODE_CONFIG}" \
    -derivedDataPath "${DERIVED}" \
    -destination 'platform=macOS' \
    -skipMacroValidation \
    build > "${DERIVED}/build.log" 2>&1 || {
        echo "ERROR: xcodebuild failed. See ${DERIVED}/build.log" >&2
        tail -20 "${DERIVED}/build.log" >&2
        exit 1
    }

BIN="${PRODUCTS_DIR}/${APP_NAME}"
if [ ! -f "${BIN}" ]; then
    echo "ERROR: binary not found at ${BIN}" >&2
    exit 1
fi

echo "==> Assembling ${APP_PATH}"
rm -rf "${APP_PATH}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "${BIN}" "${CONTENTS}/MacOS/${APP_NAME}"
cp "${ROOT}/Resources/Info.plist" "${CONTENTS}/Info.plist"
if [ -f "${ROOT}/Resources/AppIcon.icns" ]; then
    cp "${ROOT}/Resources/AppIcon.icns" "${CONTENTS}/Resources/AppIcon.icns"
fi
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# Copy every SwiftPM resource bundle next to the binary so that MLX's
# default.metallib, tokenizer data, etc. are findable at runtime.
copied=0
for bundle in "${PRODUCTS_DIR}"/*.bundle; do
    [ -d "${bundle}" ] || continue
    cp -R "${bundle}" "${CONTENTS}/Resources/"
    copied=$((copied + 1))
done
echo "==> Copied ${copied} resource bundle(s)"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - --identifier "${BUNDLE_ID}" "${APP_PATH}"

echo "==> Done: ${APP_PATH}"
echo
echo "Launch with:"
echo "  open \"${APP_PATH}\""
