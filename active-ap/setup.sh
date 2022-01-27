#!/bin/sh

# setup for https://bugzilla.redhat.com/show_bug.cgi?id=1983735

set -x

modprobe mac80211_hwsim radios=3

sleep 2

nmcli device set wlan0 managed yes
nmcli device set wlan1 managed no
nmcli device set wlan2 managed no

killall hostapd
killall dnsmasq

hostapd open.conf &
hostapd wpa2.conf &

firewall-cmd --add-interface=wlan1 --zone=trusted
firewall-cmd --add-interface=wlan2 --zone=trusted

ip addr add dev wlan1 172.25.14.1/24
dnsmasq --interface=wlan1 --bind-interfaces --dhcp-range=172.25.14.100,172.25.14.200

