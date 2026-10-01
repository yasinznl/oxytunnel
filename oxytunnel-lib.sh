#!/usr/bin/env bash
# Shared helpers for oxytunnel. Sourced by the installer, the CLI, and systemd scripts.

APP="oxytunnel"
BASE_URL="https://raw.githubusercontent.com/yasinznl/oxytunnel/main"
CONF="/etc/${APP}.conf"
SYSCTL_FILE="/etc/sysctl.d/99-${APP}.conf"
LOG_FILE="/var/log/${APP}.log"
RUN_DIR="/run/${APP}"
CHAIN_DNAT="OXYTUNNEL_DNAT"
CHAIN_SNAT="OXYTUNNEL_SNAT"
CHAIN_FWD="OXYTUNNEL_FWD"
UNIT="${APP}.service"

die() { echo "ERROR: $*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-0} -eq 0 ]] || die "Management requires root. Run: sudo ${APP}"
}

is_ipv4() {
  local ip="${1:-}" x
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local a b c d
  IFS='.' read -r a b c d <<<"$ip"
  for x in "$a" "$b" "$c" "$d"; do
    [[ "$x" =~ ^[0-9]+$ ]] || return 1
    (( 10#$x >= 0 && 10#$x <= 255 )) || return 1
  done
  return 0
}

normalize_role() {
  local r
  r="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  r="${r#"${r%%[![:space:]]*}"}"
  r="${r%"${r##*[![:space:]]}"}"
  case "$r" in
    iran|foreign) printf '%s\n' "$r" ;;
    *) return 1 ;;
  esac
}

# Print a unique space-separated port list. Empty input is valid.
parse_ports() {
  local raw="${1:-}" p out="" part
  local -a parts=()
  raw="${raw//,/ }"
  raw="${raw//$'\t'/ }"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  if [[ -z "$raw" ]]; then
    printf '\n'
    return 0
  fi
  read -r -a parts <<<"$raw"
  for part in "${parts[@]}"; do
    p="$part"
    if [[ ! "$p" =~ ^[0-9]+$ ]] || (( 10#$p < 1 || 10#$p > 65535 )); then
      echo "Invalid port: $p" >&2
      return 1
    fi
    p=$((10#$p))
    case " $out " in
      *" $p "*) ;;
      *) out="${out:+$out }$p" ;;
    esac
  done
  printf '%s\n' "$out"
}

conf_get() {
  local key="$1" line
  [[ -f "$CONF" ]] || return 0
  line="$(grep -E "^${key}=" "$CONF" | tail -n 1 || true)"
  line="${line#*=}"
  line="${line#\"}"
  line="${line%\"}"
  printf '%s' "$line"
}

conf_set() {
  local key="$1" val="$2" tmp
  [[ "$key" =~ ^[A-Z0-9_]+$ ]] || die "Refusing to write invalid config key."
  [[ "$val" != *\"* && "$val" != *\$* && "$val" != *\`* ]] || die "Refusing to write an unsafe config value."
  [[ -f "$CONF" ]] || die "Missing $CONF"
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$val" '
    index($0, k "=") == 1 { print k "=\"" v "\""; found = 1; next }
    { print }
    END { if (!found) print k "=\"" v "\"" }
  ' "$CONF" >"$tmp"
  cat "$tmp" >"$CONF"
  rm -f "$tmp"
  chmod 600 "$CONF"
}

load_conf() {
  [[ -f "$CONF" ]] || die "Missing $CONF"
  # shellcheck disable=SC1090
  source "$CONF"
  TUN_NAME="${TUN_NAME:-oxytunnel}"
  CIDR="${CIDR:-30}"
  MTU="${MTU:-1476}"
  ROLE="${ROLE:-foreign}"
  PEER_IP="${PEER_IP:-}"
  PORTS="${PORTS:-}"
  [[ "$TUN_NAME" =~ ^[A-Za-z0-9._:-]{1,15}$ ]] || die "Invalid TUN_NAME in $CONF"
  if ! ROLE="$(normalize_role "$ROLE")"; then
    die "Invalid ROLE in $CONF (use iran or foreign)"
  fi
  if ! PORTS="$(parse_ports "$PORTS")"; then
    die "Invalid PORTS in $CONF"
  fi
}

log_event() {
  local level="$1" msg="$2" pri="user.notice" bytes=0 trimmed
  case "$level" in
    err|error) pri="user.err" ;;
    warn|warning) pri="user.warning" ;;
  esac
  touch "$LOG_FILE" 2>/dev/null || true
  chmod 640 "$LOG_FILE" 2>/dev/null || true
  printf '%s %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$msg" >>"$LOG_FILE" 2>/dev/null || true
  if command -v logger >/dev/null 2>&1; then
    logger -t "$APP" -p "$pri" -- "$msg" 2>/dev/null || true
  fi
  if [[ -f "$LOG_FILE" ]]; then
    bytes="$(wc -c <"$LOG_FILE" | tr -d '[:space:]')"
    if [[ "$bytes" =~ ^[0-9]+$ ]] && (( bytes > 1048576 )); then
      trimmed="$(mktemp)"
      tail -n 2000 "$LOG_FILE" >"$trimmed" 2>/dev/null || true
      cat "$trimmed" >"$LOG_FILE" 2>/dev/null || true
      rm -f "$trimmed"
      chmod 640 "$LOG_FILE" 2>/dev/null || true
    fi
  fi
  return 0
}

persist_ip_forward() {
  mkdir -p /etc/sysctl.d
  printf 'net.ipv4.ip_forward=1\n' >"$SYSCTL_FILE"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

save_iptables() {
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
    return 0
  fi
  if [[ -d /etc/iptables ]] && command -v iptables-save >/dev/null 2>&1; then
    iptables-save > /etc/iptables/rules.v4
  fi
}

ipt() {
  command iptables -w 5 "$@"
}

ensure_chain() {
  local table="$1" parent="$2" chain="$3"
  ipt -t "$table" -N "$chain" >/dev/null 2>&1 || true
  while ipt -t "$table" -D "$parent" -j "$chain" >/dev/null 2>&1; do
    :
  done
  ipt -t "$table" -I "$parent" 1 -j "$chain"
  ipt -t "$table" -F "$chain"
}

drop_chain() {
  local table="$1" parent="$2" chain="$3"
  command -v iptables >/dev/null 2>&1 || return 0
  while ipt -t "$table" -D "$parent" -j "$chain" >/dev/null 2>&1; do
    :
  done
  ipt -t "$table" -F "$chain" >/dev/null 2>&1 || true
  ipt -t "$table" -X "$chain" >/dev/null 2>&1 || true
  return 0
}

remove_forwards() {
  drop_chain nat PREROUTING "$CHAIN_DNAT"
  drop_chain nat POSTROUTING "$CHAIN_SNAT"
  drop_chain filter FORWARD "$CHAIN_FWD"
  save_iptables
}

apply_forwards() {
  local p
  [[ "$ROLE" == "iran" ]] || die "Port forward runs only on the Iran side."
  [[ -n "${PEER_IP:-}" ]] || die "PEER_IP is empty in $CONF"
  is_ipv4 "$PEER_IP" || die "PEER_IP in $CONF is not an IPv4 address."
  command -v iptables >/dev/null 2>&1 || die "iptables is not installed. Re-run install.sh on this Iran server."
  modprobe nf_conntrack 2>/dev/null || true
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    log_event warn "firewalld is active and may override port forwards"
  fi
  persist_ip_forward
  ensure_chain nat PREROUTING "$CHAIN_DNAT"
  ensure_chain nat POSTROUTING "$CHAIN_SNAT"
  ensure_chain filter FORWARD "$CHAIN_FWD"
  if ! ipt -t filter -A "$CHAIN_FWD" -d "$PEER_IP" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT \
    || ! ipt -t filter -A "$CHAIN_FWD" -s "$PEER_IP" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; then
    log_event warn "conntrack match is unavailable; FORWARD policy must accept return traffic"
  fi
  for p in $PORTS; do
    ipt -t nat -A "$CHAIN_DNAT" -p tcp --dport "$p" -j DNAT --to-destination "${PEER_IP}:${p}"
    ipt -t nat -A "$CHAIN_DNAT" -p udp --dport "$p" -j DNAT --to-destination "${PEER_IP}:${p}"
    ipt -t filter -A "$CHAIN_FWD" -d "$PEER_IP" -p tcp --dport "$p" -j ACCEPT
    ipt -t filter -A "$CHAIN_FWD" -d "$PEER_IP" -p udp --dport "$p" -j ACCEPT
  done
  if [[ -n "${PORTS:-}" ]]; then
    ipt -t nat -A "$CHAIN_SNAT" -d "$PEER_IP" -j MASQUERADE
  fi
  save_iptables
  log_event notice "forward rules applied for role ${ROLE} ports [${PORTS:-none}]"
}

bring_up() {
  command -v ip >/dev/null 2>&1 || die "Missing dependency: ip (iproute2)"
  is_ipv4 "${LOCAL_IP:-}" || die "LOCAL_IP is invalid"
  is_ipv4 "${REMOTE_IP:-}" || die "REMOTE_IP is invalid"
  is_ipv4 "${TUN_IP:-}" || die "TUN_IP is invalid"
  [[ "${MTU:-}" =~ ^[0-9]+$ ]] || die "MTU is invalid"
  [[ "${CIDR:-}" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]] || die "CIDR is invalid"
  modprobe ip_gre 2>/dev/null || true
  ip tunnel del "$TUN_NAME" 2>/dev/null || true
  ip tunnel add "$TUN_NAME" mode gre remote "$REMOTE_IP" local "$LOCAL_IP" ttl 255
  ip link set "$TUN_NAME" mtu "$MTU" up
  ip addr replace "${TUN_IP}/${CIDR}" dev "$TUN_NAME"
}

bring_down() {
  if [[ -n "${TUN_NAME:-}" ]]; then
    ip tunnel del "$TUN_NAME" 2>/dev/null || true
  fi
}

restart_service() {
  systemctl daemon-reload
  systemctl enable "${UNIT}" >/dev/null
  log_event notice "restart requested"
  if ! systemctl restart "${UNIT}"; then
    log_event err "restart failed"
    journalctl -u "${UNIT}" -n 40 --no-pager >&2 || true
    die "${APP} failed to restart."
  fi
  log_event notice "restart finished"
}

# Print a reason and return 1 when the tunnel is not usable.
probe_tunnel() {
  local flags="" addr=""
  if ! ip link show "$TUN_NAME" >/dev/null 2>&1; then
    printf '%s\n' "interface ${TUN_NAME} is missing"
    return 1
  fi
  flags="$(ip -o link show "$TUN_NAME" 2>/dev/null | awk '{print $3}')"
  if [[ "$flags" != *UP* ]]; then
    printf '%s\n' "interface ${TUN_NAME} is down"
    return 1
  fi
  addr="$(ip -4 addr show dev "$TUN_NAME" 2>/dev/null || true)"
  if [[ "$addr" != *"inet ${TUN_IP}/"* && "$addr" != *"inet ${TUN_IP} "* ]]; then
    printf '%s\n' "address ${TUN_IP} is missing on ${TUN_NAME}"
    return 1
  fi
  if [[ -z "${PEER_IP:-}" ]]; then
    printf '%s\n' "peer address is empty"
    return 1
  fi
  if ! command -v ping >/dev/null 2>&1; then
    printf '%s\n' "ok"
    return 0
  fi
  if ! ping -c 2 -W 2 "$PEER_IP" >/dev/null 2>&1; then
    printf '%s\n' "peer ${PEER_IP} did not answer"
    return 1
  fi
  printf '%s\n' "ok"
  return 0
}

watch_tunnel() {
  local reason fails=0 now last state
  mkdir -p "$RUN_DIR"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${RUN_DIR}/health.lock"
    flock -n 9 || return 0
  fi
  if [[ ! -f "$CONF" ]]; then
    log_event err "health check skipped, missing ${CONF}"
    return 0
  fi
  state="$(systemctl show -p ActiveState --value "${UNIT}" 2>/dev/null || true)"
  case "$state" in
    activating|deactivating) return 0 ;;
    inactive)
      return 0
      ;;
    failed)
      log_event err "service ${UNIT} is failed; restarting"
      date +%s >"${RUN_DIR}/last-restart"
      systemctl reset-failed "${UNIT}" >/dev/null 2>&1 || true
      systemctl restart "${UNIT}" || log_event err "automatic restart failed"
      return 0
      ;;
  esac
  load_conf
  if reason="$(probe_tunnel)"; then
    if [[ -f "${RUN_DIR}/unhealthy" ]]; then
      log_event notice "tunnel recovered on ${TUN_NAME}"
      rm -f "${RUN_DIR}/unhealthy" "${RUN_DIR}/fails"
    fi
    return 0
  fi
  printf '%s\n' "$reason" >"${RUN_DIR}/unhealthy"
  if [[ -f "${RUN_DIR}/fails" ]]; then
    fails="$(tr -d '[:space:]' <"${RUN_DIR}/fails")"
  fi
  [[ "$fails" =~ ^[0-9]+$ ]] || fails=0
  fails=$((fails + 1))
  printf '%s\n' "$fails" >"${RUN_DIR}/fails"
  log_event warn "tunnel unhealthy (${fails}): ${reason}"
  if (( fails < 2 )); then
    return 0
  fi
  now="$(date +%s)"
  last=0
  if [[ -f "${RUN_DIR}/last-restart" ]]; then
    last="$(tr -d '[:space:]' <"${RUN_DIR}/last-restart")"
  fi
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( now - last < 90 )); then
    log_event warn "automatic restart skipped during cooldown: ${reason}"
    return 0
  fi
  log_event err "tunnel down, restarting: ${reason}"
  printf '%s\n' "$now" >"${RUN_DIR}/last-restart"
  printf '%s\n' "0" >"${RUN_DIR}/fails"
  if systemctl restart "${UNIT}"; then
    log_event notice "automatic restart finished"
  else
    log_event err "automatic restart failed: ${reason}"
  fi
}

ask_line() {
  local var="$1" msg="$2" def="${3:-}" val=""
  if [[ -n "$def" ]]; then
    read -r -p "$msg [$def]: " val || die "Input closed before the answer was given."
    val="${val:-$def}"
  else
    read -r -p "$msg: " val || die "Input closed before the answer was given."
  fi
  printf -v "$var" '%s' "$val"
}

detect_local_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  if ! is_ipv4 "${ip:-}"; then
    if command -v curl >/dev/null 2>&1; then
      ip="$(curl -4 -fsSL --max-time 4 https://api.ipify.org 2>/dev/null || true)"
      ip="${ip//$'\r'/}"
      ip="${ip//$'\n'/}"
    fi
  fi
  if is_ipv4 "${ip:-}"; then
    printf '%s\n' "$ip"
    return 0
  fi
  return 1
}

