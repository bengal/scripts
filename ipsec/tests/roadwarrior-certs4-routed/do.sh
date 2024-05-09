#!/bin/sh

set -x

. /root/ipsec/tests/test-funcs.sh

h=$(hostname)
event="$1"

if [ "$event" = clean ]; then

    cleanup_connections

elif [ "$event" = post ]; then

    if [ "$h" = hosta.example.org ]; then
        :
    elif [ "$h" = hostb.example.org ]; then
        nmcli connection add type dummy ifname dummy0 ip4 192.0.2.2/24
    fi

elif [ "$event" = check ]; then

    if [ "$h" = hosta.example.org ]; then
        check_iface_addr ipsec9 203.0.113.2
        check_xfrm_esp dir out src 203.0.113.2/32 dst 0.0.0.0/0 if_id 9
        ping_host 192.0.2.2
    elif [ "$h" = hostb.example.org ]; then
        check_xfrm_esp dir out src 0.0.0.0/0 dst 203.0.113.2/32
        ping_host 203.0.113.2 192.0.2.2
    fi

fi

    
