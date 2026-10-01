#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /usr/local/lib/sudotunnel/lib.sh

require_root
load_conf
bring_up

case "$ROLE" in
  iran) apply_forwards ;;
  foreign) remove_forwards ;;
esac
