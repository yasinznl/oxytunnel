#!/usr/bin/env bash
# Shared helpers for oxytunnel. Sourced by the installer, the CLI, and systemd scripts.

APP="oxytunnel"
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
  local flags
  if ! ip link show "$TUN_NAME" >/dev/null 2>&1; then
    printf '%s\n' "interface ${TUN_NAME} is missing"
    return 1
  fi
  flags="$(ip -o link show "$TUN_NAME" 2>/dev/null | awk '{print $3}')"
  if [[ "$flags" != *UP* ]]; then
    printf '%s\n' "interface ${TUN_NAME} is down"
    return 1
  fi
  if ! ip -4 addr show dev "$TUN_NAME" 2>/dev/null | grep -q "inet ${TUN_IP}/"; then
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
