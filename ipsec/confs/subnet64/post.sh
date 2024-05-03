#!/bin/sh

h=$(hostname)

if [ "$h" = "hosta.example.org" ]; then
    nmcli connection add type dummy ifname dummy0 ip4 192.0.1.1/24
elif [ "$h" = "hostb.example.org" ]; then
    nmcli connection add type dummy ifname dummy0 ip4 192.0.2.1/24
fi
