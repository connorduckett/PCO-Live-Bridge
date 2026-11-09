#!/bin/bash
# PCO Live Bridge - Mac launcher. Double-click in Finder, or run in Terminal:
#   ./Start-Bridge.command                 (live)
#   ./Start-Bridge.command -DryRun         (any switch from the README works)
#   ./Start-Bridge.command -ConfigPath ./config-pm.json
cd "$(dirname "$0")" || exit 1

PWSH="$(command -v pwsh || true)"
for p in /opt/homebrew/bin/pwsh /usr/local/bin/pwsh /usr/local/microsoft/powershell/7/pwsh; do
  [ -z "$PWSH" ] && [ -x "$p" ] && PWSH="$p"
done
if [ -z "$PWSH" ]; then
  echo "PowerShell 7 (pwsh) is not installed."
  echo "Install it with:  brew install --cask powershell"
  echo "or download it from https://aka.ms/powershell-release?tag=stable"
  read -r -p "Press Return to close..." _
  exit 1
fi

"$PWSH" -NoProfile -File "./PcoLiveBridge.ps1" "$@"
echo
read -r -p "Press Return to close..." _
