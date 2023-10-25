#!/bin/sh

set -ex

rpm -q kernel | tail -n1  | xargs rpm -e 

rpm -ivh $(ls ~/linux/rpmbuild/RPMS/x86_64/kernel-6* | tail -n1)
