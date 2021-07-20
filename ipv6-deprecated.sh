#!/bin/sh

# https://bugzilla.redhat.com/show_bug.cgi?id=1820770

### helpers
BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

log()
{
    printf "${BLUE}$*${NC}\n"
}

show_addr()
{
    printf "${GREEN} -> addresses $1 ${NC}\n"
    ip address show veth0
    echo
}

show_hostname()
{
    printf "${GREEN} -> hostname: $(hostname)${NC}\n"
}


[ -f /tmp/dnsmasq.pid ] && pkill --pidfile=/tmp/dnsmasq.pid
nmcli connection delete veth0+ 2> /dev/null

log " * Resetting hostname..."
hostname localhost
rm /etc/hostname
systemctl restart systemd-hostnamed

show_hostname

log " * Restaring NetworkManager..."
systemctl restart NetworkManager


log " * Set up namespaces..."

ip link add veth0 type veth peer name veth1
ip netns add ns1
ip link set veth1 netns ns1
ip link set veth0 up
ip -n ns1 link set veth1 up
ip -n ns1 address add dev veth1 172.25.1.1/24
ip -n ns1 address add dev veth1 fd01::1/64
ip -n ns1 address add dev veth1 fd02::1/64

log " * Start dnsmasq..."

ip netns exec ns1 dnsmasq --bind-interfaces --interface veth1 --dhcp-range=fd01::100,ra-only,3000s --dhcp-range=fd02::100,ra-only,deprecated --enable-ra --pid-file=/tmp/dnsmasq.pid --log-queries --ra-param=veth1,mtu:1430,low,60,120 --host-record=foobar1,fd01::200:ff:fe11:2233 --host-record=foobar2,fd02::200:ff:fe11:2233

log " * Activate connection..."

nmcli connection add type ethernet ifname veth0 con-name veth0+ ipv4.method disabled ipv6.addr-gen-mode eui64 autoconnect no ethernet.cloned-mac-address 00:00:00:11:22:33
nmcli connection up veth0+

show_addr
show_hostname
sleep 5
show_hostname
