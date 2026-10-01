#!/usr/bin/env bash
set -euo pipefail

APP="oxytunnel"
CONF="/etc/${APP}.conf"
BASE_URL="https://raw.githubusercontent.com/yasinznl/oxytunnel/main"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ ${EUID:-0} -eq 0 ]] || die "Run as root."; }
has() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
${APP} installer

Usage:
  sudo ./install.sh [options]

Options:
  --local-ip <IPv4>        Public IP of this server
  --remote-ip <IPv4>       Public IP of the other server
  --tun-ip <IPv4>          Tunnel IP on this server
  --peer-ip <IPv4>         Tunnel IP on the other server
  --cidr <N>               Tunnel prefix (default: 30). /31 is the safest point-to-point size
  --mtu <N>                Tunnel MTU (default: 1476)
  --name <ifname>          Tunnel interface name (default: oxytunnel)
  --role <iran|foreign>    iran forwards ports; foreign only brings up GRE
  --ports <list>           Ports to forward on the Iran server (space or comma separated)
  --uninstall              Remove service, health timer, scripts, config, and forward chains
  -h, --help               Show help

Examples:
  sudo ./install.sh --local-ip 203.0.113.10 --remote-ip 203.0.113.20 --tun-ip 10.200.0.1 --peer-ip 10.200.0.2 --cidr 30 --role iran --ports 443,8443
  sudo ./install.sh --local-ip 203.0.113.20 --remote-ip 203.0.113.10 --tun-ip 10.200.0.2 --peer-ip 10.200.0.1 --cidr 30 --role foreign

After install:
  sudo oxytunnel
EOF
}

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  if dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)"; then
    if [[ -f "$dir/oxytunnel-lib.sh" ]]; then
      SCRIPT_DIR="$dir"
    fi
  fi
fi

UNINSTALL=0
LOCAL_IP=""
REMOTE_IP=""
TUN_IP=""
PEER_IP=""
CIDR="30"
MTU="1476"
TUN_NAME="oxytunnel"
ROLE=""
PORTS=""
ROLE_SET=0
PORTS_SET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-ip) LOCAL_IP="${2:-}"; shift 2 ;;
    --remote-ip) REMOTE_IP="${2:-}"; shift 2 ;;
    --tun-ip) TUN_IP="${2:-}"; shift 2 ;;
    --peer-ip) PEER_IP="${2:-}"; shift 2 ;;
    --cidr) CIDR="${2:-}"; shift 2 ;;
    --mtu) MTU="${2:-}"; shift 2 ;;
    --name) TUN_NAME="${2:-}"; shift 2 ;;
    --role) ROLE="${2:-}"; ROLE_SET=1; shift 2 ;;
    --ports) PORTS="${2:-}"; PORTS_SET=1; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

need_root
has ip || die "Missing dependency: ip (iproute2)"
has systemctl || die "Missing dependency: systemctl (systemd)"

drop_named_chain() {
  local table="$1" parent="$2" chain="$3"
  has iptables || return 0
  while iptables -w 5 -t "$table" -D "$parent" -j "$chain" >/dev/null 2>&1; do
    :
  done
  iptables -w 5 -t "$table" -F "$chain" >/dev/null 2>&1 || true
  iptables -w 5 -t "$table" -X "$chain" >/dev/null 2>&1 || true
}

retire_legacy() {
  systemctl disable --now sudotunnel.service >/dev/null 2>&1 || true
  systemctl disable --now sudotunnel-health.timer >/dev/null 2>&1 || true
  ip tunnel del sudotunnel >/dev/null 2>&1 || true
  drop_named_chain nat PREROUTING SUDOTUNNEL_DNAT
  drop_named_chain nat POSTROUTING SUDOTUNNEL_SNAT
  drop_named_chain filter FORWARD SUDOTUNNEL_FWD
  rm -f \
    /usr/local/bin/sudotunnel \
    /usr/local/bin/sudotunnel-up \
    /usr/local/bin/sudotunnel-down \
    /usr/local/bin/sudotunnel-health \
    /etc/systemd/system/sudotunnel.service \
    /etc/systemd/system/sudotunnel-health.service \
    /etc/systemd/system/sudotunnel-health.timer \
    /etc/sudotunnel.conf \
    /etc/sysctl.d/99-sudotunnel.conf
  rm -rf /usr/local/lib/sudotunnel
  systemctl daemon-reload || true
}

