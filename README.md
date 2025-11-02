# socat-portproxy

End-to-end installer for a secure, systemd-managed port proxy that forwards syslog traffic from port **514** to **1514** (or any port you choose). Supports **UDP** and/or **TCP**, and includes an optional **nftables** mode that preserves the original source IP when the destination service is on the same host.

> Tested on Ubuntu 22.04 and 24.04.

---

## Why this exists

- Many SIEMs (e.g., Splunk) listen on non-privileged ports (e.g., 1514) while network devices send syslog to 514.
- You need a clean, reproducible way to:
  - Open 514 without running your SIEM as root.
  - Forward 514 → 1514 on the same host or to a remote host.
  - Run as a locked-down service with restarts, logs, and health checks.
  - Optionally preserve the **original source IP** (nftables mode).

---

## Features

- One-line installer (`scripts/install_socat_portproxy.sh`) that:
  - Installs required packages.
  - Creates a **non-root** dedicated user with **CAP_NET_BIND_SERVICE** only.
  - Sets up **systemd** services for UDP and/or TCP on port 514 (configurable).
  - Supports **two modes**:
    - **socat** (default): simple proxy to local or **remote** destination.
    - **nft**: local redirect that **preserves source IP**, best when the destination service is on the same host.
  - Provides **uninstall** to remove services and rules.

---

## Repo layout

```
socat-portproxy/
├─ README.md
└─ scripts/
   └─ install_socat_portproxy.sh
```

---

## Quick start

```bash
# Clone or download this repo, then:
sudo chmod +x scripts/install_socat_portproxy.sh

# Default: listen on UDP/514 and forward to 127.0.0.1:1514
sudo ./scripts/install_socat_portproxy.sh
```

Now send a test packet:
```bash
echo "<13>Hello from socat-portproxy" | nc -u -w1 127.0.0.1 514
```

Check the systemd unit status:
```bash
systemctl --no-pager --full status socat-syslog514to1514-udp.service
```

---

## Usage

The installer accepts both **flags** and **environment variables**. Flags override env vars.

### Flags

```
-m, --mode [socat|nft]     Forwarding mode (default: socat)
-p, --protos "udp,tcp"     Protocols to forward (default: udp)
-s, --src-ip IP            Source bind IP (default: 0.0.0.0)
-S, --src-port PORT        Source listening port (default: 514)
-d, --dst-host HOST        Destination host (default: 127.0.0.1)
-D, --dst-port PORT        Destination port (default: 1514)
-n, --name NAME            Instance name (default: syslog514to1514)
    --uninstall            Remove services/rules and exit
-h, --help                 Show help
```

### Environment variables

```
MODE=socat|nft
PROTOS=udp|tcp|udp,tcp
SRC_IP=0.0.0.0
SRC_PORT=514
DST_HOST=127.0.0.1
DST_PORT=1514
NAME=syslog514to1514
```

### Examples

Forward both UDP and TCP 514 → 1514 locally:
```bash
sudo ./scripts/install_socat_portproxy.sh -p "udp,tcp"
```

Forward UDP 514 on this proxy to **remote** Splunk (`10.10.0.11:1514`):
```bash
sudo ./scripts/install_socat_portproxy.sh -p udp -d 10.10.0.11 -D 1514
```

**Preserve source IP** on the **same host** using nftables (best when Splunk and the proxy are on one machine):
```bash
sudo ./scripts/install_socat_portproxy.sh -m nft -p udp
```

---

## Testing

**socat mode**
```bash
echo "<13>TEST via socat" | nc -u -w1 127.0.0.1 514
journalctl -u socat-syslog514to1514-udp --no-pager -n 20
```

**nft mode**
```bash
logger -n 127.0.0.1 -P 514 "TEST via nft"
```

---

## Logs & troubleshooting

- Systemd journald is used by default:
  - `journalctl -u socat-<NAME>-udp --no-pager -n 100`
  - `journalctl -u socat-<NAME>-tcp --no-pager -n 100`
- Check listeners:
  - `ss -lntu | egrep ':514\b|:1514\b'`
- Check nftables rules (nft mode):
  - `nft list ruleset | sed -n '/table inet portproxy/,$p'`
- Firewalls:
  - If using UFW/iptables/nftables elsewhere, ensure port 514 is open from sources you expect.

---

## Uninstall

Remove socat services:
```bash
sudo ./scripts/install_socat_portproxy.sh --uninstall -m socat -p "udp,tcp"
```

Remove nftables rules:
```bash
sudo ./scripts/install_socat_portproxy.sh --uninstall -m nft -p udp
```

---

## Security notes

- The systemd services run as a dedicated **system user** with minimized capabilities.
- Binding to privileged port 514 is allowed via `AmbientCapabilities=CAP_NET_BIND_SERVICE`. No full root is granted.
- Always restrict who can send to port 514 using network ACLs or a host firewall if the machine is Internet‑reachable.

---

## Compatibility

- Ubuntu 22.04 (Jammy), Ubuntu 24.04 (Noble)
- Requires `socat` (for socat mode) or `nftables` (for nft mode). The installer manages both.

---

## License

MIT License
