#!/usr/bin/env bash
set -euo pipefail

LIB="/usr/local/lib/sudotunnel/lib.sh"
[[ -f "$LIB" ]] || exit 0
# shellcheck source=/dev/null
source "$LIB"

[[ -f "$CONF" ]] || exit 0
load_conf
remove_forwards
bring_down
