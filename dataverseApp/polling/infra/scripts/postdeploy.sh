#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../../infra/scripts/setup.sh"
dataverse_setup Poll "$script_dir/../.." "$@"
