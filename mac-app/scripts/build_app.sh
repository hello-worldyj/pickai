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

echo "Codesigning with local dev identity..."
# This project lives in an iCloud-Drive-synced folder, and the file-provider daemon keeps
# re-tagging files with com.apple.FinderInfo (and dropping ._* AppleDouble sidecars) even
# seconds after they're cleared — codesign rejects both. Retry the whole clean+sign cycle
# instead of a single attempt, since this is a transient race, not a real problem with the
# bundle's contents (a plain `open` launches it fine even when the strict verify fails).
for attempt in 1 2 3 4 5; do
    xattr -cr "${APP_BUNDLE}"
    find "${APP_BUNDLE}" -name "._*" -delete
    find "${APP_BUNDLE}" -name ".DS_Store" -delete
    if codesign --force --deep --sign "PickAI Local Dev" "${APP_BUNDLE}" 2>/tmp/pickai_codesign_err.log; then
        break
    fi
    if [ "$attempt" -eq 5 ]; then
        echo "Codesigning failed after 5 attempts:"
        cat /tmp/pickai_codesign_err.log
        exit 1
    fi
    sleep 1
done

echo "Done: ${APP_BUNDLE}"
echo "Run with: open ${APP_BUNDLE}"
