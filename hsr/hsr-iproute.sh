#!/bin/sh

#                       ns1
#  ----------------     ----------------
#  |         veth0|-----|veth0p        |
#  |        |     |     |      |       |
#  |    hsr0      |     |       hsr1   |
#  |        |     |     |      |       |
#  |         veth1|-----|veth1p        |
#  |              |     |              |
#  | 172.25.10.1  |     | 172.25.10.2  |
#  ----------------     ----------------

cleanup()
{
    ip netns del ns1
    ip netns del ns2
    ip link del hsr0
    ip link del veth0
    ip link del veth1
}

cleanup

set -ex

# setup

ip netns add ns1
ip link add veth0 type veth peer name veth0p netns ns1
ip link add veth1 type veth peer name veth1p netns ns1

ip link set veth0 addr 00:88:77:11:00:01
ip link set veth1 addr 00:88:77:11:00:01
ip -n ns1 link set veth0p addr 00:88:77:11:00:02
ip -n ns1 link set veth1p addr 00:88:77:11:00:02

ip link add hsr0 type hsr proto 1 slave1 veth0 slave2 veth1 supervision 45 proto 1
ip link set hsr0 up

ip -n ns1 link add hsr1 type hsr proto 1 slave1 veth0p slave2 veth1p supervision 45 proto 1
ip -n ns1 link set hsr1 up

ip link set veth0 up
ip link set veth1 up
ip -n ns1 link set veth0p up
ip -n ns1 link set veth1p up

ip addr add dev hsr0 172.25.10.1/24
ip -n ns1 addr add dev hsr1 172.25.10.2/24

# test

ping -i .1 -c 200 172.25.10.2 >ping.out 2>&1 &
ip netns exec ns1 iperf3 -s >/dev/null &
sleep 1; iperf3 -t 20 -c 172.25.10.2

# result

tail ping.out