uninstall_app() {
  local tun_name="oxytunnel"
  systemctl disable --now oxytunnel-health.timer >/dev/null 2>&1 || true
  systemctl stop oxytunnel.service >/dev/null 2>&1 || true
  systemctl disable oxytunnel.service >/dev/null 2>&1 || true
  if [[ -f /usr/local/lib/oxytunnel/lib.sh && -f "$CONF" ]]; then
    # shellcheck source=/dev/null
    source /usr/local/lib/oxytunnel/lib.sh
    remove_forwards || true
    # shellcheck disable=SC1090
    source "$CONF" || true
    tun_name="${TUN_NAME:-oxytunnel}"
  fi
  ip tunnel del "$tun_name" >/dev/null 2>&1 || true
  retire_legacy
  rm -f \
    "/usr/local/bin/${APP}-up" \
    "/usr/local/bin/${APP}-down" \
    "/usr/local/bin/${APP}-health" \
    "/usr/local/bin/${APP}" \
    "/etc/systemd/system/${APP}.service" \
    "/etc/systemd/system/${APP}-health.service" \
    "/etc/systemd/system/${APP}-health.timer" \
    "$CONF" \
    "/etc/sysctl.d/99-${APP}.conf" \
    "/var/log/${APP}.log"
  rm -rf "/usr/local/lib/${APP}" /run/oxytunnel
  systemctl daemon-reload || true
  echo "Uninstalled ${APP}."
}

if [[ "$UNINSTALL" -eq 1 ]]; then
  uninstall_app
  exit 0
fi

STAGE="$(mktemp -d)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

download() {
  local url="$1" out="$2"
  if has curl; then
    curl -fsSL "$url" -o "$out"
  elif has wget; then
    wget -qO "$out" "$url"
  else
    die "Missing dependency: curl or wget"
  fi
  [[ -s "$out" ]] || die "Download failed: $url"
}

fetch_asset() {
  local name="$1"
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/$name" ]]; then
    cp "$SCRIPT_DIR/$name" "$STAGE/$name"
  else
    download "$BASE_URL/$name" "$STAGE/$name"
  fi
  [[ -s "$STAGE/$name" ]] || die "Missing installer file: $name"
}

ASSETS=(
  oxytunnel-lib.sh
  oxytunnel-up.sh
  oxytunnel-down.sh
  oxytunnel-health.sh
  oxytunnel
  oxytunnel.service
  oxytunnel-health.service
  oxytunnel-health.timer
)

need_download=0
for asset in "${ASSETS[@]}"; do
  if [[ -z "$SCRIPT_DIR" || ! -f "$SCRIPT_DIR/$asset" ]]; then
    need_download=1
  fi
done
if [[ "$need_download" -eq 1 ]]; then
  has curl || has wget || die "Missing dependency: curl or wget"
fi

for asset in "${ASSETS[@]}"; do
  fetch_asset "$asset"
done
# shellcheck source=/dev/null
source "$STAGE/oxytunnel-lib.sh"

collect_tunnel_answers
assert_tunnel_settings
ensure_iran_packages

retire_legacy

install -d /etc /usr/local/bin /usr/local/lib/oxytunnel
write_tunnel_conf

install -m 0644 "$STAGE/oxytunnel-lib.sh" /usr/local/lib/oxytunnel/lib.sh
install -m 0755 "$STAGE/oxytunnel-up.sh" "/usr/local/bin/${APP}-up"
install -m 0755 "$STAGE/oxytunnel-down.sh" "/usr/local/bin/${APP}-down"
install -m 0755 "$STAGE/oxytunnel-health.sh" "/usr/local/bin/${APP}-health"
install -m 0755 "$STAGE/oxytunnel" "/usr/local/bin/${APP}"
install -m 0644 "$STAGE/oxytunnel.service" "/etc/systemd/system/${APP}.service"
install -m 0644 "$STAGE/oxytunnel-health.service" "/etc/systemd/system/${APP}-health.service"
install -m 0644 "$STAGE/oxytunnel-health.timer" "/etc/systemd/system/${APP}-health.timer"
touch "/var/log/${APP}.log"
chmod 640 "/var/log/${APP}.log"

systemctl daemon-reload
systemctl enable "${APP}.service" >/dev/null
systemctl enable oxytunnel-health.timer >/dev/null
if ! systemctl restart "${APP}.service"; then
  journalctl -u "${APP}.service" -n 40 --no-pager >&2 || true
  die "Service failed to start."
fi
systemctl start oxytunnel-health.timer >/dev/null 2>&1 || echo "WARNING: health timer did not start. Check: systemctl status oxytunnel-health.timer"

echo
echo "Installation complete."
echo "GRE is IP protocol 47 and is not encrypted."
if [[ -t 0 && -t 1 ]]; then
  trap - EXIT
  rm -rf "$STAGE"
  exec /usr/local/bin/oxytunnel
fi
echo "Menu: sudo oxytunnel"
