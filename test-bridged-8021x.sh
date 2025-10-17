#!/bin/sh

# Test using a 802.1X Ethernet connection in a bridge with NM.

setup()
{
    ip netns add ns1
    ip link add v1 type veth peer name v2 netns ns1
    ip link set v1 up
    ip -n ns1 link set v2 up
    ip -n ns1 addr add dev v2 172.20.1.1/24
    ip netns exec ns1 dnsmasq --bind-interfaces -i v2 --dhcp-range 172.20.1.100,172.20.1.200,1m --pid-file="$tmpdir/dnsmasq.pid"
}

cleanup()
{
    (
        set +e
        ip netns del ns1
        ip link del br0
        ip link del v1
        pkill hostapd_cli
        nmcli connection delete v1+ br0+
        killall hostapd # XXX
        killall dnsmasq # XXX
    ) 2>/dev/null || :
}

exit_hook()
{
    cleanup > /dev/null 2>&1
    pkill -F "$tmpdir/dnsmasq.pid"
    pkill -F "$tmpdir/hostapd.pid"
    rm -rf "$tmpdir"
}

start_hostapd()
{
    # drop all incomping traffic on unauthenticated port
    ip netns exec ns1 nft add table netdev dot1x_filter
    ip netns exec ns1 nft add chain netdev dot1x_filter input { type filter hook ingress device v2 priority -500 \; policy drop \; }
    ip netns exec ns1 nft add rule netdev dot1x_filter input ether type 0x888e accept

    cat > "$tmpdir/eap.users" <<'EOF'
"user"   MD5     "password"
EOF

    cat > "$tmpdir/hostapd.conf" <<EOF
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
interface=v2
driver=wired
logger_stdout=-1
logger_stdout_level=1
ieee8021x=1
eap_reauth_period=3600
eap_server=1
use_pae_group_addr=1
eap_user_file=$tmpdir/eap.users
eap_reauth_period=20
EOF
    ip netns exec ns1 hostapd -B -P "$tmpdir/hostapd.pid" "$tmpdir/hostapd.conf"
    sleep 3

    # create event script that will start the DHCP server in the
    # namespace upon successful authentication
    cat > "$tmpdir/event.sh" <<'EOF'
#!/bin/sh

if [ "$1" = "v2" ] && [ "$2" = "AP-STA-CONNECTED" ]; then
    echo "event: $*"
    nft delete table netdev dot1x_filter
fi
EOF
    chmod +x "$tmpdir/event.sh"
    ip netns exec ns1 hostapd_cli -p /var/run/hostapd -i v2 -a "$tmpdir/event.sh" &
}

# trap exit_hook EXIT

tmpdir=$(mktemp -d)
cleanup > /dev/null 2>&1
setup
start_hostapd

nmcli connection add \
      type bridge \
      ifname br0 \
      con-name br0+ \
      connection.autoconnect no \
      bridge.stp off \
      ipv4.method auto \
      ipv6.method disabled

nmcli connection add \
      type ethernet \
      ifname v1 \
      con-name v1+ \
      connection.autoconnect no \
      connection.controller br0 \
      connection.port-type bridge \
      802-1x.eap md5 \
      802-1x.identity user \
      802-1x.password password

nmcli connection up v1+


