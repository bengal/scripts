#!/bin/sh

set -ex

dir="$(mktemp -d)"

wg genkey | tee "$dir/a.priv" | wg pubkey > "$dir/a.pub"
wg genkey | tee "$dir/b.priv" | wg pubkey > "$dir/b.pub"

ip netns del ns1 2>/dev/null || true
ip link del veth0 2>/dev/null || true
ip link del veth1 2>/dev/null || true
nmcli connection delete wg0 2>/dev/null || true

ip netns add ns1
ip link add veth0 type veth peer name veth1
ip link set veth1 netns ns1
ip addr add dev veth0 172.25.10.1/24
ip link set veth0 up
ip -n ns1 addr add dev veth1 172.25.10.2/24
ip -n ns1 link set veth1 up

ip -n ns1 link add wg0 type wireguard
ip -n ns1 addr add 10.0.0.2/24 dev wg0
ip netns exec ns1 wg set wg0 listen-port 51821 private-key "$dir/a.priv" peer $(cat "$dir/b.pub") allowed-ips 10.0.0.1/32
ip -n ns1 link set wg0 up

cat > "$dir/wg0.conf" <<EOF
[Interface]
SaveConfig = true
ListenPort = 51820
PrivateKey = $(cat "$dir/b.priv")
Address = 10.0.0.1/24

[Peer]
PublicKey = $(cat "$dir/a.pub")
AllowedIPs = 10.0.0.2/32
Endpoint = 172.25.10.2:51821
PersistentKeepalive = 15
EOF

nmcli connection import type wireguard file "$dir/wg0.conf"
nmcli connection up wg0

ping -c 1 10.0.0.2 -I wg0






