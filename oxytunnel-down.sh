#!/usr/bin/env bash
set -euo pipefail

LIB="/usr/local/lib/oxytunnel/lib.sh"
[[ -f "$LIB" ]] || exit 0
# shellcheck source=/dev/null
source "$LIB"

[[ -f "$CONF" ]] || exit 0
load_conf
log_event notice "tunnel ${TUN_NAME} stopping"
remove_forwards
bring_down
log_event notice "tunnel ${TUN_NAME} stopped"
