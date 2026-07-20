#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPL="$DIR/script/dev.harness.reap-docker-disk.plist.tmpl"
PLIST="$HOME/Library/LaunchAgents/dev.harness.reap-docker-disk.plist"
LABEL="dev.harness.reap-docker-disk"

[ -f "$TMPL" ] || { echo "❌ missing template: $TMPL" >&2; exit 1; }
chmod +x "$DIR/script/reap-docker-disk.sh"
mkdir -p "$(dirname "$PLIST")" "$HOME/.local/state/harness-reap" "$HOME/Library/Logs/harness"
sed "s#__REPO__#${DIR}#g" "$TMPL" > "$PLIST"

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl enable  "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "✅ installed in DRY-RUN mode (removes nothing)."
echo "   verify : launchctl print gui/$(id -u)/${LABEL} | head"
echo "   run now: launchctl kickstart -p gui/$(id -u)/${LABEL}"
echo "   log    : $HOME/Library/Logs/harness/reap-docker-disk.log"
echo "   ARM IT : add '--apply --prune-nested' to the template, re-run this script."
