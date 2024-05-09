#!/bin/bash

. common.sh

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
ENDCOLOR="\e[0m"

mode=nm

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode|-m)
            if [[ $# -lt 1 ]]; then
                echo "Missing argument to '$1'"
                exit 1
            fi

            shift
            mode=$1

            shift
            ;;
        *)
            test=$1
            shift
            ;;
    esac
done

run_test()
{
    local t=$1

    echo "* Running test $t"

    if [ ! -d "$scriptdir/tests/$t" ]; then
        echo "Invalid test $test"
        return 1
    fi

    podman exec "$c1" cp /root/ipsec/tests/"$t"/1.conf /etc/ipsec.d/"$t".conf
    podman exec "$c2" cp /root/ipsec/tests/"$t"/2.conf /etc/ipsec.d/"$t".conf

    podman exec "$c1" /root/ipsec/tests/"$t"/do.sh clean
    podman exec "$c2" /root/ipsec/tests/"$t"/do.sh clean

    podman exec "$c1" systemctl restart NetworkManager
    podman exec "$c1" systemctl restart ipsec
    podman exec "$c2" systemctl restart ipsec

    podman exec "$c2" ipsec auto --add "$t"

    if ! podman exec "$c1" nmcli connection import \
         type libreswan file /etc/ipsec.d/"$t".conf; then
        echo " ERROR: importing connection failed"
        return 1
    fi

    if ! podman exec "$c1" nmcli connection up "$t"; then
        echo " ERROR: bringing connection up"
        return 1
    fi

    podman exec "$c1" /root/ipsec/tests/"$t"/do.sh post
    podman exec "$c2" /root/ipsec/tests/"$t"/do.sh post

    echo
    podman exec "$c1" ip addr
    podman exec "$c1" ip route
    echo

    if ! podman exec "$c1" sh /root/ipsec/tests/"$t"/do.sh check; then
        echo " ERROR: check failed on $c1"
        return 1
    fi
    if ! podman exec "$c2" sh /root/ipsec/tests/"$t"/do.sh check; then
        echo " ERROR: check failed on $c2"
        return 1
    fi
}

succeeded=()
failed=()

if [ "$test" = all ]; then
    tests=($(ls -1 tests/ | grep -v test-funcs.sh))
    for t in ${tests[@]}; do
        printf "${YELLOW} * Running test '$t'...${ENDCOLOR}\n"
        if ! run_test "$t"; then
            failed+=( "$t" )
        else
            succeeded+=( "$t" )
        fi
    done
    printf "${GREEN}Succeeded tests:${ENDCOLOR}\n"
    for t in ${succeeded[@]}; do
        printf "$t\n"
    done
    printf "\n"
    printf "${RED}Failed tests:${ENDCOLOR}\n"
    for t in ${failed[@]}; do
        printf "$t\n"
    done
    printf "\n"
else
    if ! run_test "$test"; then
        printf "${RED}Test '$test' failed${ENDCOLOR}\n"
    else
        printf "${GREEN}Test '$test' succeeded${ENDCOLOR}\n"
    fi
fi
