#!/bin/bash

# This script configures an enviroment for testing CLAT (464XLAT).
# After running the script, interface veth0 is attached to a
# NAT64-enabled IPv6-mostly network. It offers SLAAC addresses via RA,
# advertises the PREF64 option and sends DHCPv4 option 108 (IPv6-only
# preferred). Clients can reach the (fake) IPv4 internet via CLAT.
#
# After setting up the environment, the script establishes the NM
# connection and performs some tests to verify that everything works.

# Choose the NAT64 prefix.
PREF64=64:ff9b::/96
#PREF64=2001:db8::/32
#PREF64=2001:db8:100::/40
#PREF64=2001:db8:122::/48
#PREF64=2001:db8:122:300::/56
#PREF64=2001:db8:122:344::/64
#PREF64=2001:db8:122:344::/96

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

COLOR_RED="\e[0;31m"
COLOR_GREEN="\e[0;32m"
COLOR_BLUE="\e[0;34m"
COLOR_RESET="\e[0m"

log_action()
{
    printf "$COLOR_BLUE * $* $COLOR_RESET\n"
}

fail()
{
    printf "$COLOR_RED * ERROR: $* $COLOR_RESET\n"
    exit 1
}

success()
{
    printf "$COLOR_GREEN * SUCCESS $COLOR_RESET\n"
    exit 0
}

require()
{
    if ! command -v "$1" > /dev/null ; then
        fail "command '$1' not found"
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
        pkill -F /tmp/tshark.pid
        pkill -F /tmp/dnsmasq.pid
        ip link del nat64
        nmcli connection delete clat
        killall socat
    )2>/dev/null || :
}

require ip
require tayga
require radvd
require socat
require tshark

cleanup

set -ex

log_action "Creating the topology"

ip netns add ns1
ip netns add ns2
ip link add veth0 type veth peer name veth1 netns ns1
ip link add name veth2 netns ns1 type veth peer name veth3 netns ns2

# set up veth1 in ns1
ip -n ns1 link set veth1 up
ip -n ns1 addr add dev veth1 2002:aaaa::1/64
ip -n ns1 addr add dev veth1 172.25.42.1/24
ip netns exec ns1 dnsmasq --no-hosts --conf-file=/dev/null \
   --bind-interfaces --interface veth1 \
   --dhcp-range=172.25.42.100,172.25.42.200,60 \
   --dhcp-option=108,720 --pid-file=/tmp/dnsmasq.pid

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
ip netns exec ns2 socat UDP4-LISTEN:9999,fork,bind=20.0.0.1 SYSTEM:'echo "${SOCAT_PEERADDR}"' &

log_action "Configuring radvd"

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

    nat64prefix $PREF64 {
        AdvValidLifetime 1800;
    };
};
EOF
ip netns exec ns1 radvd --configtest --config /tmp/radvd.conf
ip netns exec ns1 radvd --config /tmp/radvd.conf --pidfile /tmp/radvd.pid

log_action "Configuring tayga"

rm /var/lib/tayga/nat64/dynamic.map
cat <<EOF >/tmp/tayga.conf
tun-device nat64
ipv4-addr 1.0.0.133
prefix $PREF64
dynamic-pool 1.0.0.144/28
data-dir /var/lib/tayga/nat64
offlink-mtu 1492
EOF
ip netns exec ns1 tayga --config /tmp/tayga.conf --mktun
ip -n ns1 link set nat64 up
ip -n ns1 route add 1.0.0.144/28 dev nat64
ip -n ns1 route add $PREF64 dev nat64
ip netns exec ns1 tayga --config /tmp/tayga.conf --pidfile /tmp/tayga.pid
ip netns exec ns1 iptables -t nat -A POSTROUTING -o nat64 -j MASQUERADE
ip netns exec ns1 iptables -t nat -A POSTROUTING -s 1.0.0.144/28 -j MASQUERADE

log_action "Deactivating existing NM connections"
nmcli -g uuid connection show --active | xargs --no-run-if-empty nmcli connection down

log_action "Activating the NM clat connection"

nmcli connection add \
      type ethernet \
      ifname veth0 \
      con-name clat \
      ipv6.clat yes \
      autoconnect no
nmcli connection up clat

log_action "Check that the interface only has the IPv4 CLAT address"
num=$(ip -4 -j addr show dev veth0 | jq -r '.[0].addr_info | length')
[ "$num" == 1 ] || fail "Expected 1 address on veth0, found $num"
addr=$(ip -4 -j addr show dev veth0 | jq -r '.[0].addr_info.[0].local')
plen=$(ip -4 -j addr show dev veth0 | jq -r '.[0].addr_info.[0].prefixlen')
[ "$addr/$plen" == 192.0.0.5/32 ] || fail "Expected address 192.0.0.5/32 on veth0, found $addr/$plen"

log_action "Check the default route"
r=$(ip -4 -j route  | jq -r '.[] | select(.dst == "default" ) | "\(.dev) \(.prefsrc) \(.via.family)"')
[ "$r" == "veth0 192.0.0.5 inet6" ] || fail "Wrong default IPv4 route $r"

log_action "Ping a IPv4 host"
if ! ping -i .1 -c 4 20.0.0.1; then
    fail "Cannot ping 20.0.0.1"
fi

log_action "Establish a TCP connection"
if ! curl http://20.0.0.1:8080 > /dev/null; then
    fail "Cannot fetch HTTP URI"
fi

log_action "Establish a UDP connection"
if [ $(echo test | socat - UDP4-DATAGRAM:20.0.0.1:9999) != 1.0.0.1 ] ; then
    fail "UDP communication failed"
fi

log_action "Check ICMP time-exceeded message"
if ! ping -c 1 -t 2 20.0.0.1 | grep "Time to live exceeded"; then
    fail "The ICMP time-exceeded message was not properly translated"
fi

log_action "Check ICMP destination unreachable message"
tshark -l -n -i veth0 > /tmp/tshark.log &
sleep 1
echo test | socat - UDP4-DATAGRAM:20.0.0.1:44444
echo $! > /tmp/tshark.pid
pkill -F /tmp/tshark.pid
if ! grep -E "20.0.0.1.*192.0.0.5.*ICMP 75 Destination unreachable \(Port unreachable\)" /tmp/tshark.log; then
    fail "The ICMP destination unrechable message was not properly translated"
fi

success

cleanup
kill $(jobs -p)

exit 0
