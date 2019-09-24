#!/bin/sh

unalias ip

cleanup()
{
    pkill -F dhcpd.pid
    pkill -F radvd.pid
    rm -f radvd.conf
    rm -f dhcpd.conf
    rm -f leases.conf
    nmcli connection delete v1+ v2+
    ip netns del ns1
    ip netns del ns2
    ip link del v1
    ip link del v2
}

exit_hook()
{
    cleanup > /dev/null 2>&1
}

###

# ns1 is the 'upstream' namespace that provides IPv6 connectivity
# through RA + stateful DHCPv6. The DHCP server also acts as a
# delegating router for /60 prefixes.

# ns2 is the 'downstream' namespace where a client obtains IPv6
# connectivity through RA from NM.

# NM is in the default namespace and has a connection to ns1 with
# ipv6.method=auto and to ns2 with ipv6.method=shared.

cleanup
trap exit_hook EXIT

ip netns add ns1
ip netns add ns2

ip link add v1 type veth peer name v1p
ip link add v2 type veth peer name v2p

ip link set v1p netns ns1
ip link set v2p netns ns2

ip link set v1 up
ip link set v2 up

ip -n ns1 link set v1p up
ip -n ns1 addr add dev v1p fc01::1/64

ip -n ns2 link set v2p up

cat > radvd.conf <<EOF
interface v1p {
        AdvManagedFlag on;
        AdvSendAdvert on;
        AdvOtherConfigFlag on;
        MinRtrAdvInterval 3;
        MaxRtrAdvInterval 60;
};
EOF

cat > dhcpd.conf <<EOF
subnet6 fc01::/64 {
	range6  fc01::1000 fc01::ffff;
	prefix6 fc01:bbbb:1:: fc01:bbbb:2:: /60;
}
EOF

echo > leases.conf
ip netns exec ns1 radvd -n -C radvd.conf -p radvd.pid &
ip netns exec ns1 dhcpd -6 -d -cf dhcpd.conf -lf leases.conf -pf dhcpd.pid &

nmcli connection add type ethernet ifname v1 con-name v1+ ipv4.method disabled ipv6.method auto autoconnect no
nmcli connection up v1+

sleep 5

nmcli connection add type ethernet ifname v2 con-name v2+ ipv4.method disabled ipv6.method shared autoconnect no
nmcli connection up v2+

sleep 5

# parse the lease file, extract the client address and the prefix
# delegated to it; add a route needed to reach the prefix through
# that client
addr=$(grep -m 1 iaaddr leases.conf | sed -r 's/\s+iaaddr ([a-f0-9:]+) \{.*/\1/')
prefix=$(grep -m 1 iaprefix leases.conf | sed -r 's/\s+iaprefix ([a-f0-9:/]+) \{.*/\1/')
if [ -z "$addr" ] || [ -z "$prefix" ]; then
    echo "Address or prefix not found in lease file"
    exit 1
fi

ip netns exec ns1 ip route add $prefix via $addr 

# kernel does IPv6 autoconf in ns2 ...

sleep 10

# check connectivity to ns1
if ! ip -n ns2 a show dev v2p | grep 'fc01:bbbb:[a-f0-9\:]\+/64'; then
    ip -n ns2 a show dev v2p
    echo "ERROR: no address"
    exit 1
fi

if ! ip netns exec ns2 ping -c2 fc01::1; then
    echo "ERROR: ping failed"
    exit 1
fi
