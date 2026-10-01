#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /usr/local/lib/oxytunnel/lib.sh

require_root
watch_tunnel
