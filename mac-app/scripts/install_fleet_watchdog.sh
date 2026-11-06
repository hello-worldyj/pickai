#!/bin/bash
# Installs (or removes, with `uninstall`) the com.pickai.fleetwatchdog LaunchAgent, which runs
# fleet_watchdog.sh every 60s to keep the main PickAI instance and all 10 redundant instances
# loaded in launchd for as long as this is installed — independent of any particular terminal
# or chat session. Run `install_fleet_watchdog.sh uninstall` to stop enforcing this.
set -euo pipefail
cd "$(dirname "$0")/.."
# launchd running something from inside this iCloud-Drive-synced Desktop folder hits the same
# sandbox restriction that bit the app's own code signature before (see build_app.sh's
# comments) — confirmed live: running fleet_watchdog.sh directly worked, but launchd invoking
# that exact same path failed with "Operation not permitted" (exit 126). Deploying the scripts
# to the same non-iCloud location the app itself already deploys to sidesteps it entirely.
DEPLOY_DIR="$HOME/Library/Application Support/PickAI/scripts"
mkdir -p "$DEPLOY_DIR"
cp scripts/fleet_watchdog.sh scripts/manage_redundant_instances.sh "$DEPLOY_DIR/"
chmod +x "$DEPLOY_DIR/fleet_watchdog.sh" "$DEPLOY_DIR/manage_redundant_instances.sh"
sed -i '' "s|cd \"\$(dirname \"\$0\")/..\"|cd \"\$(dirname \"\$0\")\"|" "$DEPLOY_DIR/fleet_watchdog.sh"
SCRIPT_PATH="${DEPLOY_DIR}/fleet_watchdog.sh"
LABEL="com.pickai.fleetwatchdog"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_PATH="$HOME/Library/Logs/pickai-app.log"

if [ "${1:-}" = "uninstall" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "fleet watchdog uninstalled — the fleet will no longer be auto-reinstalled if unloaded"
    exit 0
fi

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${SCRIPT_PATH}</string>
	</array>
	<key>StartInterval</key>
	<integer>60</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>${LOG_PATH}</string>
	<key>StandardErrorPath</key>
	<string>${LOG_PATH}</string>
</dict>
</plist>
PLIST

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "fleet watchdog installed — checks every 60s that main + all 10 redundant instances are loaded, reinstalling any that are missing"
