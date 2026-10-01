# sudotunnel

Persistent GRE tunnel between two servers, with port forwarding on the Iran side.

The foreign server runs the panel and listens on `0.0.0.0`. The Iran server owns the public address clients use, and forwards the ports you choose across the tunnel to the foreign tunnel IP. GRE is not encrypted.

## Install

Run the installer on both servers.

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/yasinznl/sudotunnel/main/install.sh
sudo bash install.sh
```

The installer asks for the public IPs, the tunnel IPs, and the role of **this** machine:

- `iran` — forward the ports you enter to the foreign tunnel IP
- `foreign` — bring up GRE only

Use the same pair of tunnel addresses on both sides. `/31` is the simplest point-to-point prefix. `/30` also works; do not use the network or broadcast address.

Iran:

```bash
sudo bash install.sh \
  --local-ip IRAN_PUBLIC_IP \
  --remote-ip FOREIGN_PUBLIC_IP \
  --tun-ip 10.10.0.10 \
  --peer-ip 10.10.0.9 \
  --cidr 30 \
  --role iran \
  --ports 8028,443
```

Foreign:

```bash
sudo bash install.sh \
  --local-ip FOREIGN_PUBLIC_IP \
  --remote-ip IRAN_PUBLIC_IP \
  --tun-ip 10.10.0.9 \
  --peer-ip 10.10.0.10 \
  --cidr 30 \
  --role foreign
```

Clients connect to the Iran public IP and the forwarded port. In the foreign panel, leave the inbound Listen address empty. Do not put the Iran public IP in Listen; that address does not exist on the foreign machine.

## Change ports

On the Iran server:

```bash
sudo sudotunnel status
sudo sudotunnel port list
sudo sudotunnel port add 8443
sudo sudotunnel port del 8443
sudo sudotunnel port set 8028 443
sudo sudotunnel restart
```

`port add`, `port del`, and `port set` save `/etc/sudotunnel.conf` and restart the service. Restart rebuilds the GRE interface and the forward rules from that file. TCP and UDP are both forwarded. The foreign server does not keep the port list.

Switch role only if this machine was installed on the wrong side:

```bash
sudo sudotunnel role iran
sudo sudotunnel role foreign
```

## Service

```bash
sudo systemctl status sudotunnel --no-pager
sudo systemctl restart sudotunnel
sudo systemctl stop sudotunnel
```

The service restores the tunnel and, on the Iran side, the port forwards after reboot.

## Uninstall

```bash
sudo bash install.sh --uninstall
```

## Troubleshooting

GRE uses IP protocol 47, not TCP or UDP. If `sudotunnel status` reports `ping: ... failed`, the provider or a firewall is dropping GRE.

```bash
journalctl -u sudotunnel --no-pager -n 80
ip addr show sudotunnel
ip tunnel show
```

If clients time out while `ping` of the tunnel IP works, check the Iran port list and confirm the foreign inbound is listening on `0.0.0.0` and that port.

Packet loss inside an otherwise working tunnel is often MTU. Re-run the installer with `--mtu 1400`, or set `MTU` in `/etc/sudotunnel.conf` and run `sudo sudotunnel restart`.

## Requirements

- Linux with systemd
- iproute2
- curl or wget, when the installer has to download its files
- iptables on the Iran server (the installer packages it)