ip_to_int() {
  local a b c d
  IFS='.' read -r a b c d <<<"$1"
  echo $(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))
}

int_to_ip() {
  local n="$1"
  echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

assert_tunnel_settings() {
  local mask net_tun net_peer tun_i net_i bcast_i net_ip bcast_ip
  [[ "${LOCAL_IP:-}" != "${REMOTE_IP:-}" ]] || die "The two public IPs must be different."
  [[ "${TUN_IP:-}" != "${PEER_IP:-}" ]] || die "The two tunnel IPs must be different."
  is_ipv4 "${LOCAL_IP:-}" || die "Local public IP is invalid."
  is_ipv4 "${REMOTE_IP:-}" || die "Remote public IP is invalid."
  is_ipv4 "${TUN_IP:-}" || die "Tunnel IP is invalid."
  is_ipv4 "${PEER_IP:-}" || die "Peer tunnel IP is invalid."
  CIDR="${CIDR:-30}"
  MTU="${MTU:-1476}"
  TUN_NAME="${TUN_NAME:-oxytunnel}"
  [[ "$CIDR" =~ ^[0-9]+$ ]] || die "Invalid CIDR."
  CIDR=$((10#$CIDR))
  (( CIDR >= 1 && CIDR <= 32 )) || die "CIDR must be between 1 and 32."
  [[ "$MTU" =~ ^[0-9]+$ ]] || die "Invalid MTU."
  MTU=$((10#$MTU))
  (( MTU >= 576 && MTU <= 9000 )) || die "MTU must be between 576 and 9000."
  [[ "$TUN_NAME" =~ ^[A-Za-z0-9._:-]{1,15}$ ]] || die "Invalid interface name."
  ROLE="$(normalize_role "${ROLE:-}")" || die "Role must be iran or foreign."
  if [[ "$ROLE" == "iran" ]]; then
    PORTS="$(parse_ports "${PORTS:-}")" || die "Invalid port list."
    [[ -n "$PORTS" ]] || die "The Iran side needs at least one port."
  else
    PORTS=""
  fi
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
}

write_tunnel_conf() {
  local old_umask
  old_umask="$(umask)"
  umask 077
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
  umask "$old_umask"
}

ensure_iran_packages() {
  [[ "${ROLE:-}" == "iran" ]] || return 0
  if ! command -v iptables >/dev/null 2>&1 || { command -v apt-get >/dev/null 2>&1 && ! dpkg -s iptables-persistent >/dev/null 2>&1; }; then
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get update
    fi
  fi
  if ! command -v iptables >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y iptables
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y iptables
    elif command -v yum >/dev/null 2>&1; then
      yum install -y iptables
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache iptables
    else
      die "iptables is missing and no supported package manager was found."
    fi
  fi
  command -v iptables >/dev/null 2>&1 || die "iptables installation failed."
  if command -v apt-get >/dev/null 2>&1 && ! dpkg -s iptables-persistent >/dev/null 2>&1; then
    if command -v debconf-set-selections >/dev/null 2>&1; then
      echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
      echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent || true
  fi
}

collect_tunnel_answers() {
  local detected=""
  local show_header=0
  CIDR="${CIDR:-30}"
  MTU="${MTU:-1476}"
  TUN_NAME="${TUN_NAME:-oxytunnel}"
  if [[ -t 0 ]]; then
    if [[ "${ROLE_SET:-0}" -eq 0 && -z "${ROLE:-}" ]]; then show_header=1; fi
    if ! is_ipv4 "${LOCAL_IP:-}"; then show_header=1; fi
    if ! is_ipv4 "${REMOTE_IP:-}"; then show_header=1; fi
    if ! is_ipv4 "${TUN_IP:-}"; then show_header=1; fi
    if ! is_ipv4 "${PEER_IP:-}"; then show_header=1; fi
    if [[ "$show_header" -eq 1 ]]; then
      echo
      echo "Oxytunnel setup"
      echo "Choose iran or foreign first. Press Enter to accept a value shown in brackets."
      echo
    fi
  fi
  if [[ "${ROLE_SET:-0}" -eq 1 || -n "${ROLE:-}" ]]; then
    ROLE="$(normalize_role "${ROLE:-}")" || die "Invalid role. Use iran or foreign."
  elif [[ -t 0 ]]; then
    while true; do
      ask_line ROLE "Role of this server (iran or foreign)"
      if ROLE="$(normalize_role "$ROLE")"; then
        break
      fi
      echo "Enter iran or foreign."
      ROLE=""
    done
  else
    ROLE="foreign"
  fi
  detected="$(detect_local_ip || true)"
  while ! is_ipv4 "${LOCAL_IP:-}"; do
    if [[ -t 0 ]]; then
      ask_line LOCAL_IP "Public IP of this server" "$detected"
    else
      die "Missing --local-ip."
    fi
  done
  while ! is_ipv4 "${REMOTE_IP:-}"; do
    if [[ -t 0 ]]; then
      ask_line REMOTE_IP "Public IP of the other server"
    else
      die "Missing --remote-ip."
    fi
  done
  while ! is_ipv4 "${TUN_IP:-}"; do
    if [[ -t 0 ]]; then
      ask_line TUN_IP "Tunnel IP on this server"
    else
      die "Missing --tun-ip."
    fi
  done
  while ! is_ipv4 "${PEER_IP:-}"; do
    if [[ -t 0 ]]; then
      ask_line PEER_IP "Tunnel IP on the other server"
    else
      die "Missing --peer-ip."
    fi
  done
  if [[ "$ROLE" == "iran" ]]; then
    if [[ "${PORTS_SET:-0}" -eq 1 ]]; then
      PORTS="$(parse_ports "${PORTS:-}")" || die "Invalid --ports."
      [[ -n "$PORTS" ]] || die "The Iran side needs at least one port. Example: --ports 443,8443"
    elif [[ -t 0 ]]; then
      PORTS=""
      while [[ -z "$PORTS" ]]; do
        ask_line PORTS "Ports to forward (example: 443 8443)"
        if ! PORTS="$(parse_ports "$PORTS")"; then
          echo "Use ports from 1 to 65535, separated by spaces or commas."
          PORTS=""
          continue
        fi
        if [[ -z "$PORTS" ]]; then
          echo "Enter at least one port."
        fi
      done
    else
      die "Non-interactive Iran install needs --ports. Example: --ports 443,8443"
    fi
  else
    if [[ "${PORTS_SET:-0}" -eq 1 && -n "${PORTS:-}" ]]; then
      echo "Ports are forwarded only on the Iran server. Ignoring --ports here."
    fi
    PORTS=""
  fi
}
