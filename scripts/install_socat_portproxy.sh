#!/usr/bin/env bash
# install_socat_portproxy.sh
# End-to-end installer for port forwarding 514 -> 1514 using socat (and optional nftables).
# - Creates a dedicated non-root user with CAP_NET_BIND_SERVICE via systemd
# - Builds systemd units for UDP/TCP as requested
# - Optional MODE=nft to preserve source IP when the destination is on the same host
#
# Usage (quick):
#   sudo ./install_socat_portproxy.sh
#   sudo SRC_PORT=514 DST_HOST=10.10.0.11 DST_PORT=1514 PROTOS=udp ./install_socat_portproxy.sh
#
# CLI flags override env vars:
#   -m, --mode [socat|nft]      default: socat
#   -p, --protos "udp,tcp"      default: udp
#   -s, --src-ip 0.0.0.0        default: 0.0.0.0
#   -S, --src-port 514          default: 514
#   -d, --dst-host 127.0.0.1    default: 127.0.0.1
#   -D, --dst-port 1514         default: 1514
#   -n, --name syslog514to1514  default: syslog514to1514
#   --uninstall                 remove services/rules
#
# Notes:
# - socat mode: simple port proxy (source IP will be the proxy host)
# - nft mode: on the same host as the destination service, preserves original source IP

set -euo pipefail

MODE="${MODE:-socat}"            # socat | nft
PROTOS="${PROTOS:-udp}"          # comma-separated: udp,tcp
SRC_IP="${SRC_IP:-0.0.0.0}"
SRC_PORT="${SRC_PORT:-514}"
DST_HOST="${DST_HOST:-127.0.0.1}"
DST_PORT="${DST_PORT:-1514}"
NAME="${NAME:-syslog514to1514}"

UNINSTALL=0
PORTUSER="portproxy"

usage() {
  cat <<USAGE
Usage:
  sudo $0 [options]

Options:
  -m, --mode [socat|nft]     Forwarding mode (default: socat)
  -p, --protos "udp,tcp"     Protocols to forward (default: udp)
  -s, --src-ip IP            Source bind IP (default: 0.0.0.0)
  -S, --src-port PORT        Source listening port (default: 514)
  -d, --dst-host HOST        Destination host (default: 127.0.0.1)
  -D, --dst-port PORT        Destination port (default: 1514)
  -n, --name NAME            Instance name (default: syslog514to1514)
      --uninstall            Remove services/rules and exit
  -h, --help                 Show help

Examples:
  sudo $0
  sudo $0 -p "udp,tcp" -d 10.10.0.11 -D 1514
  sudo MODE=nft $0 -p udp -S 514 -D 1514
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--mode) MODE="$2"; shift 2;;
    -p|--protos) PROTOS="$2"; shift 2;;
    -s|--src-ip) SRC_IP="$2"; shift 2;;
    -S|--src-port) SRC_PORT="$2"; shift 2;;
    -d|--dst-host) DST_HOST="$2"; shift 2;;
    -D|--dst-port) DST_PORT="$2"; shift 2;;
    -n|--name) NAME="$2"; shift 2;;
    --uninstall) UNINSTALL=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root." >&2
  exit 1
fi

enable_services() {
  systemctl daemon-reload
  for svc in "$@"; do
    systemctl enable --now "$svc"
    systemctl --no-pager --full status "$svc" || true
  done
}

disable_services() {
  for svc in "$@"; do
    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}"
  done
  systemctl daemon-reload
}

install_pkgs() {
  apt-get update
  apt-get install -y "$@"
}

