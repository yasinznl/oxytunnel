# oxytunnel

Persistent GRE tunnel between two servers, with port forwarding on the Iran side, a health check that restarts a dead tunnel, and a root-only management menu.

The foreign server runs the panel and listens on `0.0.0.0`. The Iran server owns the public address clients use, and forwards the ports you choose across the tunnel to the foreign tunnel IP. GRE is not encrypted.

## Install

Run the installer on both servers. Prompts do not offer a saved address.

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/yasinznl/oxytunnel/main/install.sh
sudo bash install.sh
```

It asks for the public IPs, the tunnel IPs, and the role of this machine:

- `iran` — forward the ports you enter to the foreign tunnel IP
- `foreign` — bring up GRE only

Use the same pair of tunnel addresses on both sides. `/31` is the simplest point-to-point prefix. `/30` also works; do not use the network or broadcast address.

Iran:

```bash
sudo bash install.sh \
  --local-ip 203.0.113.10 \
  --remote-ip 203.0.113.20 \
  --tun-ip 10.200.0.1 \
  --peer-ip 10.200.0.2 \
  --cidr 30 \
  --role iran \
  --ports 443,8443
```

Foreign:

```bash
sudo bash install.sh \
  --local-ip 203.0.113.20 \
  --remote-ip 203.0.113.10 \
  --tun-ip 10.200.0.2 \
  --peer-ip 10.200.0.1 \
  --cidr 30 \
  --role foreign
```

Clients connect to the Iran public IP and the forwarded port. In the foreign panel, leave the inbound Listen address empty.

## Menu

Management is root-only. One command opens the menu:

```bash
sudo oxytunnel
```

The menu shows status, runs a health check, prints the log, adds or removes ports, restarts the tunnel, and changes the role. The same actions exist as commands:

```bash
sudo oxytunnel status
sudo oxytunnel health
sudo oxytunnel log
sudo oxytunnel port add 8443
sudo oxytunnel port del 8443
sudo oxytunnel port set 443 8443
sudo oxytunnel restart
sudo oxytunnel role iran
sudo oxytunnel role foreign
```

Config file `/etc/oxytunnel.conf` is mode 600. The log `/var/log/oxytunnel.log` is mode 640. A non-root user cannot open the menu.

## Health

`oxytunnel-health.timer` checks the tunnel every 30 seconds. A missing interface, a down interface, or two failed pings to the peer is written to the log and to the system journal. The timer then restarts `oxytunnel.service`. Restarts are at least 90 seconds apart. Stopping the service on purpose does not make the timer start it again.

```bash
sudo oxytunnel log
journalctl -u oxytunnel -u oxytunnel-health --no-pager -n 80
```

## Service

```bash
sudo systemctl status oxytunnel --no-pager
sudo systemctl restart oxytunnel
sudo systemctl stop oxytunnel
```

The service restores the tunnel after reboot. On the Iran side it also restores the port forwards.

## Uninstall

```bash
sudo bash install.sh --uninstall
```

## Troubleshooting

GRE uses IP protocol 47, not TCP or UDP. If the log says the peer did not answer, the provider or a firewall is dropping GRE.

```bash
ip addr show oxytunnel
ip tunnel show
```

If clients time out while the peer answers ping, check the Iran port list and confirm the foreign inbound is listening on `0.0.0.0` and that port.

Packet loss inside an otherwise working tunnel is often MTU. Re-run the installer with `--mtu 1400`, or set `MTU` in `/etc/oxytunnel.conf` and run `sudo oxytunnel restart`.

## Requirements

- Linux with systemd
- iproute2
- curl or wget, when the installer has to download its files
- iptables on the Iran server (the installer packages it)
