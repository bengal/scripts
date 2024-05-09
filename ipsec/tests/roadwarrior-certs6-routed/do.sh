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
        nmcli connection add type dummy ifname dummy0 ip6 2001:db8:bbbb::1/64
    fi

elif [ "$event" = check ]; then

    if [ "$h" = hosta.example.org ]; then
        check_iface_addr ipsec9 2001:db8:9:aaaa::/128
        check_xfrm_esp dir out src 2001:db8:9:aaaa::/128 dst ::/0 if_id 9
        ping_host 2001:db8:bbbb::1
    elif [ "$h" = hostb.example.org ]; then
        check_xfrm_esp dir out src ::/0 dst 2001:db8:9:aaaa::/128
        ping_host 2001:db8:9:aaaa:: 2001:db8:bbbb::1
    fi

fi

    