if [[ "$UNINSTALL" -eq 1 ]]; then
  if [[ "$MODE" = "socat" ]]; then
    SVCs=()
    [[ "$PROTOS" = *udp* ]] && SVCs+=("socat-${NAME}-udp.service")
    [[ "$PROTOS" = *tcp* ]] && SVCs+=("socat-${NAME}-tcp.service")
    disable_services "${SVCs[@]}"
    id -u "$PORTUSER" >/dev/null 2>&1 && userdel "$PORTUSER" 2>/dev/null || true
    echo "Removed socat services. (User ${PORTUSER} may remain if used elsewhere.)"
  elif [[ "$MODE" = "nft" ]]; then
    install_pkgs nftables
    nft list tables 2>/dev/null | grep -q 'portproxy' && nft delete table inet portproxy || true
    if [[ -d /etc/nftables.d ]]; then rm -f /etc/nftables.d/portproxy.nft; fi
    systemctl enable --now nftables
    systemctl restart nftables
    echo "Removed nftables portproxy rules."
  fi
  exit 0
fi

case "$MODE" in
  socat|nft) :;;
  *) echo "Invalid MODE: $MODE (valid: socat|nft)"; exit 1;;
esac

if ss -lntu | awk '{print $4}' | grep -q ":${SRC_PORT}$"; then
  echo "Warning: something is already listening on port ${SRC_PORT}. Socat/nft may fail." >&2
fi

if [[ "$MODE" = "socat" ]]; then
  install_pkgs socat
  id -u "$PORTUSER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$PORTUSER"

  units=()

  if [[ "$PROTOS" = *udp* ]]; then
cat >"/etc/systemd/system/socat-${NAME}-udp.service" <<EOF
[Unit]
Description=Socat UDP proxy ${SRC_IP}:${SRC_PORT} -> ${DST_HOST}:${DST_PORT} (${NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${PORTUSER}
Group=${PORTUSER}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/bin/socat -s -u UDP-LISTEN:${SRC_PORT},fork,reuseaddr,so-reuseport,bind=${SRC_IP} UDP:${DST_HOST}:${DST_PORT}
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    units+=("socat-${NAME}-udp.service")
  fi

  if [[ "$PROTOS" = *tcp* ]]; then
cat >"/etc/systemd/system/socat-${NAME}-tcp.service" <<EOF
[Unit]
Description=Socat TCP proxy ${SRC_IP}:${SRC_PORT} -> ${DST_HOST}:${DST_PORT} (${NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${PORTUSER}
Group=${PORTUSER}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/bin/socat -s TCP-LISTEN:${SRC_PORT},fork,reuseaddr,keepalive,bind=${SRC_IP} TCP:${DST_HOST}:${DST_PORT}
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    units+=("socat-${NAME}-tcp.service")
  fi

  enable_services "${units[@]}"
  echo
  echo "== Health checks =="
  echo "Listening sockets:"
  ss -lntu | egrep ":${SRC_PORT}\b|:${DST_PORT}\b" || true
  echo
  echo "Send a test (UDP):"
  echo "  echo \"<13>TEST via socat\" | nc -u -w1 127.0.0.1 ${SRC_PORT}"
  echo
  exit 0
fi

# nft mode
install_pkgs nftables

mkdir -p /etc/nftables.d

cat > /etc/nftables.d/portproxy.nft <<EOF
table inet portproxy {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    $( [[ "$PROTOS" = *udp* ]] && echo "ip protocol udp udp dport ${SRC_PORT} redirect to ${DST_PORT}" )
    $( [[ "$PROTOS" = *tcp* ]] && echo "ip protocol tcp tcp dport ${SRC_PORT} redirect to ${DST_PORT}" )
  }
  chain output {
    type nat hook output priority -100; policy accept;
    $( [[ "$PROTOS" = *udp* ]] && echo "ip protocol udp udp dport ${SRC_PORT} redirect to ${DST_PORT}" )
    $( [[ "$PROTOS" = *tcp* ]] && echo "ip protocol tcp tcp dport ${SRC_PORT} redirect to ${DST_PORT}" )
  }
}
EOF

if ! grep -q 'include "/etc/nftables.d/*.nft"' /etc/nftables.conf 2>/dev/null; then
  echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
fi

systemctl enable --now nftables
nft -f /etc/nftables.conf

echo
echo "== nftables rules installed =="
nft list ruleset | sed -n '/table inet portproxy/,$p'
echo
echo "Test with:"
echo "  logger -n 127.0.0.1 -P ${SRC_PORT} \"TEST via nft\""
echo
