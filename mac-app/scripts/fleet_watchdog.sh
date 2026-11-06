#!/bin/bash
# Keeps the whole PickAI fleet (main + every redundant instance) loaded in launchd, not just
# alive. launchd's own KeepAlive already relaunches a process that dies — this covers the gap
# KeepAlive can't: a LaunchAgent that gets unloaded or its plist removed entirely, which no
# amount of KeepAlive on the (now nonexistent) job can recover from on its own.
#
# Run periodically by com.pickai.fleetwatchdog (see install_fleet_watchdog.sh). Idempotent and
# safe to run as often as you like: (re)installing an already-correct LaunchAgent is a no-op.
set -euo pipefail
cd "$(dirname "$0")/.."

MAIN_PLIST="$HOME/Library/LaunchAgents/com.pickai.app.plist"
APP_BUNDLE="$HOME/Library/Application Support/PickAI/PickAI.app"

if [ ! -f "$MAIN_PLIST" ] || ! launchctl print "gui/$(id -u)/com.pickai.app" >/dev/null 2>&1; then
    echo "$(date): main instance missing from launchd — PickAI must be run manually at least once to self-install it" >&2
else
    launchctl print "gui/$(id -u)/com.pickai.app" >/dev/null 2>&1 || launchctl load "$MAIN_PLIST" 2>/dev/null || true
fi

if [ -x "${APP_BUNDLE}/Contents/MacOS/PickAI" ]; then
    for key in d z x c v space w e s q; do
        label="com.pickai.redundant.${key}"
        if ! launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
            echo "$(date): ${label} missing — reinstalling"
            bash scripts/manage_redundant_instances.sh start "$key"
        fi
    done
fi
