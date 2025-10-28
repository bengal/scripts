#!/bin/bash

# This script configures an enviroment for testing CLAT (464XLAT).
#
# Set $IFACE to an interface with access to IPv4 internet and
# with a DHCPv4 server. After running the script, the internet
# access is available via NAT64 over the IPv6-only network on
# veth0.

IFACE=enp7s0

###############################################################
#                                                   [init ns] #
#     IPv6-only network                                       #
#         veth0                                               #
#           ^                                                 #
# ----------|------------------------------------------------ #
#           v                                           [ns1] #
#                                                             #
#         veth1      <--->  nat64  <--->     dummy1           #
u#    2002:aaaa::1/64       (tayga)       100.25.1.1/24        #
#        (radvd)                               ^              #
#                                              |              #
#                                            (nat)            #
#                                              |              #
#                                            IFACE            #
#                                            (dhcp)           #
# ---------------------------------------------|------------- #
#                                              v              #
#                                                             #
#                        IPv4 internet                        #
#                                                             #
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
        ip link del veth0
        pkill -F /tmp/radvd.pid
        pkill -F /tmp/tayga.pid
        pkill -F /tmp/dnsmasq.pid
        ip link del nat64
        dhclient -r $IFACE
    )2>/dev/null || :
}

require ip
require tayga
require radvd

cleanup

set -ex

# set up ns1
ip netns add ns1
ip link add veth0 type veth peer name veth1 netns ns1
ip link add dummy1 netns ns1 type dummy

ip -n ns1 link set veth1 up
ip -n ns1 addr add dev veth1 2002:aaaa::1/64
ip -n ns1 link set dummy1 up
ip -n ns1 addr add dev dummy1 100.25.1.1/24
ip netns exec ns1 sysctl -w net.ipv4.ip_forward=1
ip netns exec ns1 iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
ip link set $IFACE netns ns1
ip netns exec ns1 dhclient $IFACE
ip -n ns1 addr add dev veth1 172.25.42.1/24
ip netns exec ns1 dnsmasq -h --bind-interfaces --interface veth1 --dhcp-range=172.25.42.100,172.25.42.200,60 --dhcp-option=108,720 --pid-file=/tmp/dnsmasq.pid

# set up radvd
ip netns exec ns1 sysctl -w net.ipv4.ip_forward=1
ip netns exec ns1 sysctl -w net.ipv6.conf.all.forwarding=1
cat <<EOF >/tmp/radvd.conf
interface veth1
{
    AdvSendAdvert on;
    MinRtrAdvInterval 6;
    MaxRtrAdvInterval 12;
    AdvLinkMTU 1498;
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

# set up tayga
cat <<EOF >/tmp/tayga.conf
tun-device nat64
ipv4-addr 100.25.1.133
prefix 64:ff9b::/96
dynamic-pool 100.25.1.144/28
data-dir /var/lib/tayga/nat64
EOF
ip netns exec ns1 tayga --config /tmp/tayga.conf --mktun
ip -n ns1 link set nat64 up
ip -n ns1 route add 100.25.1.144/28 dev nat64
ip -n ns1 route add 64:ff9b::/96 dev nat64
ip netns exec ns1 tayga --config /tmp/tayga.conf --pidfile /tmp/tayga.pid

sleep 1

set +x
echo
echo "NAT64 set up successfully on interface veth0"
echo
read -p "Press enter to end..."

cleanup

exit 0
