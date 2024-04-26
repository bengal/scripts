#!/bin/sh

total=2000000
i=1

while [ $i -le $total ]; do
    a0=$i
    a1=$((a0 / 65536))
    printf "route append fd01::%04x:%04x dev $1 proto bird\n" $((a1 % 65536)) $((a0 % 65536))
    i=$((i+1))
done | bzip2 > routes6.txt.bz2
