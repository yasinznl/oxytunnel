#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /usr/local/lib/oxytunnel/lib.sh

require_root
load_conf
trap 'log_event err "tunnel start failed on ${TUN_NAME:-oxytunnel}"' ERR
if [[ "${PROTO:-gre4}" == "gre6" ]]; then
  bring_up_v6
  log_event notice "experimental GRE v6 ${TUN_NAME} is up, role ${ROLE}, speed ${SPEED:-normal}, peer ${PEER_IP}"
  case "$ROLE" in
    iran) apply_forwards ;;
    foreign) remove_forwards ;;
  esac
  if [[ "${SPEED:-normal}" == "fast" ]]; then
    apply_mss
  else
    remove_mss
    save_iptables
  fi
else
  bring_up
  log_event notice "tunnel ${TUN_NAME} is up, role ${ROLE}, speed ${SPEED:-normal}, peer ${PEER_IP}"

  case "$ROLE" in
    iran) apply_forwards ;;
    foreign) remove_forwards ;;
  esac
  if [[ "${SPEED:-normal}" == "fast" ]]; then
    apply_mss
  else
    remove_mss
    save_iptables
  fi
fi
