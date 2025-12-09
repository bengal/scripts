#!/bin/bash

# Test IPv6 router failover via NUD
#
# Instructions: let the ping run in the first panel, then bring down
# rtr1 or rtr2 in the bottom panels

# select whether you want to let kernel or NetworkManager handle IPv6 autoconf
connect=NM
# connect=kernel

start_tmux()
{
    SESSION="netlab"

    set -x

    tmux kill-session -t $SESSION || :
    tmux new-session -d -s $SESSION
    tmux set-option -g pane-border-status top
    tmux set-option -g pane-border-format "#{pane_index} #{pane_title}"
    tmux set-option pane-base-index 1

    tmux split-window -v -t $SESSION
    tmux split-window -h -t $SESSION
    tmux split-window -h -t $SESSION
    tmux select-layout -t $SESSION tiled

    tmux list-windows -t $SESSION
    tmux list-panes -t $SESSION

    tmux select-pane -t $SESSION:1.1 -T "HOST (Bash)"
    tmux send-keys -t $SESSION:1.1 'ping 2001:db8::1' C-m

    tmux select-pane -t $SESSION:1.2 -T "HOST (Bash)"
    tmux send-keys -t $SESSION:1.2 'watch "echo NEIGHBORS; ip -6 neigh; echo ROUTES; ip -6 route; echo NEXTHOPS; ip -6 nexthop"' C-m

    tmux send-keys -t $SESSION:1.3 'ip netns exec ns1 bash' C-m
    tmux send-keys -t $SESSION:1.3 C-m
    tmux select-pane -t $SESSION:1.3 -T "NAMESPACE: ns1"

    tmux send-keys -t $SESSION:1.4 'ip netns exec ns2 bash' C-m
    tmux send-keys -t $SESSION:1.4 C-m
    tmux select-pane -t $SESSION:1.4 -T "NAMESPACE: ns2"

    tmux attach -t $SESSION
}

#                  vethc
#                    |
#  +-----------------|-----------------+
#  |                 |            [ns0]|
#  |                 p0                |
#  |                 v                 |
#  |           +-----------+           |
#  |           |    br0    |           |
#  |           +-----------+           |
#  |             ^       ^             |
#  |            p1       p2            |
#  +-------------|---+---|-------------+
#  |[ns1]        |   |   |        [ns2]|
#  |             |   |   |             |
#  |          rtr1   |   rtr2          |
#  |    fd01:aaa::1  |  fd01:aaa::2    |
#  |      (radvd)    |    (radvd)      |
#  |                 |                 |
#  |    2001:db8::1  |  2001:db8::1    |
#  |        wan1     |      wan2       |
#  +-----------------------------------+


# Check for radvd
if ! command -v radvd &> /dev/null; then
    echo "radvd could not be found. Please install it (apt install radvd / yum install radvd)."
    exit 1
fi

echo "=== IPv6 RA Failover test ==="

echo "[+] Cleaning up old namespaces and bridges..."
ip netns del ns0 2>/dev/null
ip netns del ns1 2>/dev/null
ip netns del ns2 2>/dev/null
ip netns del ns3 2>/dev/null
ip link del vethc 2>/dev/null
killall radvd 2>/dev/null

set -e

echo "[+] Creating topology"
ip netns add ns0
ip netns add ns1
ip netns add ns2

ip link add vethc type veth peer name p0 netns ns0
ip link set vethc up
ip -n ns0 link add br0 type bridge
ip -n ns0 link add p1 type veth peer name rtr1 netns ns1
ip -n ns0 link add p2 type veth peer name rtr2 netns ns2
ip -n ns0 link set p0 master br0
ip -n ns0 link set p1 master br0
ip -n ns0 link set p2 master br0
ip -n ns0 link set br0 up
ip -n ns0 link set p0 up
ip -n ns0 link set p1 up
ip -n ns0 link set p2 up

ip -n ns1 link add wan1 type dummy
ip -n ns1 link set wan1 up
ip -n ns1 link set rtr1 up
ip -n ns1 addr add dev rtr1 fd01:aaa::1/64
ip -n ns1 addr add dev wan1 2001:db8::1/64
ip netns exec ns1 sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

ip -n ns2 link add wan2 type dummy
ip -n ns2 link set wan2 up
ip -n ns2 link set rtr2 up
ip -n ns2 addr add dev rtr2 fd01:aaa::2/64
ip -n ns2 addr add dev wan2 2001:db8::1/64
ip netns exec ns2 sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null


echo "[+] Starting RA daemon (radvd)"
mkdir -p /tmp/ipv6_test
cat <<EOF > /tmp/ipv6_test/radvd_rtr1.conf
interface rtr1 {
    AdvSendAdvert on;
    MinRtrAdvInterval 3;
    MaxRtrAdvInterval 120;
    AdvDefaultLifetime 600;
    prefix fd01:aaa::/64 {
        AdvOnLink on;
        AdvAutonomous on;
        AdvRouterAddr on;
    };
};
EOF

cat <<EOF > /tmp/ipv6_test/radvd_rtr2.conf
interface rtr2 {
    AdvSendAdvert on;
    MinRtrAdvInterval 3;
    MaxRtrAdvInterval 120;
    AdvDefaultLifetime 600;
    prefix fd01:aaa::/64 {
        AdvOnLink on;
        AdvAutonomous on;
        AdvRouterAddr on;
    };
};
EOF

ip netns exec ns1 radvd -C /tmp/ipv6_test/radvd_rtr1.conf -p /tmp/ipv6_test/radvd_rtr1.pid
ip netns exec ns2 radvd -C /tmp/ipv6_test/radvd_rtr2.conf -p /tmp/ipv6_test/radvd_rtr2.pid

if [ "$connect" = NM ]; then
    nmcli connection delete vethc+ >/dev/null 2>&1 || :
    nmcli connection add \
          type ethernet \
          ifname vethc \
          ipv4.method disabled \
          autoconnect no \
          con-name vethc+
    nmcli connection up vethc+
elif [ "$connect" = kernel ]; then
    nmcli device set vethc managed no 2>/dev/null || :
    ip link set vethc addrgenmode eui64
    sysctl -w net.ipv6.conf.vethc.accept_ra=2
    sysctl -w net.ipv6.conf.vethc.disable_ipv6=1
    sysctl -w net.ipv6.conf.vethc.disable_ipv6=0
fi

sleep 4

start_tmux

exit 0
