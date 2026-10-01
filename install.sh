#!/usr/bin/env bash
set -euo pipefail

APP="sudotunnel"
CONF="/etc/${APP}.conf"
BASE_URL="https://raw.githubusercontent.com/yasinznl/sudotunnel/main"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ ${EUID:-0} -eq 0 ]] || die "Run as root."; }
has() { command -v "$1" >/dev/null 2>&1; }

prompt() {
  local var="$1" msg="$2" def="${3:-}" val=""
  if [[ -n "$def" ]]; then
    if ! read -r -p "$msg [$def]: " val; then
      die "Input closed before the answer was given."
    fi
    val="${val:-$def}"
  else
    if ! read -r -p "$msg: " val; then
      die "Input closed before the answer was given."
    fi
  fi
  printf -v "$var" '%s' "$val"
}

usage() {
  cat <<EOF
${APP} installer

Usage:
  sudo ./install.sh [options]

Options:
  --local-ip <IPv4>        Public IP of THIS server
  --remote-ip <IPv4>       Public IP of the other server
  --tun-ip <IPv4>          Tunnel IP on THIS server
  --peer-ip <IPv4>         Tunnel IP on the other server
  --cidr <N>               Tunnel prefix (default: 30). /31 is the safest point-to-point size
  --mtu <N>                Tunnel MTU (default: 1476)
  --name <ifname>          Tunnel interface name (default: sudotunnel)
  --role <iran|foreign>    iran forwards ports; foreign only brings up GRE
  --ports <list>           Ports to forward on the Iran server (space or comma separated)
  --uninstall              Remove service, scripts, config, and port-forward chains
  -h, --help               Show help

Examples:
  sudo ./install.sh --local-ip 10.1.1.1 --remote-ip 10.2.2.2 --tun-ip 10.10.0.10 --peer-ip 10.10.0.9 --cidr 30 --role iran --ports 8028,443
  sudo ./install.sh --local-ip 10.2.2.2 --remote-ip 10.1.1.1 --tun-ip 10.10.0.9 --peer-ip 10.10.0.10 --cidr 30 --role foreign

After install:
  sudotunnel status
  sudotunnel port add 8443
  sudotunnel port del 8443
  sudotunnel restart
EOF
}

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  if dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)"; then
    if [[ -f "$dir/sudotunnel-lib.sh" ]]; then
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
TUN_NAME="sudotunnel"
ROLE=""
PORTS=""
CIDR_SET=0
MTU_SET=0
NAME_SET=0
ROLE_SET=0
PORTS_SET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-ip) LOCAL_IP="${2:-}"; shift 2 ;;
    --remote-ip) REMOTE_IP="${2:-}"; shift 2 ;;
    --tun-ip) TUN_IP="${2:-}"; shift 2 ;;
    --peer-ip) PEER_IP="${2:-}"; shift 2 ;;
    --cidr) CIDR="${2:-}"; CIDR_SET=1; shift 2 ;;
    --mtu) MTU="${2:-}"; MTU_SET=1; shift 2 ;;
    --name) TUN_NAME="${2:-}"; NAME_SET=1; shift 2 ;;
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

