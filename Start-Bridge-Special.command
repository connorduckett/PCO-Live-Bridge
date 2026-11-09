#!/bin/bash
# Launcher for a third service type (config-special.json). See README.
cd "$(dirname "$0")" || exit 1
exec ./Start-Bridge.command -ConfigPath ./config-special.json "$@"
