#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="PickAI"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"

echo "Building ${APP_NAME}..."
swift build -c release

echo "Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

xattr -cr "${APP_BUNDLE}"

echo "Codesigning with local dev identity..."
codesign --force --deep --sign "PickAI Local Dev" "${APP_BUNDLE}"

echo "Done: ${APP_BUNDLE}"
echo "Run with: open ${APP_BUNDLE}"
