#!/bin/sh

# This simulates (from the point of view of NM) a 802.1X port (veth0)
# that initially doesn't have authentication and is bridged to network
# 172.25.1.1/24. Later, port authentication gets enabled and after
# successful authentication the port is bridged to network
# 172.25.2.1/24.

setup()
{
    ip netns add ns1
    ip netns add ns2
    ip link add brx type bridge    
    ip link add p1 type veth peer name p1br
    ip link add p2 type veth peer name p2br
    ip link set p1 netns ns1
    ip link set p2 netns ns2
    ip link set p1br master brx
    ip link set p2br master brx
    ip link set p1br up
    ip link set p2br up

    ip -n ns1 link set p1 up
    ip -n ns1 addr add dev p1 172.25.1.1/24
    ip netns exec ns1 dnsmasq --bind-interfaces -i p1 --dhcp-range 172.25.1.100,172.25.1.200,2m --pid-file="$tmpdir/dnsmasq1.pid"

    ip -n ns2 link set p2 up
    ip -n ns2 addr add dev p2 172.25.2.1/24
    ip netns exec ns2 dnsmasq --bind-interfaces -i p2 --dhcp-range 172.25.2.100,172.25.2.200,2m --pid-file="$tmpdir/dnsmasq2.pid"

    ip link add veth0 type veth peer name veth1
    ip link set veth1 master brx
    ip link set veth0 up
    ip link set veth1 up
    ip link set brx up
}

cleanup()
{
    ip link del veth0
    ip link del p1
    ip link del p1br
    ip link del p2
    ip link del p2br
    ip link del brx
    ip netns del ns1
    ip netns del ns2
    pkill hostapd_cli
    nmcli connection delete veth0+
}

exit_hook()
{
    cleanup > /dev/null 2>&1
    pkill -F "$tmpdir/dnsmasq1.pid"
    pkill -F "$tmpdir/dnsmasq2.pid"
    pkill -F "$tmpdir/hostapd.pid"
    rm -rf "$tmpdir"
}

start_hostapd()
{
    cat > "$tmpdir/eap.users" <<'EOF'
"user"   MD5     "password"
EOF

    cat > "$tmpdir/hostapd.conf" <<EOF
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
interface=veth1
driver=wired
logger_stdout=-1
logger_stdout_level=1
debug=2
bridge=brx
ieee8021x=1
eap_reauth_period=3600
eap_server=1
use_pae_group_addr=1
eap_user_file=$tmpdir/eap.users
EOF
    hostapd -B -P "$tmpdir/hostapd.pid" "$tmpdir/hostapd.conf"
    sleep 3

    # create event script that will bridge the veth with authenticated
    # namespace upon successful authentication
    cat > "$tmpdir/event.sh" <<'EOF'
#!/bin/sh

if [ "$1" = "veth1" ] && [ "$2" = "AP-STA-CONNECTED" ]; then
    echo "event: $*"
    ip link set p1br down
    ip link set p2br up
fi
EOF
    chmod +x "$tmpdir/event.sh"
    hostapd_cli -p /var/run/hostapd -i veth1 -a "$tmpdir/event.sh" &
}

trap exit_hook EXIT

tmpdir=$(mktemp -d)
cleanup > /dev/null 2>&1
setup

echo "* PORT AUTHENTICATION OFF"
ip link set p1br up
ip link set p2br down

nmcli connection add \
      type ethernet \
      ifname veth0 \
      con-name veth0+ \
      connection.autoconnect no \
      connection.auth-retries 1 \
      802-1x.eap md5 \
      802-1x.identity user \
      802-1x.password password \
      802-1x.auth-timeout 10 \
      802-1x.optional yes

if ! nmcli connection up veth0+; then
    echo "ERROR: can't activate veth0+"
    exit 1
fi

if ! ping -c1 172.25.1.1; then
    echo "ERROR: no connectivity to unauthenticated network"
    exit 1
fi

sleep 10

echo "* PORT AUTHENTICATION ON"
start_hostapd

for t in $(seq 90); do
    if ip addr show dev veth0 | grep "inet 172\.25\.2\."; then
	break
    fi
    if [ "$t" = 90 ]; then
	echo
	echo "ERROR: didn't get address on authenticated network"
	exit 1
    fi
    printf "."
    sleep 1
done

echo

if ! ping -c2 172.25.2.1; then
    echo "ERROR: no connectivity to authenticated network"
    exit 1
fi

echo "SUCCESS"
exit 0
