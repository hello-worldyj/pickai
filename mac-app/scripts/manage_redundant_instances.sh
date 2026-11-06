#!/bin/bash
# Manages the fleet of redundant PickAI instances: one OS process per key in ALL_KEYS, each
# with its own LaunchAgent (KeepAlive=true), each bound to exactly ⌃⌥⌘<key> and nothing else.
# They all run the SAME binary as the main app (deployed by build_app.sh) — what makes each one
# a "redundant instance" instead of a second main app is the PICKAI_HOTKEY_NAME environment
# variable baked into its own LaunchAgent, which AppDelegate reads at launch.
#
# Usage:
#   manage_redundant_instances.sh start [keys...]   # default: all of d z x c v space w e s
#   manage_redundant_instances.sh stop  [keys...]   # default: all
#   manage_redundant_instances.sh list
set -euo pipefail

ALL_KEYS="d z x c v space w e s q"
APP_BUNDLE="$HOME/Library/Application Support/PickAI/PickAI.app"
BINARY_PATH="${APP_BUNDLE}/Contents/MacOS/PickAI"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_PATH="$HOME/Library/Logs/pickai-app.log"

label_for() { echo "com.pickai.redundant.$1"; }

start_one() {
    local key="$1"
    local label; label=$(label_for "$key")
    local plist="${LAUNCH_AGENTS_DIR}/${label}.plist"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${BINARY_PATH}</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PICKAI_HOTKEY_NAME</key>
		<string>${key}</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>1</integer>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>${LOG_PATH}</string>
	<key>StandardErrorPath</key>
	<string>${LOG_PATH}</string>
</dict>
</plist>
PLIST
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load "$plist"
    echo "started redundant instance for ⌘⌥${key} (${label})"
}

stop_one() {
    local key="$1"
    local label; label=$(label_for "$key")
    local plist="${LAUNCH_AGENTS_DIR}/${label}.plist"
    if [ -f "$plist" ]; then
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        echo "stopped redundant instance for ⌘⌥${key} (${label})"
    else
        echo "⌘⌥${key} (${label}) wasn't running"
    fi
}

list_all() {
    for key in $ALL_KEYS; do
        local label; label=$(label_for "$key")
        local state
        state=$(launchctl print "gui/$(id -u)/${label}" 2>/dev/null | grep -m1 "state =" | awk '{print $3}')
        echo "⌘⌥${key}: ${state:-not loaded}"
    done
}

cmd="${1:-}"
shift || true
keys="${*:-$ALL_KEYS}"

case "$cmd" in
    start)
        [ -x "$BINARY_PATH" ] || { echo "error: $BINARY_PATH not found — run build_app.sh first" >&2; exit 1; }
        for k in $keys; do start_one "$k"; done
        ;;
    stop)
        for k in $keys; do stop_one "$k"; done
        ;;
    list)
        list_all
        ;;
    *)
        echo "usage: $0 {start|stop|list} [keys...]" >&2
        exit 1
        ;;
esac
