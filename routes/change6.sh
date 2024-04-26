#!/bin/bash

set -x

while true; do
    for i in $(seq 1 300); do
        ip route add fd42::$i/128 dev dummy1
    done
    sleep 1
    for i in $(seq 1 300); do
        ip route del fd42::$i/128 dev dummy1
    done
    sleep 1
    printf "."
done
echo
