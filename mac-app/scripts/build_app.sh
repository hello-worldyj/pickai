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
cp "Resources/GoogleService-Info.plist" "${APP_BUNDLE}/Contents/Resources/GoogleService-Info.plist"

# Firebase/GoogleSignIn's SPM resource bundles (localized strings, images) — needed at
# runtime, not just build time, so they have to be embedded in the shipped app bundle too.
shopt -s nullglob
for bundle in "${BUILD_DIR}"/*.bundle; do
    cp -R "$bundle" "${APP_BUNDLE}/Contents/Resources/"
done
shopt -u nullglob

xattr -cr "${APP_BUNDLE}"
# xattr -cr clears extended attributes but not AppleDouble resource-fork sidecar files
# (._*), which some of the fetched SPM bundle resources carry — codesign rejects those.
find "${APP_BUNDLE}" -name "._*" -delete
find "${APP_BUNDLE}" -name ".DS_Store" -delete

echo "Codesigning with local dev identity..."
codesign --force --deep --sign "PickAI Local Dev" "${APP_BUNDLE}"

echo "Done: ${APP_BUNDLE}"
echo "Run with: open ${APP_BUNDLE}"
