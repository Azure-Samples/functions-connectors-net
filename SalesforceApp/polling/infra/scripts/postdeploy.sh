#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bash "$script_dir/create-local-settings.sh"
echo 'Poll configurations are provisioned. Manually authorize the Salesforce connection for the approved org before testing.'
