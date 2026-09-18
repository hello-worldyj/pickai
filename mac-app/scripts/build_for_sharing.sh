#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="PickAI"
APP_BUNDLE="${APP_NAME}.app"
SHARE_BUNDLE="${APP_NAME}-share.app"
ZIP_NAME="${APP_NAME}.app.zip"

./scripts/build_app.sh

# IMPORTANT: never ad-hoc sign APP_BUNDLE in place. It's the exact path the
# com.pickai.app LaunchAgent runs with KeepAlive=true — overwriting its signature
# broke macOS's launch-constraint check for a *running* background app and caused
# a SIGKILL/relaunch crash loop that froze the whole machine (2026-09-09 incident).
# Work on a separate copy instead.
rm -rf "${SHARE_BUNDLE}"
cp -R "${APP_BUNDLE}" "${SHARE_BUNDLE}"
# Same iCloud-Drive xattr/AppleDouble detritus that build_app.sh works around --
# codesign refuses to sign a bundle carrying it.
xattr -cr "${SHARE_BUNDLE}"
find "${SHARE_BUNDLE}" -name "._*" -delete
find "${SHARE_BUNDLE}" -name ".DS_Store" -delete

echo "Re-signing ${SHARE_BUNDLE} ad-hoc for sharing..."
# "PickAI Local Dev" is a self-signed cert that only this Mac trusts — on a friend's Mac
# it doesn't just warn, Gatekeeper flags the app as "damaged" and refuses to open it at
# all, with no override. An ad-hoc signature (no identity) is the standard way to hand an
# unnotarized app to someone else: they still get one Gatekeeper prompt, but it's the
# normal "unidentified developer" one, bypassable with right-click → Open.
for attempt in 1 2 3 4 5 6 7 8; do
    xattr -cr "${SHARE_BUNDLE}"
    find "${SHARE_BUNDLE}" -name "._*" -delete
    if codesign --force --deep --sign - "${SHARE_BUNDLE}" 2>/tmp/pickai_share_codesign_err.log \
        && codesign --verify --deep --strict "${SHARE_BUNDLE}" 2>>/tmp/pickai_share_codesign_err.log; then
        break
    fi
    if [ "$attempt" -eq 8 ]; then
        echo "Codesigning (share copy) failed after 8 attempts:"
        cat /tmp/pickai_share_codesign_err.log
        exit 1
    fi
    sleep 1
done

# Zip it under the real name (PickAI.app), not PickAI-share.app -- stage in a scratch
# dir so the zip's top-level entry is correct.
STAGE_DIR="$(mktemp -d)"
mv "${SHARE_BUNDLE}" "${STAGE_DIR}/${APP_BUNDLE}"
rm -f "${ZIP_NAME}"
ditto -c -k --keepParent "${STAGE_DIR}/${APP_BUNDLE}" "$(pwd)/${ZIP_NAME}"
rm -rf "${STAGE_DIR}"

echo "Done: ${ZIP_NAME}"
echo
echo "Send this zip to your friend (AirDrop/Messages/etc). First launch instructions:"
echo "  1. Unzip it, drag PickAI.app to Applications (optional)."
echo "  2. Right-click PickAI.app -> Open -> Open again in the dialog."
echo "     (Double-clicking will be blocked the first time since it's not from"
echo "     the App Store or a registered Apple developer.)"
echo "  3. Grant Accessibility + Screen Recording permission when prompted"
echo "     (System Settings > Privacy & Security)."
echo "PickAI installs its own LaunchAgent on first launch, so it'll relaunch"
echo "instantly whenever it's quit or crashes -- no extra setup needed."
