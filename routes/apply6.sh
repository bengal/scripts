#!/bin/sh

set -x

ip link add dummy1 type dummy 2>&1 || true

ip link set dummy1 up
ip -6 route del default proto bird 2>&1 || true
ip -6 route flush dev dummy1

bunzip2 --stdout routes6.txt.bz2 | ip -batch -
