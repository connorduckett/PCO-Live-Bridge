#!/bin/bash
# One-time setup (Mac): starts the PCO Live Bridge on service days at several times and when you log in.
# Whichever comes first wins; the bridge exits by itself on days with no service, and only one copy runs.
#
#   bash Install-SundayTask-Mac.sh                       # Sundays at 7:00, 8:30, 9:15, 10:45
#   bash Install-SundayTask-Mac.sh 6:30 8:00 10:15       # your own times (24-hour, local time)
#   bash Install-SundayTask-Mac.sh --days Sat,Sun 7:00   # other days (Sun Mon Tue Wed Thu Fri Sat)
#   bash Install-SundayTask-Mac.sh --config config-pm.json 15:00   # a second config gets its own start
#   bash Install-SundayTask-Mac.sh --uninstall [--config config-pm.json]
#
# The Mac must be on and you must be logged in. If it's asleep at a start time,
# macOS runs the missed start when it wakes.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG=""
DAYS="Sun"
UNINSTALL=0
TIMES=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --uninstall) UNINSTALL=1 ;;
    --config)    shift; CONFIG="${1:-}" ;;
    --days)      shift; DAYS="${1:-}" ;;
    *)           TIMES+=("$1") ;;
  esac
  shift
done

LABEL="org.pcolivebridge.sunday"
CFG_ARGS=""
if [ -n "$CONFIG" ]; then
  case "$CONFIG" in /*) ;; *) CONFIG="$DIR/${CONFIG#./}" ;; esac
  base="$(basename "$CONFIG" .json)"
  if [ "$base" != "config" ]; then
    LABEL="org.pcolivebridge.$(echo "$base" | tr -c 'A-Za-z0-9.
-' '-')"
    CFG_ARGS="    <string>-ConfigPath</string>
    <string>$CONFIG</string>
"
  fi
else
  CONFIG="$DIR/config.json"
fi
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "$UNINSTALL" = 1 ]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed the PCO Live Bridge start ($LABEL)."
  exit 0
fi

PWSH="$(command -v pwsh || true)"
for p in /opt/homebrew/bin/pwsh /usr/local/bin/pwsh /usr/local/microsoft/powershell/7/pwsh; do
  [ -z "$PWSH" ] && [ -x "$p" ] && PWSH="$p"
done
[ -n "$PWSH" ] || { echo "PowerShell 7 (pwsh) not found. Install it first: brew install --cask powershell"; exit 1; }
[ -f "$DIR/PcoLiveBridge.ps1" ] || { echo "PcoLiveBridge.ps1 not found next to this script ($DIR)"; exit 1; }
[ -f "$CONFIG" ] || echo "Warning: $CONFIG not found yet - create it before the first service (see README)."

[ "${#TIMES[@]}" -gt 0 ] || TIMES=("7:00" "8:30" "9:15" "10:45")

DAYNUMS=()
IFS=',' read -r -a DAYLIST <<< "$DAYS"
for d in "${DAYLIST[@]}"; do
  case "$(echo "$d" | tr '[:upper:]' '[:lower:]' | cut -c1-3)" in
    sun) DAYNUMS+=(0) ;; mon) DAYNUMS+=(1) ;; tue) DAYNUMS+=(2) ;; wed) DAYNUMS+=(3) ;;
    thu) DAYNUMS+=(4) ;; fri) DAYNUMS+=(5) ;; sat) DAYNUMS+=(6) ;;
    *) echo "Bad day '$d' - use Sun,Mon,Tue,Wed,Thu,Fri,Sat"; exit 1 ;;
  esac
done

INTERVALS=""
for wd in "${DAYNUMS[@]}"; do
for t in "${TIMES[@]}"; do
  [[ "$t" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || { echo "Bad time '$t' - use 24-hour H:MM, e.g. 7:00 or 13:30"; exit 1; }
  h=$((10#${BASH_REMATCH[1]})); m=$((10#${BASH_REMATCH[2]}))
  { [ "$h" -le 23 ] && [ "$m" -le 59 ]; } || { echo "Bad time '$t' - hours 0-23, minutes 0-59"; exit 1; }
  INTERVALS+="    <dict><key>Weekday</key><integer>$wd</integer><key>Hour</key><integer>$h</integer><key>Minute</key><integer>$m</integer></dict>
"
done
done

mkdir -p "$HOME/Library/LaunchAgents" "$DIR/logs"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PWSH</string>
    <string>-NoProfile</string>
    <string>-File</string>
    <string>$DIR/PcoLiveBridge.ps1</string>
    <string>-OnlyIfServiceToday</string>
$CFG_ARGS  </array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>StartCalendarInterval</key>
  <array>
$INTERVALS  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$DIR/logs/$LABEL.out.txt</string>
  <key>StandardErrorPath</key><string>$DIR/logs/$LABEL.err.txt</string>
</dict>
</plist>
PL

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Installed ($LABEL): PCO Live Bridge starts on $DAYS at ${TIMES[*]} and when you log in."
echo "It exits on days with no service. It runs in the background - check logs/ for what it did."
echo "Remove with: bash Install-SundayTask-Mac.sh --uninstall${CFG_ARGS:+ --config $(basename "$CONFIG")}"
