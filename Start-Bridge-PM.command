#!/bin/bash
# Launcher for a second service type (config-pm.json). See README.
cd "$(dirname "$0")" || exit 1
exec ./Start-Bridge.command -ConfigPath ./config-pm.json "$@"
