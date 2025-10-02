#!/bin/bash

# This script configures an enviroment for testing CLAT (464XLAT).
# After running the script, interface veth0 is attached to a
# NAT64-enabled IPv6-only network. It offers SLAAC addresses via RA
# and advertises the PREF64 option. Clients can reach the IPv4
# internet via CLAT. To test IPv4 connectivity use:
#
# curl http://20.0.0.1:8080


###############################################################
#                                                   [init ns] #
#     IPv6-only network                                       #
#         veth0                                               #
#           ^                                                 #
# ----------|------------------------------------------------ #
#           v                                           [ns1] #
#         veth1                                               #
#    2002:aaaa::1/64  <---->  nat64  <---->  1.0.0.1/24       #
#        (radvd)             (tayga)          veth2           #
#                                               ^             #
# ----------------------------------------------|------------ #
#                                               v       [ns2] #
#     IPv4 internet                           veth3           #
#                                            1.0.0.2/24       #
#       dummy1                                                #
#    20.0.0.1/24                                              #
#    (web server)                                             #
#                                                             #
###############################################################

require()
{
    if ! command -v "$1" > /dev/null ; then
        echo " *** Error: command '$1' not found"
        exit 1
    fi
}

cleanup()
{
    (
        set +e
        ip netns del ns1
        ip netns del ns2
        ip link del veth0
        pkill -F /tmp/radvd.pid
        pkill -F /tmp/tayga.pid
        ip link del nat64
    )2>/dev/null || :
}

require ip
require tayga
require radvd

cleanup

set -ex

ip netns add ns1
ip netns add ns2
ip link add veth0 type veth peer name veth1 netns ns1
ip link add name veth2 netns ns1 type veth peer name veth3 netns ns2

# set up veth1 in ns1
ip -n ns1 link set veth1 up
ip -n ns1 addr add dev veth1 2002:aaaa::1/64

# set up veth2 in ns1
ip -n ns1 link set veth2 up
ip -n ns1 addr add dev veth2 1.0.0.1/24
ip -n ns1 route add default via 1.0.0.2 dev veth2

# set up veth3 in ns2
ip -n ns2 link set veth3 up
ip -n ns2 addr add dev veth3 1.0.0.2/24
ip netns exec ns2 sysctl -w net.ipv4.icmp_ratelimit=0

# set up dummy1 in ns2
ip -n ns2 link add dummy1 type dummy
ip -n ns2 link set dummy1 up
ip -n ns2 addr add dev dummy1 20.0.0.1/24
ip netns exec ns2 python -m http.server --bind 20.0.0.1 8080 &

# set up radvd in ns1
ip netns exec ns1 sysctl -w net.ipv4.ip_forward=1
ip netns exec ns1 sysctl -w net.ipv6.conf.all.forwarding=1
cat <<EOF >/tmp/radvd.conf
interface veth1
{
    AdvSendAdvert on;
    MinRtrAdvInterval 30;
    MaxRtrAdvInterval 100;
    prefix 2002:aaaa::/64 {
        AdvOnLink on;
        AdvAutonomous on;
    };

    nat64prefix 64:ff9b::/96 {
        AdvValidLifetime 1800;
    };
};
EOF
ip netns exec ns1 radvd --configtest --config /tmp/radvd.conf
ip netns exec ns1 radvd --config /tmp/radvd.conf --pidfile /tmp/radvd.pid

# set up tayga in ns1
cat <<EOF >/tmp/tayga.conf
tun-device nat64
ipv4-addr 1.0.0.133
prefix 64:ff9b::/96
dynamic-pool 1.0.0.144/28
data-dir /var/lib/tayga/nat64
EOF
ip netns exec ns1 tayga --config /tmp/tayga.conf --mktun
ip -n ns1 link set nat64 up
ip -n ns1 route add 1.0.0.144/28 dev nat64
ip -n ns1 route add 64:ff9b::/96 dev nat64
ip netns exec ns1 tayga --config /tmp/tayga.conf --pidfile /tmp/tayga.pid
ip netns exec ns1 iptables -t nat -A POSTROUTING -o nat64 -j MASQUERADE
ip netns exec ns1 iptables -t nat -A POSTROUTING -s 1.0.0.144/28 -j MASQUERADE

sleep 1

set +x
echo
echo "NAT64 set up successfully on interface veth0"
echo
read -p "Press enter to end..."

cleanup
kill $(jobs -p)

exit 0
