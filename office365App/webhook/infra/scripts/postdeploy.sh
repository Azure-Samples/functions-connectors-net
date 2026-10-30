#!/usr/bin/env bash
set -euo pipefail

# Use the same registration and consent flow on every platform.
exec pwsh -NoProfile -File "$(dirname "${BASH_SOURCE[0]}")/postdeploy.ps1" "$@"