uninstall_app() {
  local tun_name="sudotunnel"
  systemctl stop "${APP}.service" >/dev/null 2>&1 || true
  systemctl disable "${APP}.service" >/dev/null 2>&1 || true
  if [[ -f /usr/local/lib/sudotunnel/lib.sh ]]; then
    # shellcheck source=/dev/null
    source /usr/local/lib/sudotunnel/lib.sh
    remove_forwards || true
  fi
  if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF" || true
    tun_name="${TUN_NAME:-sudotunnel}"
  fi
  ip tunnel del "$tun_name" 2>/dev/null || true
  rm -f \
    "/usr/local/bin/${APP}-up" \
    "/usr/local/bin/${APP}-down" \
    "/usr/local/bin/${APP}" \
    "/etc/systemd/system/${APP}.service" \
    "$CONF" \
    /etc/sysctl.d/99-sudotunnel.conf
  rm -rf /usr/local/lib/sudotunnel
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

need_download=0
for asset in sudotunnel-lib.sh sudotunnel-up.sh sudotunnel-down.sh sudotunnel sudotunnel.service; do
  if [[ -z "$SCRIPT_DIR" || ! -f "$SCRIPT_DIR/$asset" ]]; then
    need_download=1
  fi
done
if [[ "$need_download" -eq 1 ]]; then
  has curl || has wget || die "Missing dependency: curl or wget"
fi

fetch_asset sudotunnel-lib.sh
fetch_asset sudotunnel-up.sh
fetch_asset sudotunnel-down.sh
fetch_asset sudotunnel
fetch_asset sudotunnel.service
# shellcheck source=/dev/null
source "$STAGE/sudotunnel-lib.sh"

if [[ "$CIDR_SET" -eq 0 ]]; then
  prev="$(conf_get CIDR)"
  [[ -n "$prev" ]] && CIDR="$prev"
fi
if [[ "$MTU_SET" -eq 0 ]]; then
  prev="$(conf_get MTU)"
  [[ -n "$prev" ]] && MTU="$prev"
fi
if [[ "$NAME_SET" -eq 0 ]]; then
  prev="$(conf_get TUN_NAME)"
  [[ -n "$prev" ]] && TUN_NAME="$prev"
fi

while ! is_ipv4 "$LOCAL_IP"; do
  prompt LOCAL_IP "Public IP of THIS server" "$(conf_get LOCAL_IP)"
done
while ! is_ipv4 "$REMOTE_IP"; do
  prompt REMOTE_IP "Public IP of the OTHER server" "$(conf_get REMOTE_IP)"
done
while ! is_ipv4 "$TUN_IP"; do
  prompt TUN_IP "Tunnel IP on THIS server" "$(conf_get TUN_IP)"
done
while ! is_ipv4 "$PEER_IP"; do
  prompt PEER_IP "Tunnel IP on the OTHER server" "$(conf_get PEER_IP)"
done

[[ "$LOCAL_IP" != "$REMOTE_IP" ]] || die "The two public IPs must be different."
[[ "$TUN_IP" != "$PEER_IP" ]] || die "The two tunnel IPs must be different."
[[ "$CIDR" =~ ^[0-9]+$ ]] || die "Invalid --cidr"
CIDR=$((10#$CIDR))
(( CIDR >= 1 && CIDR <= 32 )) || die "Invalid --cidr"
[[ "$MTU" =~ ^[0-9]+$ ]] || die "Invalid --mtu"
MTU=$((10#$MTU))
(( MTU >= 576 && MTU <= 9000 )) || die "MTU must be between 576 and 9000."
[[ "$TUN_NAME" =~ ^[A-Za-z0-9._:-]{1,15}$ ]] || die "Invalid interface name."

ip_to_int() {
  local a b c d
  IFS='.' read -r a b c d <<<"$1"
  echo $(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))
}
int_to_ip() {
  local n="$1"
  echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

if (( CIDR <= 31 )); then
  mask=$(( (0xFFFFFFFF << (32 - CIDR)) & 0xFFFFFFFF ))
  net_tun=$(( $(ip_to_int "$TUN_IP") & mask ))
  net_peer=$(( $(ip_to_int "$PEER_IP") & mask ))
  [[ "$net_tun" -eq "$net_peer" ]] || die "Tunnel IP and peer IP are not in the same /${CIDR} network."
fi

if [[ "$CIDR" == "30" ]]; then
  tun_i="$(ip_to_int "$TUN_IP")"
  net_i=$(( tun_i & 0xFFFFFFFC ))
  bcast_i=$(( net_i + 3 ))
  net_ip="$(int_to_ip "$net_i")"
  bcast_ip="$(int_to_ip "$bcast_i")"
  [[ "$TUN_IP" != "$net_ip" && "$TUN_IP" != "$bcast_ip" ]] || die "For /30, the tunnel IP cannot be the network or broadcast address."
  [[ "$PEER_IP" != "$net_ip" && "$PEER_IP" != "$bcast_ip" ]] || die "For /30, the peer IP cannot be the network or broadcast address."
fi

if [[ "$ROLE_SET" -eq 1 ]]; then
  ROLE="$(normalize_role "$ROLE")" || die "Invalid --role. Use iran or foreign."
elif [[ -t 0 ]]; then
  def_role="$(conf_get ROLE)"
  while true; do
    prompt ROLE "Role of THIS server (iran/ایران forwards ports, foreign/خارج is the panel)" "$def_role"
    if ROLE="$(normalize_role "$ROLE")"; then
      break
    fi
    echo "Enter iran or foreign."
    ROLE=""
    def_role=""
  done
else
  ROLE="foreign"
fi

if [[ "$ROLE" == "iran" ]]; then
  if [[ "$PORTS_SET" -eq 1 ]]; then
    PORTS="$(parse_ports "$PORTS")" || die "Invalid --ports."
    [[ -n "$PORTS" ]] || die "The Iran side needs at least one port. Example: --ports 8028,443"
  elif [[ -t 0 ]]; then
    def_ports="$(conf_get PORTS)"
    PORTS=""
    while [[ -z "$PORTS" ]]; do
      prompt PORTS "Ports to forward to the foreign tunnel IP (example: 8028 443)" "$def_ports"
      if ! PORTS="$(parse_ports "$PORTS")"; then
        echo "Use ports from 1 to 65535, separated by spaces or commas."
        PORTS=""
        def_ports=""
        continue
      fi
      if [[ -z "$PORTS" ]]; then
        echo "Enter at least one port."
        def_ports=""
      fi
    done
  else
    die "Non-interactive Iran install needs --ports. Example: --ports 8028,443"
  fi
else
  if [[ "$PORTS_SET" -eq 1 && -n "$PORTS" ]]; then
    echo "Note: ports are forwarded only on the Iran server. Ignoring --ports here."
  fi
  PORTS=""
fi

if [[ "$ROLE" == "iran" ]]; then
  if ! has iptables || { has apt-get && ! dpkg -s iptables-persistent >/dev/null 2>&1; }; then
    if has apt-get; then
      DEBIAN_FRONTEND=noninteractive apt-get update
    fi
  fi
  if ! has iptables; then
    if has apt-get; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y iptables
    elif has dnf; then
      dnf install -y iptables
    elif has yum; then
      yum install -y iptables
    elif has apk; then
      apk add --no-cache iptables
    else
      die "iptables is missing and no supported package manager was found."
    fi
  fi
  has iptables || die "iptables installation failed."
  if has apt-get && ! dpkg -s iptables-persistent >/dev/null 2>&1; then
    if has debconf-set-selections; then
      echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
      echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent || true
  fi
fi

install -d /etc /usr/local/bin /usr/local/lib/sudotunnel
cat >"$CONF" <<EOF
TUN_NAME="${TUN_NAME}"
LOCAL_IP="${LOCAL_IP}"
REMOTE_IP="${REMOTE_IP}"
TUN_IP="${TUN_IP}"
PEER_IP="${PEER_IP}"
CIDR="${CIDR}"
MTU="${MTU}"
ROLE="${ROLE}"
PORTS="${PORTS}"
EOF
chmod 600 "$CONF"

install -m 0644 "$STAGE/sudotunnel-lib.sh" /usr/local/lib/sudotunnel/lib.sh
install -m 0755 "$STAGE/sudotunnel-up.sh" "/usr/local/bin/${APP}-up"
install -m 0755 "$STAGE/sudotunnel-down.sh" "/usr/local/bin/${APP}-down"
install -m 0755 "$STAGE/sudotunnel" "/usr/local/bin/${APP}"
install -m 0644 "$STAGE/sudotunnel.service" "/etc/systemd/system/${APP}.service"

systemctl daemon-reload
systemctl enable "${APP}.service" >/dev/null
if ! systemctl restart "${APP}.service"; then
  journalctl -u "${APP}.service" -n 40 --no-pager >&2 || true
  die "Service failed to start."
fi

echo "Installed ${APP}."
echo "Role: ${ROLE}"
echo "Tunnel: ${TUN_IP}/${CIDR} <-> ${PEER_IP} (${TUN_NAME})"
if [[ "$ROLE" == "iran" ]]; then
  echo "Forward: ${LOCAL_IP} ports [${PORTS}] -> ${PEER_IP}"
  echo "Clients connect to ${LOCAL_IP}. On the foreign panel, leave Listen empty (0.0.0.0), not the Iran IP."
else
  echo "This side only keeps the GRE tunnel up."
  echo "Set the same ports on the Iran server. In the panel, listen on 0.0.0.0."
fi
echo "Check: sudotunnel status"
echo "Change ports: sudotunnel port add <port>    sudotunnel port del <port>    sudotunnel restart"
echo "Test: ping ${PEER_IP}"
echo "GRE is IP protocol 47. The firewall and the provider must allow it. GRE is not encrypted."
