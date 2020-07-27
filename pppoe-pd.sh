#!/bin/sh

# Test DHCPv6 Prefix Delegation over PPPoE
# See: https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/issues/478

# Cleanup from previous execution
killall dhcp6s radvd pppoe-server 2> /dev/null
nmcli connection delete pppoe-pd+ dummy-shared+ 2> /dev/null
ip netns del ns1 2> /dev/null
ip link del veth0 2> /dev/null
ip link del veth1 2> /dev/null

# Install needed packages
dnf install -y rp-pppoe radvd wide-dhcpv6

# Create interfaces
ip netns add ns1
ip link add veth0 type veth peer name veth1
ip link set veth1 netns ns1
ip link set veth0 up
ip -n ns1 link set veth1 up

# Start PPPoE server
cat <<'EOF' > /etc/ppp/pppoe-server-options
# PPP options for the PPPoE server
require-chap
ms-dns 172.25.41.1
netmask 255.255.255.0
defaultroute
lcp-echo-interval 10
lcp-echo-failure 2
ipv6 ::1111,::2222
+ipv6
EOF

cat <<'EOF' > /etc/ppp/chap-secrets
# Secrets for authentication using CHAP
# client        server  secret                  IP addresses
"client"        *       "password"              172.25.41.2
EOF

ip netns exec ns1 pppoe-server -I veth1 -L 172.25.41.1

# Start router advertisements
cat <<EOF > /tmp/radvd.conf
interface ppp0
{
	AdvSendAdvert on;
	AdvOtherConfigFlag on;
	prefix fd01:3333:1::/64
	{
		AdvOnLink on;
		AdvAutonomous on;
	};
};
EOF

while true; do
    if [ -d /sys/class/net/ppp0 ]; then
	ip netns exec ns1 radvd -C /tmp/radvd.conf -n;
	exit;
    fi
    sleep 1
done &

# Start DHCPv6
cat <<EOF > /tmp/wide-dhcps.conf
option domain-name-servers	fd01:3333::1;
option domain-name		"example.com";

host fedora {
     duid 00:11:22:33:44;
     address fd01:3333::2 infinity;
     prefix fd01:3333:4444::/48 infinity;
};
EOF

while true; do
    if [ -d /sys/class/net/ppp0 ]; then
	ip netns exec ns1 dhcp6s -c /tmp/wide-dhcps.conf ppp0 -D -f
        exit;
    fi
    sleep 1
done &

# Activate a PPPoE connection and a dummy connection in shared IPv6
# mode. NM will request a prefix over the PPP interface and assign it
# to the dummy one.
nmcli connection add type pppoe \
      ifname ppp0 \
      con-name pppoe-pd+ \
      pppoe.parent veth0 \
      username client \
      password password \
      ipv6.dhcp-duid 00:11:22:33:44 \
      connection.autoconnect no

nmcli connection add type dummy \
      ifname dummy1 \
      con-name dummy-shared+ \
      ipv4.method disabled \
      ipv6.method shared

nmcli connection up pppoe-pd+
nmcli connection up dummy-shared+

sleep 5

# Check result
echo
ip addr show dummy1
echo

if ! ip -o -6 addr show dummy1 | grep fd01:3333:4444::1; then
    echo "ERROR: address not configured on dummy1"
    exit 1
fi

echo OK
