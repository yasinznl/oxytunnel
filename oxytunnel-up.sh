#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /usr/local/lib/oxytunnel/lib.sh

require_root
load_conf
trap 'log_event err "tunnel start failed on ${TUN_NAME:-oxytunnel}"' ERR
bring_up
log_event notice "tunnel ${TUN_NAME} is up, role ${ROLE}, peer ${PEER_IP}"

case "$ROLE" in
  iran) apply_forwards ;;
  foreign) remove_forwards ;;
esac
