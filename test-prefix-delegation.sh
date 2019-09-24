#!/bin/sh

set -x

# cleanup from previous runs
unalias ip
nmcli connection delete v1+ v2+
killall dhcpd
ip l del ns1
ip l del ns2
ip l del v1
ip l del v2

###

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
ip netns exec ns1 radvd -n -C radvd.conf &
ip netns exec ns1 dhcpd -6 -d -cf dhcpd.conf -lf leases.conf &

nmcli connection add type ethernet ifname v1 con-name v1+ ipv4.method disabled ipv6.method auto autoconnect no
nmcli connection up v1+

sleep 3

nmcli connection add type ethernet ifname v2 con-name v2+ ipv4.method disabled ipv6.method shared autoconnect no
nmcli connection up v2+

sleep 5

# add route in ns1 to main ns
addr=$(grep -m 1 iaaddr leases.conf | sed -r 's/\s+iaaddr ([a-f0-9:]+) \{.*/\1/')
prefix=$(grep -m 1 iaprefix leases.conf | sed -r 's/\s+iaprefix ([a-f0-9:/]+) \{.*/\1/')
ip netns exec ns1 ip route add $prefix via $addr 


# start IPv6 autoconf in ns2
ip netns exec ns2 rdisc -d -v

sleep 10

if ! ip -n ns2 a show dev v2p | grep 'fc01:bbbb:[a-f0-9\:]\+/64'; then
    ip -n ns2 a show dev v2p
    echo "ERROR: no address"
    exit 1
fi

if ! ip netns exec ns2 ping -c2 fc01::1; then
    echo "ERROR: ping failed"
    exit 1
fi


