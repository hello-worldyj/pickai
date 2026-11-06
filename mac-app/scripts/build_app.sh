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
# seconds after they're cleared — codesign rejects both. Worse, iCloud can re-tag the bundle
# again in the instant AFTER a signing attempt succeeds, silently invalidating that signature
# (confirmed live: codesign exited 0, but launchd then refused to run it with
# OS_REASON_CODESIGNING). So success is only real once --verify --deep --strict also passes —
# checking codesign's own exit code alone isn't enough.
for attempt in 1 2 3 4 5 6 7 8; do
    xattr -cr "${APP_BUNDLE}"
    find "${APP_BUNDLE}" -name "._*" -delete
    find "${APP_BUNDLE}" -name ".DS_Store" -delete
    if codesign --force --deep --sign "PickAI Local Dev" "${APP_BUNDLE}" 2>/tmp/pickai_codesign_err.log \
        && codesign --verify --deep --strict "${APP_BUNDLE}" 2>>/tmp/pickai_codesign_err.log; then
        break
    fi
    if [ "$attempt" -eq 8 ]; then
        echo "Codesigning failed after 8 attempts:"
        cat /tmp/pickai_codesign_err.log
        exit 1
    fi
    sleep 1
done

echo "Done: ${APP_BUNDLE}"

# The LaunchAgent (com.pickai.app, KeepAlive=true) runs its OWN copy from here, not from
# the iCloud-synced folder above. iCloud's file-provider daemon can re-tag the bundle with
# com.apple.FinderInfo within ~1s of a successful sign — invalidating the signature after
# this script already verified it passed — which caused a real incident: launchd kept
# relaunching the invalidated binary, got SIGKILLed by the kernel's code-signing launch
# constraint every time, in a tight loop (2026-09-09). Deploying outside iCloud sync removes
# the race entirely instead of trying to out-run it with more retries.
DEPLOY_DIR="$HOME/Library/Application Support/PickAI"
DEPLOY_BUNDLE="${DEPLOY_DIR}/${APP_BUNDLE}"
echo "Deploying to ${DEPLOY_BUNDLE} (outside iCloud sync, what launchd actually runs)..."
mkdir -p "${DEPLOY_DIR}"
rm -rf "${DEPLOY_BUNDLE}"
cp -R "${APP_BUNDLE}" "${DEPLOY_BUNDLE}"
xattr -cr "${DEPLOY_BUNDLE}"
xattr -d com.apple.FinderInfo "${DEPLOY_BUNDLE}" 2>/dev/null || true
codesign --force --deep --sign "PickAI Local Dev" "${DEPLOY_BUNDLE}"
codesign --verify --deep --strict "${DEPLOY_BUNDLE}"

echo "Done: ${DEPLOY_BUNDLE}"
echo "Restart with: launchctl kickstart -k gui/\$(id -u)/com.pickai.app"
